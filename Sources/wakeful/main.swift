import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - Constants

private enum Constants {
    static let assertionIdentifier = "com.sunknudsen.wakeful"
    static let kIOMessageSystemWillSleep: UInt32 = 0xE0000280
    static let kIOMessageSystemHasPoweredOn: UInt32 = 0xE0000300
    static let ioBufferSize = 8192
    static let drainDelay: useconds_t = 100_000
    static let terminationTimeout: TimeInterval = 2.0
}

// MARK: - Type Aliases

private typealias FileDescriptor = Int32
private typealias SignalNumber = Int32

// MARK: - Process Status

private enum ProcessStatus {
    case exited(code: Int32)
    case signaled(signal: Int32)
    
    init(status: Int32) {
        if (status & 0x7f) == 0 {
            self = .exited(code: (status >> 8) & 0xff)
        } else {
            self = .signaled(signal: status & 0x7f)
        }
    }
    
    var exitCode: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal):
            return 128 + signal
        }
    }
}

// MARK: - Signal Escalation

private enum SignalEscalation {
    case initial
    case interrupt
    case terminate
    case kill
    
    mutating func escalate() {
        self = switch self {
        case .initial: .interrupt
        case .interrupt: .terminate
        case .terminate, .kill: .kill
        }
    }
    
    var signal: SignalNumber {
        switch self {
        case .initial, .interrupt: SIGINT
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
    }
    
    var message: String {
        switch self {
        case .initial, .interrupt: 
            "Sending interrupt signal (SIGINT) to child process…"
        case .terminate: 
            "Sending termination signal (SIGTERM) to child process…"
        case .kill: 
            "Forcefully killing child process (SIGKILL)…"
        }
    }
}

// MARK: - Errors

enum WakefulError: LocalizedError {
    case assertionFailed(String)
    case ptyFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .assertionFailed(let reason):
            return "Failed to create power assertion: \(reason)"
        case .ptyFailed(let reason):
            return "PTY error: \(reason)"
        }
    }
}

// MARK: - Standard Error Output

private enum StandardError {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
    
    static func warning(_ message: String) {
        FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
    }
    
    static func usage(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

// MARK: - File Descriptor Extensions

extension FileDescriptor {
    var isValid: Bool { self != -1 }
    
    func readData(count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let bytesRead = read(self, &buffer, count)
        guard bytesRead > 0 else { return nil }
        return Data(buffer[..<bytesRead])
    }
    
    @discardableResult
    func writeData(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var totalWritten = 0
            while totalWritten < data.count {
                let written = write(self, baseAddress + totalWritten, data.count - totalWritten)
                if written <= 0 { return false }
                totalWritten += written
            }
            return true
        }
    }
    
    func setNonBlocking() throws {
        let flags = fcntl(self, F_GETFL, 0)
        guard flags != -1 else {
            throw WakefulError.ptyFailed("Failed to get flags: \(String(cString: strerror(errno)))")
        }
        guard fcntl(self, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw WakefulError.ptyFailed("Failed to set non-blocking: \(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - Terminal State

private struct TerminalState {
    private var original: termios?
    
    mutating func enterRawMode() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        
        var termiosStruct = termios()
        guard tcgetattr(STDIN_FILENO, &termiosStruct) == 0 else { return }
        
        original = termiosStruct
        
        var raw = termiosStruct
        cfmakeraw(&raw)
        raw.c_lflag |= tcflag_t(ISIG)
        raw.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }
    
    func restore() {
        guard var termios = original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &termios)
    }
}

// MARK: - Wait Helper

private func waitpidRetrying(_ pid: pid_t, _ status: inout Int32, _ options: Int32) -> Int32 {
    var result: Int32
    repeat {
        result = waitpid(pid, &status, options)
    } while result == -1 && errno == EINTR
    return result
}

// MARK: - WakefulRunner

final class WakefulRunner: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var childPID: pid_t = 0
    private let preventDisplaySleep: Bool
    private let sleepGracePeriod: TimeInterval
    private let verbose: Bool
    
    private var signalSource: DispatchSourceSignal?
    private var termSource: DispatchSourceSignal?
    private var winchSource: DispatchSourceSignal?
    private var notifierPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var signalEscalation: SignalEscalation = .initial
    
    private let processQueue = DispatchQueue(label: "com.wakeful.process")
    private var masterFD: FileDescriptor = -1
    private var terminalState = TerminalState()
    private var stdinSource: DispatchSourceRead?
    private var masterSource: DispatchSourceRead?
    
    init(preventDisplaySleep: Bool, sleepGracePeriod: TimeInterval, verbose: Bool) {
        self.preventDisplaySleep = preventDisplaySleep
        self.sleepGracePeriod = sleepGracePeriod
        self.verbose = verbose
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Main Entry Point
    
    fileprivate func run(command: String, arguments: [String]) throws -> Int32 {
        try createPowerAssertions()
        registerForPowerNotifications()
        
        defer {
            cleanup()
        }
        
        return try spawnWithPTY(command: command, arguments: arguments)
    }
    
    // MARK: - Power Assertions
    
    private func createPowerAssertions() throws {
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "\(Constants.assertionIdentifier).preventsystemsleep" as CFString,
            &assertionID
        )
        
        guard systemResult == kIOReturnSuccess else {
            throw WakefulError.assertionFailed("system sleep")
        }
        
        if preventDisplaySleep {
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "\(Constants.assertionIdentifier).preventuseridledisplaysleep" as CFString,
                &displayAssertionID
            )
            
            if displayResult != kIOReturnSuccess {
                StandardError.warning("Failed to create display sleep assertion")
            }
        }
    }
    
    private func registerForPowerNotifications() {
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notifierPort,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let runner = Unmanaged<WakefulRunner>.fromOpaque(refcon).takeUnretainedValue()
                runner.handlePowerNotification(messageType: messageType, messageArgument: messageArgument)
            },
            &notifierObject
        )
        
        guard rootPort != 0, let port = notifierPort else {
            StandardError.warning("Failed to register for power notifications")
            return
        }
        
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )
    }
    
    private func handlePowerNotification(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Constants.kIOMessageSystemWillSleep:
            handleSystemWillSleep(messageArgument: messageArgument)
            
        case Constants.kIOMessageSystemHasPoweredOn:
            if verbose {
                print("\rSystem has woken up\r\n", terminator: "")
            }
            
        default:
            break
        }
    }
    
    private func handleSystemWillSleep(messageArgument: UnsafeMutableRawPointer?) {
        // If no child process is running, allow sleep and exit
        guard childPID > 0 else {
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
            cleanup()
            exit(0)
        }
        
        if verbose {
            print("\rSending interrupt signal (SIGINT) to child process…\r\n", terminator: "")
        }
        
        kill(-childPID, SIGINT)
        
        let semaphore = DispatchSemaphore(value: 0)
        processQueue.async { [weak self] in
            self?.waitForChildTermination(semaphore: semaphore)
        }
        
        _ = semaphore.wait(timeout: .now() + sleepGracePeriod + Constants.terminationTimeout)
        
        if verbose {
            print("\rChild process terminated, allowing sleep…\r\n", terminator: "")
        }
        
        releasePowerAssertions()
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))

        cleanup()
        exit(0)
    }
    
    private func waitForChildTermination(semaphore: DispatchSemaphore) {
        let startTime = Date()
        var status: Int32 = 0
        
        var result = waitpidRetrying(childPID, &status, WNOHANG)
        
        while result == 0 && Date().timeIntervalSince(startTime) < sleepGracePeriod {
            usleep(Constants.drainDelay)
            result = waitpidRetrying(childPID, &status, WNOHANG)
        }
        
        if result == 0 {
            if verbose {
                print("\rChild process still running after grace period, sending termination signal (SIGTERM)…\r\n", terminator: "")
            }
            
            kill(-childPID, SIGTERM)
            
            let terminateStartTime = Date()
            result = waitpidRetrying(childPID, &status, WNOHANG)
            
            while result == 0 && Date().timeIntervalSince(terminateStartTime) < Constants.terminationTimeout {
                usleep(Constants.drainDelay)
                result = waitpidRetrying(childPID, &status, WNOHANG)
            }
        }
        
        semaphore.signal()
    }
    
    // MARK: - Process Spawning
    
    private func spawnWithPTY(command: String, arguments: [String]) throws -> Int32 {
        var master: FileDescriptor = -1
        var windowSize = winsize()
        
        if isatty(STDIN_FILENO) != 0 {
            _ = ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &windowSize)
        }
        
        let pid = forkpty(&master, nil, nil, &windowSize)
        
        if pid == -1 {
            throw WakefulError.ptyFailed("Failed to fork with PTY: \(String(cString: strerror(errno)))")
        }
        
        if pid == 0 {
            setpgid(0, 0)
            
            var sigset = sigset_t()
            sigemptyset(&sigset)
            sigprocmask(SIG_SETMASK, &sigset, nil)
            
            let args = [command] + arguments
            let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
            execvp(command, cArgs)
            
            // Note: Can’t use StandardError here as we’re in a forked child process
            let errorMsg = "Error: failed to execute '\(command)': \(String(cString: strerror(errno)))\n"
            errorMsg.utf8CString.withUnsafeBufferPointer { buffer in
                _ = write(STDERR_FILENO, buffer.baseAddress!, buffer.count - 1) // -1 to exclude null terminator
            }
            Darwin._exit(127)
        }
        
        self.childPID = pid
        self.masterFD = master
        
        terminalState.enterRawMode()
        try masterFD.setNonBlocking()
        setupSignalHandling()
        
        return try forwardIO()
    }
    
    // MARK: - Signal Handling
    
    private func setupSignalHandling() {
        blockSignal(SIGINT)
        signalSource = makeSignalSource(for: SIGINT) { [weak self] in
            self?.handleInterruption()
        }
        
        blockSignal(SIGTERM)
        termSource = makeSignalSource(for: SIGTERM) { [weak self] in
            self?.handleTermination()
        }
        
        blockSignal(SIGWINCH)
        winchSource = makeSignalSource(for: SIGWINCH) { [weak self] in
            self?.handleWindowSizeChange()
        }
    }
    
    private func blockSignal(_ signal: SignalNumber) {
        var sigset = sigset_t()
        sigemptyset(&sigset)
        sigaddset(&sigset, signal)
        sigprocmask(SIG_BLOCK, &sigset, nil)
    }
    
    private func makeSignalSource(for signal: SignalNumber, handler: @escaping () -> Void) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
    
    private func handleInterruption() {
        guard childPID > 0, isChildProcessRunning() else {
            cleanup()
            exit(130)
        }
        
        signalEscalation.escalate()
        sendSignalToChildProcessGroup()
        
        if signalEscalation.signal == SIGKILL {
            usleep(Constants.drainDelay)
            cleanup()
            exit(137)
        }
    }
    
    private func handleTermination() {
        guard childPID > 0 else {
            cleanup()
            exit(143)
        }
        
        if verbose {
            print("\rReceived termination signal, sending SIGINT to child process…\r\n", terminator: "")
        }
        
        kill(-childPID, SIGINT)
        
        let semaphore = DispatchSemaphore(value: 0)
        processQueue.async { [weak self] in
            self?.waitForChildTermination(semaphore: semaphore)
        }
        
        _ = semaphore.wait(timeout: .now() + sleepGracePeriod + Constants.terminationTimeout)
        
        cleanup()
        exit(143)
    }
    
    private func isChildProcessRunning() -> Bool {
        var status: Int32 = 0
        return waitpidRetrying(childPID, &status, WNOHANG) == 0
    }
    
    private func sendSignalToChildProcessGroup() {
        print("\r\(signalEscalation.message)\r\n", terminator: "")
        kill(-childPID, signalEscalation.signal)
    }
    
    private func handleWindowSizeChange() {
        guard masterFD.isValid, isatty(STDIN_FILENO) != 0 else { return }
        
        var windowSize = winsize()
        guard ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 else { return }
        
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &windowSize)
        
        if childPID > 0 {
            kill(childPID, SIGWINCH)
        }
    }
    
    // MARK: - I/O Forwarding
    
    private func forwardIO() throws -> Int32 {
        if isatty(STDIN_FILENO) != 0 {
            stdinSource = makeReadSource(from: STDIN_FILENO, to: masterFD)
        }
        
        masterSource = makeReadSource(from: masterFD, to: STDOUT_FILENO)
        
        blockSignal(SIGCHLD)
        
        var finalStatus: Int32 = 0
        let childSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: .main)
        
        childSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            let result = waitpid(self.childPID, &status, WNOHANG)
            if result > 0 {
                finalStatus = status
                childSource.cancel()
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        childSource.resume()
        
        CFRunLoopRun()
        
        stdinSource?.cancel()
        masterSource?.cancel()
        
        var sigset = sigset_t()
        sigemptyset(&sigset)
        sigprocmask(SIG_UNBLOCK, &sigset, nil)
        
        usleep(Constants.drainDelay)
        drainRemainingPTYData()
        
        return ProcessStatus(status: finalStatus).exitCode
    }
    
    private func makeReadSource(from source: FileDescriptor, to destination: FileDescriptor) -> DispatchSourceRead {
        let readSource = DispatchSource.makeReadSource(fileDescriptor: source, queue: .global())
        readSource.setEventHandler { [weak self] in
            self?.forwardData(from: source, to: destination)
        }
        readSource.resume()
        return readSource
    }
    
    private func forwardData(from source: FileDescriptor, to destination: FileDescriptor) {
        guard source.isValid, destination.isValid else { return }
        guard let data = source.readData(count: Constants.ioBufferSize) else { return }
        destination.writeData(data)
    }
    
    private func drainRemainingPTYData() {
        while let data = masterFD.readData(count: Constants.ioBufferSize) {
            STDOUT_FILENO.writeData(data)
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        cleanupDispatchSources()
        terminalState.restore()
        closePTY()
        releasePowerAssertions()
        deregisterPowerNotifications()
    }
    
    private func cleanupDispatchSources() {
        stdinSource?.cancel()
        stdinSource = nil
        masterSource?.cancel()
        masterSource = nil
        signalSource?.cancel()
        signalSource = nil
        termSource?.cancel()
        termSource = nil
        winchSource?.cancel()
        winchSource = nil
        
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)
    }
    
    private func closePTY() {
        guard masterFD.isValid else { return }
        close(masterFD)
        masterFD = -1
    }
    
    private func releasePowerAssertions() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }
    
    private func deregisterPowerNotifications() {
        guard rootPort != 0 else { return }
        IODeregisterForSystemPower(&notifierObject)
        IOServiceClose(rootPort)
        if let port = notifierPort {
            IONotificationPortDestroy(port)
        }
        rootPort = 0
    }
}

// MARK: - Command Line Parsing

struct CommandLineOptions {
    var preventDisplaySleep: Bool = false
    var sleepGracePeriod: TimeInterval = 60.0
    var verbose: Bool = false
    var command: String?
    var arguments: [String] = []
}

func parseCommandLine() -> CommandLineOptions? {
    var options = CommandLineOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    
    while let arg = args.first, arg.hasPrefix("-") {
        args.removeFirst()
        
        switch arg {
        case "-d", "--display":
            options.preventDisplaySleep = true
            
        case "-g", "--grace-period":
            guard let gracePeriodStr = args.first,
                  let gracePeriod = TimeInterval(gracePeriodStr),
                  gracePeriod > 0 else {
                StandardError.error("-g/--grace-period requires a positive number of seconds")
                return nil
            }
            options.sleepGracePeriod = gracePeriod
            args.removeFirst()
            
        case "-v", "--verbose":
            options.verbose = true
            
        case "-h", "--help":
            printUsage()
            exit(0)
            
        default:
            StandardError.error("Unknown option '\(arg)'")
            printUsage()
            exit(1)
        }
    }
    
    guard let command = args.first else {
        printUsage()
        exit(1)
    }
    
    options.command = command
    options.arguments = Array(args.dropFirst())
    
    return options
}

func printUsage() {
    StandardError.usage("""
    Usage: wakeful [options] <command> [arguments...]
    
    Options:
      -d, --display                 Also prevent display from sleeping
      -g, --grace-period <seconds>  Grace period for child process termination (default: 60)
      -v, --verbose                 Verbose output
      -h, --help                    Show this help message
    
    """)
}

// MARK: - Main Entry Point

guard let options = parseCommandLine(), let command = options.command else {
    exit(1)
}

let runner = WakefulRunner(
    preventDisplaySleep: options.preventDisplaySleep,
    sleepGracePeriod: options.sleepGracePeriod,
    verbose: options.verbose
)

do {
    let exitCode = try runner.run(command: command, arguments: options.arguments)
    exit(exitCode)
} catch {
    StandardError.error(error.localizedDescription)
    exit(1)
}
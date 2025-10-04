import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - Constants

private let kIOMessageSystemWillSleep: UInt32 = UInt32(0xE0000280)
private let kIOMessageSystemHasPoweredOn: UInt32 = UInt32(0xE0000300)

// MARK: - Type Aliases

private typealias FileDescriptor = Int32
private typealias SignalNumber = Int32
private typealias ExitCode = Int32

// MARK: - Wait Status Helpers

/// Decodes the wait status returned by waitpid() into a usable format.
/// The wait status uses bit fields:
/// - Bits 0-6: Signal number (if terminated by signal)
/// - Bits 8-15: Exit code (if exited normally)
private enum ProcessStatus {
    case exited(code: Int32)
    case signaled(signal: Int32)
    
    init(status: Int32) {
        // Check if lower 7 bits are 0 (normal exit)
        if (status & 0x7f) == 0 {
            // Extract exit code from bits 8-15
            self = .exited(code: (status >> 8) & 0xff)
        } else {
            // Extract signal number from lower 7 bits
            self = .signaled(signal: status & 0x7f)
        }
    }
    
    var exitCode: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal):
            // Shell convention: signal termination returns 128 + signal number
            return 128 + signal
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

// MARK: - WakefulRunner

final class WakefulRunner: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var childPID: pid_t = 0
    private let preventDisplaySleep: Bool
    private let sleepGracePeriod: TimeInterval
    private let verbose: Bool
    
    private var signalSource: DispatchSourceSignal?
    private var winchSource: DispatchSourceSignal?
    private var notifierPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var signalCount: Int = 0
    
    private let processQueue = DispatchQueue(label: "com.wakeful.process")
    private var masterFD: FileDescriptor = -1
    private var originalTermios: termios?
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
            "Wakeful - Prevent System Sleep" as CFString,
            &assertionID
        )
        
        guard systemResult == kIOReturnSuccess else {
            throw WakefulError.assertionFailed("system sleep")
        }
        
        if preventDisplaySleep {
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Wakeful - Prevent Display Sleep" as CFString,
                &displayAssertionID
            )
            
            if displayResult != kIOReturnSuccess {
                FileHandle.standardError.write(Data("Warning: Failed to create display sleep assertion\n".utf8))
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
            FileHandle.standardError.write(Data("Warning: Failed to register for power notifications\n".utf8))
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
        case kIOMessageSystemWillSleep:
            handleSystemWillSleep(messageArgument: messageArgument)
            
        case kIOMessageSystemHasPoweredOn:
            if verbose {
                print("\rSystem has woken up\r\n", terminator: "")
            }
            
        default:
            break
        }
    }
    
    private func handleSystemWillSleep(messageArgument: UnsafeMutableRawPointer?) {
        defer {
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
        }
        
        guard childPID > 0 else {
            return
        }
        
        if verbose {
            print("\rSending interrupt signal (SIGINT) to child process…\r\n", terminator: "")
        }
        
        kill(-childPID, SIGINT)
        
        let semaphore = DispatchSemaphore(value: 0)
        processQueue.async { [weak self] in
            self?.waitForChildTermination(semaphore: semaphore)
        }
        
        _ = semaphore.wait(timeout: .now() + sleepGracePeriod + 2.0)
    }
    
    private func waitForChildTermination(semaphore: DispatchSemaphore) {
        let startTime = Date()
        var status: Int32 = 0
        var result: Int32
        
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        
        while result == 0 && Date().timeIntervalSince(startTime) < sleepGracePeriod {
            usleep(100_000)
            repeat {
                result = waitpid(childPID, &status, WNOHANG)
            } while result == -1 && errno == EINTR
        }
        
        if result == 0 {
            if verbose {
                print("\rChild process still running after grace period, sending termination signal (SIGTERM)…\r\n", terminator: "")
            }
            
            kill(-childPID, SIGTERM)
            
            let terminateStartTime = Date()
            repeat {
                result = waitpid(childPID, &status, WNOHANG)
            } while result == -1 && errno == EINTR
            
            while result == 0 && Date().timeIntervalSince(terminateStartTime) < 2.0 {
                usleep(100_000)
                repeat {
                    result = waitpid(childPID, &status, WNOHANG)
                } while result == -1 && errno == EINTR
            }
        }
        
        if verbose {
            print("\rChild process terminated, allowing sleep…\r\n", terminator: "")
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
            // Make child process the leader of its own process group
            setpgid(0, 0)
            
            // Unblock all signals in child process
            var sigset = sigset_t()
            sigemptyset(&sigset)
            sigprocmask(SIG_SETMASK, &sigset, nil)
            
            let args = [command] + arguments
            let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
            execvp(command, cArgs)
            
            Darwin._exit(127)
        }
        
        self.childPID = pid
        self.masterFD = master
        
        try configureTerminal()
        setupSignalHandling()
        return try forwardIO()
    }
    
    // MARK: - Terminal Configuration
    
    private func configureTerminal() throws {
        guard isatty(STDIN_FILENO) != 0 else { return }
        
        var termiosStruct = termios()
        guard tcgetattr(STDIN_FILENO, &termiosStruct) == 0 else { return }
        
        originalTermios = termiosStruct
        
        var raw = termiosStruct
        cfmakeraw(&raw)
        raw.c_lflag |= tcflag_t(ISIG)
        raw.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }
    
    // MARK: - Signal Handling
    
    private func setupSignalHandling() {
        var sigset = sigset_t()
        sigemptyset(&sigset)
        sigaddset(&sigset, SIGINT)
        sigprocmask(SIG_BLOCK, &sigset, nil)
        
        signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource?.setEventHandler { [weak self] in
            self?.handleInterrupt()
        }
        signalSource?.resume()
        
        sigemptyset(&sigset)
        sigaddset(&sigset, SIGWINCH)
        sigprocmask(SIG_BLOCK, &sigset, nil)
        
        winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winchSource?.setEventHandler { [weak self] in
            self?.handleWindowSizeChange()
        }
        winchSource?.resume()
    }
    
    private func handleInterrupt() {
        guard childPID > 0 else {
            cleanup()
            exit(130)
        }
        
        guard isChildProcessRunning() else {
            cleanup()
            exit(130)
        }
        
        signalCount += 1
        let signalInfo = determineSignalForInterruptCount()
        sendSignalToChildProcessGroup(signalInfo)
        
        if signalInfo.signal == SIGKILL {
            usleep(100_000)
            cleanup()
            exit(137)
        }
    }
    
    private func isChildProcessRunning() -> Bool {
        var status: Int32 = 0
        var result: Int32
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        return result == 0
    }
    
    private func determineSignalForInterruptCount() -> (signal: SignalNumber, message: String) {
        switch signalCount {
        case 1:
            return (SIGINT, "Sending interrupt signal (SIGINT) to child process…")
        case 2:
            return (SIGTERM, "Sending termination signal (SIGTERM) to child process…")
        default:
            return (SIGKILL, "Forcefully killing child process (SIGKILL)…")
        }
    }
    
    private func sendSignalToChildProcessGroup(_ signalInfo: (signal: SignalNumber, message: String)) {
        print("\r\(signalInfo.message)\r\n", terminator: "")
        kill(-childPID, signalInfo.signal)
    }
    
    private func handleWindowSizeChange() {
        guard assertMasterFDValid() else { return }
        guard isatty(STDIN_FILENO) != 0 else { return }
        
        var windowSize = winsize()
        guard ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 else { return }
        
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &windowSize)
        
        if assertChildProcessValid() {
            kill(childPID, SIGWINCH)
        }
    }
    
    // MARK: - I/O Forwarding
    
    private func forwardIO() throws -> Int32 {
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        
        if isatty(STDIN_FILENO) != 0 {
            stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
            stdinSource?.setEventHandler { [weak self] in
                self?.forwardData(from: STDIN_FILENO, to: self?.masterFD ?? -1)
            }
            stdinSource?.resume()
        }
        
        masterSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        masterSource?.setEventHandler { [weak self] in
            self?.forwardData(from: self?.masterFD ?? -1, to: STDOUT_FILENO)
        }
        masterSource?.resume()
        
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
        
        stdinSource?.cancel()
        masterSource?.cancel()
        
        // Allow remaining PTY data to drain
        usleep(50_000)
        
        drainRemainingPTYData()
        
        return ProcessStatus(status: status).exitCode
    }
    
    private func forwardData(from source: FileDescriptor, to destination: FileDescriptor) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(source, &buffer, buffer.count)
        if bytesRead > 0 {
            var totalWritten: Int = 0
            buffer.withUnsafeBytes { bufferPtr in
                while totalWritten < bytesRead {
                    let written = write(destination, bufferPtr.baseAddress! + totalWritten, bytesRead - totalWritten)
                    if written <= 0 { break }
                    totalWritten += written
                }
            }
        }
    }
    
    private func drainRemainingPTYData() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var bytesRead: Int
        repeat {
            bytesRead = read(masterFD, &buffer, buffer.count)
            if bytesRead > 0 {
                _ = write(STDOUT_FILENO, buffer, bytesRead)
            }
        } while bytesRead > 0
    }
    
    // MARK: - State Validation
    
    /// Validates that the PTY master file descriptor is open
    private func assertMasterFDValid() -> Bool {
        return masterFD != -1
    }
    
    /// Validates that the child process is running
    private func assertChildProcessValid() -> Bool {
        return childPID > 0
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        cleanupDispatchSources()
        restoreTerminalState()
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
        winchSource?.cancel()
        winchSource = nil
        
        signal(SIGINT, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)
    }
    
    private func restoreTerminalState() {
        guard let termios = originalTermios else { return }
        var termiosStruct = termios
        tcsetattr(STDIN_FILENO, TCSANOW, &termiosStruct)
    }
    
    private func closePTY() {
        guard masterFD != -1 else { return }
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
                FileHandle.standardError.write(Data("Error: -g/--grace-period requires a positive number of seconds\n".utf8))
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
            FileHandle.standardError.write(Data("Error: Unknown option '\(arg)'\n".utf8))
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
    FileHandle.standardError.write(Data("""
    Usage: wakeful [options] <command> [arguments...]
    
    Options:
      -d, --display                 Also prevent display from sleeping
      -g, --grace-period <seconds>  Grace period for child process termination (default: 60)
      -v, --verbose                 Verbose output
      -h, --help                    Show this help message
    
    """.utf8))
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
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin

// MARK: - Constants

private let kIOMessageSystemWillSleep = UInt32(0xE0000280)
private let kIOMessageSystemHasPoweredOn = UInt32(0xE0000300)

// MARK: - Wait Status Helpers

private enum ProcessStatus {
    case exited(code: Int32)
    case signaled(signal: Int32)
    case unknown
    
    init(status: Int32) {
        if (status & 0x7f) == 0 {
            self = .exited(code: (status >> 8) & 0xff)
        } else if (status & 0x7f) != 0 && (status & 0x7f) != 0x7f {
            self = .signaled(signal: status & 0x7f)
        } else {
            self = .unknown
        }
    }
    
    var exitCode: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal):
            return 128 + signal
        case .unknown:
            return 1
        }
    }
}

// MARK: - Errors

enum WakefulError: LocalizedError {
    case assertionFailed(String)
    case ptyFailed(String)
    case spawnFailed(String, Int32)
    case commandNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .assertionFailed(let reason):
            return "Failed to create power assertion: \(reason)"
        case .ptyFailed(let reason):
            return "PTY error: \(reason)"
        case .spawnFailed(let command, let error):
            return "Failed to spawn '\(command)': \(String(cString: strerror(error)))"
        case .commandNotFound(let command):
            return "Command not found: \(command)"
        }
    }
}

// MARK: - WakefulRunner

final class WakefulRunner {
    // MARK: Properties
    
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
    private var signalCount = 0
    
    private let processQueue = DispatchQueue(label: "com.wakeful.process")
    private var masterFD: Int32 = -1
    private var originalTermios: termios?
    private var stdinSource: DispatchSourceRead?
    private var masterSource: DispatchSourceRead?
    
    // MARK: Initialization
    
    init(preventDisplaySleep: Bool, sleepGracePeriod: TimeInterval, verbose: Bool) {
        self.preventDisplaySleep = preventDisplaySleep
        self.sleepGracePeriod = sleepGracePeriod
        self.verbose = verbose
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: Public Methods
    
    func run(command: String, arguments: [String]) throws -> Int32 {
        try createPowerAssertions()
        registerForPowerNotifications()
        
        defer {
            cleanup()
        }
        
        return try spawnWithPTY(command: command, arguments: arguments)
    }
    
    // MARK: Private Methods - Power Assertions
    
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
                print("Warning: Failed to create display sleep assertion", to: &StandardError.shared)
            }
        }
    }
    
    // MARK: Private Methods - PTY
    
    private func spawnWithPTY(command: String, arguments: [String]) throws -> Int32 {
        let (master, slave) = try openPTY()
        defer { close(slave) }
        
        self.masterFD = master
        
        try configureTerminal()
        try spawnProcess(command: command, arguments: arguments, master: master, slave: slave)
        
        setupSignalHandling()
        return try forwardIO(master: master)
    }
    
    private func openPTY() throws -> (master: Int32, slave: Int32) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master != -1 else {
            throw WakefulError.ptyFailed("Failed to open PTY master")
        }
        
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master)
            throw WakefulError.ptyFailed("Failed to grant/unlock PTY")
        }
        
        var slaveName = [CChar](repeating: 0, count: 1024)
        guard ptsname_r(master, &slaveName, slaveName.count) == 0 else {
            close(master)
            throw WakefulError.ptyFailed("Failed to get PTY slave name")
        }
        
        let slave = open(String(cString: slaveName), O_RDWR)
        guard slave != -1 else {
            close(master)
            throw WakefulError.ptyFailed("Failed to open PTY slave")
        }
        
        // Set the PTY window size to match the parent terminal
        if isatty(STDIN_FILENO) != 0 {
            var windowSize = winsize()
            if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 {
                _ = ioctl(slave, UInt(TIOCSWINSZ), &windowSize)
            }
        }
        
        return (master, slave)
    }
    
    private func configureTerminal() throws {
        guard isatty(STDIN_FILENO) != 0 else { return }
        
        var termiosStruct = termios()
        guard tcgetattr(STDIN_FILENO, &termiosStruct) == 0 else { return }
        
        originalTermios = termiosStruct
        
        var raw = termiosStruct
        cfmakeraw(&raw)
        // Re-enable signal generation so Ctrl+C generates SIGINT
        raw.c_lflag |= tcflag_t(ISIG)
        // Disable echo to prevent ^C from being displayed
        raw.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }
    
    private func spawnProcess(command: String, arguments: [String], master: Int32, slave: Int32) throws {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        posix_spawn_file_actions_addclose(&fileActions, master)
        
        var spawnAttrs: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttrs)
        defer { posix_spawnattr_destroy(&spawnAttrs) }
        
        var flags: Int16 = 0
        posix_spawnattr_getflags(&spawnAttrs, &flags)
        flags |= Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&spawnAttrs, flags)
        
        // Reset signal mask for child to allow SIGWINCH
        var sigset = sigset_t()
        sigemptyset(&sigset)
        posix_spawnattr_setsigmask(&spawnAttrs, &sigset)
        
        // Set signals to default handling
        sigfillset(&sigset)
        posix_spawnattr_setsigdefault(&spawnAttrs, &sigset)
        
        let args = [command] + arguments
        let cArgs = args.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
        }
        
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, command, &fileActions, &spawnAttrs, cArgs, environ)
        
        guard result == 0 else {
            throw WakefulError.spawnFailed(command, result)
        }
        
        self.childPID = pid
    }
    
    private func forwardIO(master: Int32) throws -> Int32 {
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        
        if isatty(STDIN_FILENO) != 0 {
            stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
            stdinSource?.setEventHandler { [weak self] in
                self?.forwardData(from: STDIN_FILENO, to: self?.masterFD ?? -1)
            }
            stdinSource?.resume()
        }
        
        masterSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        masterSource?.setEventHandler { [weak self] in
            self?.forwardData(from: self?.masterFD ?? -1, to: STDOUT_FILENO)
        }
        masterSource?.resume()
        
        var status: Int32 = 0
        waitpid(childPID, &status, 0)
        
        return ProcessStatus(status: status).exitCode
    }
    
    private func forwardData(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(source, &buffer, buffer.count)
        if bytesRead > 0 {
            _ = write(destination, buffer, bytesRead)
        }
    }
    
    // MARK: Private Methods - Signal Handling
    
    private func setupSignalHandling() {
        // Block SIGINT so it can be caught by DispatchSource
        var sigset = sigset_t()
        sigemptyset(&sigset)
        sigaddset(&sigset, SIGINT)
        sigprocmask(SIG_BLOCK, &sigset, nil)
        
        signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource?.setEventHandler { [weak self] in
            self?.handleInterrupt()
        }
        signalSource?.resume()
        
        // Handle terminal window size changes - block SIGWINCH too
        sigemptyset(&sigset)
        sigaddset(&sigset, SIGWINCH)
        sigprocmask(SIG_BLOCK, &sigset, nil)
        
        winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winchSource?.setEventHandler { [weak self] in
            self?.handleWindowSizeChange()
        }
        winchSource?.resume()
    }
    
    private func handleWindowSizeChange() {
        guard masterFD != -1, isatty(STDIN_FILENO) != 0 else { return }
        
        var windowSize = winsize()
        if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 {
            _ = ioctl(masterFD, UInt(TIOCSWINSZ), &windowSize)
            
            // Send SIGWINCH to the child process
            if childPID > 0 {
                kill(childPID, SIGWINCH)
            }
        }
    }
    
    private func handleInterrupt() {
        guard childPID > 0 else {
            cleanup()
            exit(130)
        }
        
        // Check if child is still alive
        let isAlive = kill(childPID, 0) == 0
        
        if !isAlive {
            cleanup()
            exit(130)
        }
        
        signalCount += 1
        
        let signal: Int32
        let message: String
        
        switch signalCount {
        case 1:
            signal = SIGINT
            message = "Sending interrupt signal (SIGINT) to child process…"
        case 2:
            signal = SIGTERM
            message = "Sending termination signal (SIGTERM) to child process…"
        default:
            signal = SIGKILL
            message = "Forcefully killing child process (SIGKILL)…"
        }
        
        print("\r\(message)\r\n", terminator: "")
        
        // Send signal to the process group (negative PID)
        kill(-childPID, signal)
        
        // If SIGKILL, wait briefly then exit
        if signal == SIGKILL {
            usleep(100_000) // 100ms
            cleanup()
            exit(137)
        }
    }
    
    // MARK: Private Methods - Power Notifications
    
    private func registerForPowerNotifications() {
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notifierPort,
            { refcon, _, messageType, messageArgument in
                guard let refcon = refcon else { return }
                let runner = Unmanaged<WakefulRunner>.fromOpaque(refcon).takeUnretainedValue()
                runner.handlePowerNotification(messageType: messageType, messageArgument: messageArgument)
            },
            &notifierObject
        )
        
        guard rootPort != 0, let port = notifierPort else {
            print("Warning: Failed to register for power notifications", to: &StandardError.shared)
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
        
        guard childPID > 0, kill(childPID, 0) == 0 else {
            return
        }
        
        if verbose {
            print("\rSending interrupt signal (SIGINT) to child process…\r\n", terminator: "")
        }
        
        // Send to process group
        kill(-childPID, SIGINT)
        
        let semaphore = DispatchSemaphore(value: 0)
        processQueue.async { [weak self] in
            self?.waitForChildTermination(semaphore: semaphore)
        }
        
        _ = semaphore.wait(timeout: .now() + sleepGracePeriod + 3.0)
    }
    
    private func waitForChildTermination(semaphore: DispatchSemaphore) {
        let startTime = Date()
        
        while kill(childPID, 0) == 0 && Date().timeIntervalSince(startTime) < sleepGracePeriod {
            usleep(100_000)
        }
        
        if kill(childPID, 0) == 0 {
            if verbose {
                print("\rChild process still running after grace period, sending termination signal (SIGTERM)…\r\n", terminator: "")
            }
            
            // Send to process group
            kill(-childPID, SIGTERM)
            
            let terminateStart = Date()
            while kill(childPID, 0) == 0 && Date().timeIntervalSince(terminateStart) < 2.0 {
                usleep(100_000)
            }
        }
        
        if verbose {
            print("\rChild process terminated, allowing sleep…\r\n", terminator: "")
        }
        
        semaphore.signal()
    }
    
    // MARK: Private Methods - Cleanup
    
    private func cleanup() {
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
        
        if let termios = originalTermios {
            var termiosStruct = termios
            tcsetattr(STDIN_FILENO, TCSANOW, &termiosStruct)
        }
        
        if masterFD != -1 {
            close(masterFD)
            masterFD = -1
        }
        
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        
        if rootPort != 0 {
            IODeregisterForSystemPower(&notifierObject)
            IOServiceClose(rootPort)
            if let port = notifierPort {
                IONotificationPortDestroy(port)
            }
            rootPort = 0
        }
    }
}

// MARK: - Command Line Parsing

struct CommandLineOptions {
    var preventDisplaySleep = false
    var sleepGracePeriod: TimeInterval = 60.0
    var verbose = false
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
            
        case "-t", "--timeout":
            guard let timeoutStr = args.first,
                  let timeout = TimeInterval(timeoutStr),
                  timeout > 0 else {
                print("Error: -t/--timeout requires a positive number of seconds", to: &StandardError.shared)
                return nil
            }
            options.sleepGracePeriod = timeout
            args.removeFirst()
            
        case "-v", "--verbose":
            options.verbose = true
            
        case "-h", "--help":
            printUsage()
            return nil
            
        default:
            print("Error: Unknown option '\(arg)'", to: &StandardError.shared)
            printUsage()
            return nil
        }
    }
    
    guard let command = args.first else {
        printUsage()
        return nil
    }
    
    options.command = command
    options.arguments = Array(args.dropFirst())
    
    return options
}

func printUsage() {
    print("""
    Usage: wakeful [options] <command> [arguments...]
    
    Options:
      -d, --display           Also prevent display from sleeping
      -t, --timeout <seconds> Grace period for child process termination (default: 60)
      -v, --verbose           Verbose output
      -h, --help              Show this help message
    """, to: &StandardError.shared)
}

// MARK: - Standard Error Output

struct StandardError: TextOutputStream {
    static var shared = StandardError()
    
    func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

// MARK: - Main

guard let options = parseCommandLine(), let command = options.command else {
    exit(1)
}

let runner = WakefulRunner(
    preventDisplaySleep: options.preventDisplaySleep,
    sleepGracePeriod: options.sleepGracePeriod,
    verbose: options.verbose
)

var exitCode: Int32 = 1

DispatchQueue.global().async {
    do {
        exitCode = try runner.run(command: command, arguments: options.arguments)
        exit(exitCode)
    } catch {
        print("Error: \(error.localizedDescription)", to: &StandardError.shared)
        exit(1)
    }
}

RunLoop.main.run()
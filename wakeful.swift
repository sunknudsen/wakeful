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

// MARK: - Errors

enum WakefulError: LocalizedError {
    case assertionFailed(String)
    case ptyFailed(String)
    case spawnFailed(String, Int32)
    
    var errorDescription: String? {
        switch self {
        case .assertionFailed(let reason):
            return "Failed to create power assertion: \(reason)"
        case .ptyFailed(let reason):
            return "PTY error: \(reason)"
        case .spawnFailed(let command, let error):
            return "Failed to spawn '\(command)': \(String(cString: strerror(error)))"
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
        var master: Int32 = -1
        var windowSize = winsize()
        
        // Get current terminal size if running in a terminal
        if isatty(STDIN_FILENO) != 0 {
            _ = ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &windowSize)
        }
        
        // Use forkpty - it handles openpty, fork, setsid, and TIOCSCTTY for us
        let pid = forkpty(&master, nil, nil, &windowSize)
        
        if pid == -1 {
            throw WakefulError.ptyFailed("Failed to fork with PTY: \(String(cString: strerror(errno)))")
        }
        
        if pid == 0 {
            // Child process - already has controlling terminal set up by forkpty
            
            // Reset signal mask
            var sigset = sigset_t()
            sigemptyset(&sigset)
            sigprocmask(SIG_SETMASK, &sigset, nil)
            
            // Execute the command
            let args = [command] + arguments
            let cArgs = args.map { strdup($0) } + [nil]
            execvp(command, cArgs)
            
            // If execvp returns, it failed
            Darwin._exit(127)
        }
        
        // Parent process
        self.childPID = pid
        self.masterFD = master
        
        try configureTerminal()
        setupSignalHandling()
        return try forwardIO(master: master)
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
        
        // Wait for child with EINTR handling
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
        
        // Cancel dispatch sources to stop reading
        stdinSource?.cancel()
        masterSource?.cancel()
        
        // Give dispatch sources a moment to process any pending events
        usleep(50_000) // 50ms
        
        // Drain any remaining bytes from the PTY master
        var buffer = [UInt8](repeating: 0, count: 8192)
        var bytesRead: Int
        repeat {
            bytesRead = read(master, &buffer, buffer.count)
            if bytesRead > 0 {
                _ = write(STDOUT_FILENO, buffer, bytesRead)
            }
        } while bytesRead > 0
        
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
        
        // Use waitpid with EINTR handling
        var status: Int32 = 0
        var result: Int32
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        
        if result != 0 {  // Process has exited (result > 0) or error (result < 0)
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
        
        guard childPID > 0 else {
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
        var status: Int32 = 0
        var result: Int32
        
        // Use waitpid with WNOHANG and EINTR handling
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        
        while result == 0 && Date().timeIntervalSince(startTime) < sleepGracePeriod {
            usleep(100_000)
            repeat {
                result = waitpid(childPID, &status, WNOHANG)
            } while result == -1 && errno == EINTR
        }
        
        // Check if process is still running (waitpid returns 0 if still alive)
        if result == 0 {
            if verbose {
                print("\rChild process still running after grace period, sending termination signal (SIGTERM)…\r\n", terminator: "")
            }
            
            kill(-childPID, SIGTERM)
            
            let terminateStart = Date()
            repeat {
                result = waitpid(childPID, &status, WNOHANG)
            } while result == -1 && errno == EINTR
            
            while result == 0 && Date().timeIntervalSince(terminateStart) < 2.0 {
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
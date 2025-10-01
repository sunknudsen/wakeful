import Foundation
import IOKit
import IOKit.pwr_mgt

// Define the IOKit message constants that aren’t bridged to Swift
let kIOMessageSystemWillSleep = UInt32(0xE0000280)
let kIOMessageSystemHasPoweredOn = UInt32(0xE0000300)

class WakefulRunner {
    private var assertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var childProcess: Process?
    private var preventDisplaySleep: Bool
    private let sleepGracePeriod: TimeInterval
    private var verbose: Bool
    private var signalSource: DispatchSourceSignal?
    private var notifierPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var signalCount: Int = 0
    private let processQueue = DispatchQueue(label: "com.wakeful.process")
    
    init(preventDisplaySleep: Bool, sleepGracePeriod: TimeInterval, verbose: Bool) {
        self.preventDisplaySleep = preventDisplaySleep
        self.sleepGracePeriod = sleepGracePeriod
        self.verbose = verbose
    }
    
    func run(command: String, arguments: [String]) -> Int32 {
        // Create power assertion to prevent system sleep
        let systemAssertionName = "Wakeful - Prevent System Sleep" as CFString
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            systemAssertionName,
            &assertionID
        )
        
        guard systemResult == kIOReturnSuccess else {
            fputs("Error: Failed to create system sleep assertion\n", stderr)
            return 1
        }
        
        // Optionally create display assertion
        if preventDisplaySleep {
            let displayAssertionName = "Wakeful - Prevent Display Sleep" as CFString
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                displayAssertionName,
                &displayAssertionID
            )
            
            if displayResult != kIOReturnSuccess {
                fputs("Warning: Failed to create display sleep assertion\n", stderr)
            }
        }
        
        // Register for power notifications (sleep/wake)
        registerForPowerNotifications()
        
        // Start the child process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        
        // Pass through stdin, stdout, stderr
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        
        self.childProcess = process
        
        do {
            try process.run()
            
            // Setup signal handling AFTER child is running so child inherits default SIGINT behavior
            setupSignalHandling()
            
            process.waitUntilExit()
            
            let exitCode = process.terminationStatus
            
            // Clean up
            cleanup()
            
            return exitCode
        } catch {
            fputs("Error: Failed to execute command: \(error.localizedDescription)\n", stderr)
            cleanup()
            return 1
        }
    }
    
    private func setupSignalHandling() {
        // Ignore SIGINT in parent so we can handle it manually
        signal(SIGINT, SIG_IGN)
        
        // Setup dispatch source for SIGINT on a global queue
        signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource?.setEventHandler { [weak self] in
            self?.handleInterrupt()
        }
        signalSource?.resume()
    }
    
    private func handleInterrupt() {
        guard let process = childProcess, process.isRunning else {
            cleanup()
            exit(130) // Standard exit code for SIGINT
        }
        
        signalCount += 1
        
        switch signalCount {
        case 1:
            if verbose {
                fputs("\nSending interrupt signal (SIGINT) to child process…\n", stdout)
            }
            process.interrupt()
            
        case 2:
            if verbose {
                fputs("\nSending termination signal (SIGTERM) to child process…\n", stdout)
            }
            process.terminate()
            
        default:
            if verbose {
                fputs("\nForcefully killing child process (SIGKILL)…\n", stdout)
            }
            kill(process.processIdentifier, SIGKILL)
        }
    }
    
    private func registerForPowerNotifications() {
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notifierPort,
            { (refcon, service, messageType, messageArgument) in
                let runner = Unmanaged<WakefulRunner>.fromOpaque(refcon!).takeUnretainedValue()
                runner.handlePowerNotification(messageType: messageType, messageArgument: messageArgument)
            },
            &notifierObject
        )
        
        guard rootPort != 0, let port = notifierPort else {
            fputs("Error: Failed to register for power notifications\n", stderr)
            return
        }
        
        // Add to main run loop, not background thread
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )
    }
    
    private func handlePowerNotification(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case kIOMessageSystemWillSleep:
            // Forced sleep (Apple menu sleep, lid close or low battery)
            guard let process = childProcess, process.isRunning else {
                IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
                return
            }
            
            if verbose {
                fputs("Sending interrupt signal (SIGINT) to child process…\n", stdout)
            }
            
            // Send SIGINT to allow graceful shutdown
            process.interrupt()
            
            // Wait asynchronously for process to exit within grace period
            let semaphore = DispatchSemaphore(value: 0)
            processQueue.async { [weak self] in
                guard let self = self else { return }
                
                let startTime = Date()
                while process.isRunning && Date().timeIntervalSince(startTime) < self.sleepGracePeriod {
                    usleep(100_000) // 0.1 seconds in microseconds
                }
                
                // If still running, send SIGTERM
                if process.isRunning {
                    if self.verbose {
                        fputs("Child process still running after grace period, sending termination signal (SIGTERM)…\n", stdout)
                    }
                    process.terminate()
                    
                    // Wait a bit more
                    let terminateStart = Date()
                    while process.isRunning && Date().timeIntervalSince(terminateStart) < 2.0 {
                        usleep(100_000)
                    }
                }
                
                if self.verbose {
                    fputs("Child process terminated, allowing sleep…\n", stdout)
                }
                semaphore.signal()
            }
            
            // Wait for the async work to complete
            _ = semaphore.wait(timeout: .now() + sleepGracePeriod + 3.0)
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
            
        case kIOMessageSystemHasPoweredOn:
            if verbose {
                fputs("System has woken up\n", stdout)
            }
            
        default:
            break
        }
    }
    
    private func cleanup() {
        // Cancel signal handler
        signalSource?.cancel()
        signalSource = nil
        
        // Restore default SIGINT handler
        signal(SIGINT, SIG_DFL)
        
        // Release assertions
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        
        // Deregister power notifications
        if rootPort != 0 {
            IODeregisterForSystemPower(&notifierObject)
            IOServiceClose(rootPort)
            if let port = notifierPort {
                IONotificationPortDestroy(port)
            }
            rootPort = 0
        }
    }
    
    deinit {
        cleanup()
    }
}

// Parse command line arguments
var preventDisplaySleep = false
var sleepGracePeriod: TimeInterval = 60.0
var verbose = false
var commandArgs = CommandLine.arguments.dropFirst()

func printUsage() {
    fputs("Usage: wakeful [options] <command>\n", stderr)
    fputs("\nOptions:\n", stderr)
    fputs("  -d, --display           Also prevent display from sleeping\n", stderr)
    fputs("  -t, --timeout <seconds> Grace period for child process termination (default: 60)\n", stderr)
    fputs("  -v, --verbose           Verbose output\n", stderr)
    fputs("  -h, --help              Show this help message\n", stderr)
}

while let arg = commandArgs.first, arg.hasPrefix("-") {
    commandArgs = commandArgs.dropFirst()
    
    switch arg {
    case "-d", "--display":
        preventDisplaySleep = true
        
    case "-t", "--timeout":
        guard let timeoutStr = commandArgs.first,
              let timeout = TimeInterval(timeoutStr),
              timeout > 0 else {
            fputs("Error: -t/--timeout requires a positive number of seconds\n", stderr)
            exit(1)
        }
        sleepGracePeriod = timeout
        commandArgs = commandArgs.dropFirst()
        
    case "-v", "--verbose":
        verbose = true
        
    case "-h", "--help":
        printUsage()
        exit(0)
        
    default:
        fputs("Error: Unknown option '\(arg)'\n", stderr)
        printUsage()
        exit(1)
    }
}

guard let command = commandArgs.first else {
    printUsage()
    exit(1)
}

let arguments = Array(commandArgs.dropFirst())

// Resolve command path
var executablePath = command
if !command.hasPrefix("/") && !command.hasPrefix(".") {
    // Try to find in PATH
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = [command]
    
    let pipe = Pipe()
    whichProcess.standardOutput = pipe
    whichProcess.standardError = FileHandle.nullDevice
    
    do {
        try whichProcess.run()
        whichProcess.waitUntilExit()
        
        if whichProcess.terminationStatus == 0 {
            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                executablePath = path
            }
        }
    } catch {
        // Fall through to use original command
    }
}

// Need to run the main run loop for power notifications
let runner = WakefulRunner(preventDisplaySleep: preventDisplaySleep, sleepGracePeriod: sleepGracePeriod, verbose: verbose)

var exitCode: Int32 = 0

// Start child process on background queue
DispatchQueue.global().async {
    exitCode = runner.run(command: executablePath, arguments: arguments)
    // Exit the entire program when child completes
    exit(exitCode)
}

// Run the main run loop to handle power notifications
// This will run until the program exits via the exit() call above
RunLoop.main.run()
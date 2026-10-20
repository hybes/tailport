import Foundation
import Darwin

@main
struct TailportTunnel {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let parent = Int32(arguments[1]), parent > 1 else { exit(64) }
        guard kill(parent, 0) == 0 else { exit(1) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[2])
        child.arguments = Array(arguments.dropFirst(3))
        child.standardInput = FileHandle.standardInput
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        child.terminationHandler = { process in exit(process.terminationStatus) }

        func stop() {
            if child.isRunning { child.terminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }

        let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        parentExit.setEventHandler(handler: stop)
        parentExit.activate()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler(handler: stop)
        termination.activate()
        do { try child.run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
        if kill(parent, 0) != 0 { stop() }
        withExtendedLifetime((parentExit, termination)) { dispatchMain() }
    }
}

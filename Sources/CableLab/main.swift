import CableLabCore
import Foundation

// The same binary is the disk benchmark helper. The app runs it as a child
// (through sudo when needed), so it must exit here before any UI starts.
let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--bench-disk" {
    exit(DiskBench.commandLine(Array(arguments.dropFirst(2))))
}
// `CableLab ctl ...` talks to the running app over its control socket (see Control.swift).
if arguments.count >= 2, arguments[1] == "ctl" {
    exit(ControlCLI.run(Array(arguments.dropFirst(2))))
}

CableLabApp.main()

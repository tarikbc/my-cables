import CableLabCore
import Foundation

// `CableLab ctl ...` talks to the running app over its control socket (see Control.swift).
// It must exit here before any UI starts. This binary never runs as root.
let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "ctl" {
    exit(ControlCLI.run(Array(arguments.dropFirst(2))))
}

CableLabApp.main()

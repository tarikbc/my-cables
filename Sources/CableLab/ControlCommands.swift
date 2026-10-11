import AppKit
import CableLabCore
import Foundation

/// Answers requests from `cablectl` (see CableLabCore/Control.swift). Runs on the main actor.
extension LabModel {
    struct ControlError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    func startControlServer() {
        let server = ControlServer { [weak self] request in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.handleControl(request) ?? ["ok": false, "error": "Cable Lab is closing."]
                }
            }
        }
        do {
            try server.start()
            control = server
        } catch {
            problem = "The cablectl socket did not start: \(error)"
        }
    }

    func handleControl(_ request: [String: Any]) -> [String: Any] {
        let args = request["args"] as? [String: Any] ?? [:]
        do {
            let data = try runControl(request["cmd"] as? String ?? "", args)
            return ["ok": true, "data": data]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func runControl(_ cmd: String, _ args: [String: Any]) throws -> Any {
        switch cmd {
        case "state":
            return [
                "repo": repoURL?.path ?? NSNull(),
                "host": host,
                "devices": Control.object(endpoints),
                "ports": Control.object(ports),
                "saved_password": hasSavedPassword,
                "detected": detected.map { d -> [String: Any] in
                    ["port": d.port, "new": d.isNew, "suggestion": d.isSuggestion, "cable": d.cableID ?? NSNull(),
                     "summary": d.identity?.summary ?? "no e-marker"]
                } ?? NSNull(),
                "cables": data.cables.map(summary),
                "job": jobObject(),
            ] as [String: Any]

        case "devices":
            rescanNow()
            return Control.object(endpoints)

        case "cables":
            return Control.object(data.cables)

        case "add", "edit":
            var fields = CableFields()
            var id: String?
            if cmd == "edit" {
                guard let cableID = args["cable"] as? String, let cable = cable(cableID) else {
                    throw ControlError("Unknown cable. Run `cablectl cables` for the ids.")
                }
                id = cableID
                fields = CableFields(cable)
            }
            let given = args["fields"] as? [String: String] ?? [:]
            if let v = given["name"] { fields.name = v }
            if let v = given["brand"] { fields.brand = v }
            if let v = given["rated_data"] { fields.ratedData = v }
            if let v = given["rated_power"] { fields.ratedPower = v }
            if let v = given["length"] { fields.length = v }
            if let v = given["ends"] { fields.ends = v }
            if let v = given["looks"] { fields.looks = v }
            if let v = given["notes"] { fields.notes = v }
            var failure: Error?
            let saved = change { data -> String? in
                do { return try data.upsert(id: id, fields: fields) } catch { failure = error; return nil }
            }
            guard let newID = saved ?? nil else {
                throw failure ?? ControlError(problem ?? "Could not save the cable.")
            }
            selection = .cable(newID)
            return Control.object(cable(newID))

        case "test":
            guard let cableID = args["cable"] as? String, cable(cableID) != nil else {
                throw ControlError("Unknown cable. Run `cablectl cables` for the ids.")
            }
            guard !job.isRunning else { throw ControlError("A test is already running.") }
            rescanNow()
            let endpoint: Endpoint
            if let deviceID = args["device"] as? String {
                guard let found = endpoints.first(where: { $0.id == deviceID }) else {
                    throw ControlError("Unknown device. Run `cablectl devices` for the ids.")
                }
                endpoint = found
            } else if endpoints.count == 1 {
                endpoint = endpoints[0]
            } else {
                throw ControlError(endpoints.isEmpty
                    ? "No device is connected."
                    : "More than one device is connected. Pass --device with one of: "
                        + endpoints.map(\.id).joined(separator: ", "))
            }
            selection = .cable(cableID)
            startTest(cableID: cableID, endpointID: endpoint.id)
            if passwordRequest != nil { NSApp.activate(ignoringOtherApps: true) }
            return jobObject()

        case "job":
            return jobObject()

        case "ports":
            rescanNow()
            return ports.map { port -> [String: Any] in
                var out = Control.object(port) as? [String: Any] ?? [:]
                out["saved_cable"] = port.cable.flatMap { data.cable(matching: $0)?.id } ?? NSNull()
                out["cable_summary"] = port.cable?.summary ?? (port.connected ? "no e-marker" : NSNull())
                return out
            }

        case "link":
            guard let cableID = args["cable"] as? String, cable(cableID) != nil else {
                throw ControlError("Unknown cable. Run `cablectl cables` for the ids.")
            }
            guard let number = args["port"] as? Int else { throw ControlError("link needs --port N.") }
            rescanNow()
            guard let port = ports.first(where: { $0.number == number }), port.connected else {
                throw ControlError("Nothing is connected to port \(number).")
            }
            guard let identity = port.cable else {
                throw ControlError("The cable on port \(number) has no e-marker, so there is nothing to link.")
            }
            change { try $0.link(identity, to: cableID) }
            if detected?.identity == identity { detected = nil }
            return Control.object(cable(cableID))

        case "accept":
            guard detected?.isSuggestion == true else { throw ControlError("There is no cable suggestion to accept.") }
            addSuggested()
            return Control.object(cable(detected?.cableID))

        case "ignore":
            guard detected != nil else { throw ControlError("There is no banner to dismiss.") }
            dismissDetected()
            return ["dismissed": true]

        case "forget-password":
            forgetPassword()
            return ["saved_password": false]

        case "show":
            let target = args["target"] as? String ?? "map"
            if target == "map" {
                selection = .map
            } else {
                guard cable(target) != nil else { throw ControlError("Unknown cable.") }
                selection = .cable(target)
            }
            NSApp.activate(ignoringOtherApps: true)
            return ["shown": target]

        case "remove-result":
            guard let cableID = args["cable"] as? String, let index = args["index"] as? Int else {
                throw ControlError("remove-result needs a cable and an index.")
            }
            guard let cable = cable(cableID), cable.results.indices.contains(index) else {
                throw ControlError("That result does not exist.")
            }
            change { try $0.deleteResult(at: index, of: cableID) }
            return Control.object(self.cable(cableID))

        default:
            throw ControlError("Unknown command “\(cmd)”.")
        }
    }

    private func summary(_ cable: Cable) -> [String: Any] {
        [
            "id": cable.id,
            "name": cable.name,
            "best_link": USBLink.short(cable.bestLink),
            "results": cable.results.count,
            "verdict": Readme.verdict(cable),
        ]
    }

    func jobObject() -> [String: Any] {
        var out: [String: Any] = [
            "cable": job.cableID ?? NSNull(),
            "steps": job.steps,
            "privacy_blocked": job.privacyBlocked,
        ]
        switch job.state {
        case .idle:
            out["state"] = "idle"
        case .running:
            out["state"] = passwordRequest == nil ? "running" : "waiting_for_password"
        case .done(let result):
            out["state"] = "done"
            out["result"] = Control.object(result)
            out["write_mbps"] = result.writeMBps.safeRoundedInt
            out["read_mbps"] = result.readMBps.safeRoundedInt
        case .failed(let message):
            out["state"] = "failed"
            out["error"] = message
        }
        return out
    }
}

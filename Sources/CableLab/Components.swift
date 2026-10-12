import CableLabCore
import SwiftUI

extension USBLink.Tier {
    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .slow: return .red
        case .mid: return .orange
        case .fast: return .green
        }
    }
}

struct LinkBadge: View {
    let bps: Int64?
    var untested = false

    var body: some View {
        let tier = untested ? .unknown : USBLink.tier(bps)
        Text(untested ? "untested" : USBLink.short(bps))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tier.color)
            .background(tier.color.opacity(0.14), in: Capsule())
            .help(untested ? "No test yet" : USBLink.name(bps))
    }
}

/// One line about the cable on a port: its saved name, else what its e-marker says.
func cableLine(_ identity: CableIdentity?, savedName: String?) -> String {
    guard let identity else { return "Cable: no e-marker" }
    if let savedName { return "Cable: \(savedName)" }
    return "Cable: \(identity.speedName), \(identity.ratedPower.isEmpty ? "?" : identity.ratedPower) (not saved)"
}

struct DeviceRow: View {
    let endpoint: Endpoint
    var savedCableName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: endpoint.kind == .disk ? "externaldrive.fill" : "gamecontroller.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.label).fontWeight(.medium).lineLimit(1)
                Text(endpoint.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if endpoint.port != nil {
                    Text(cableLine(endpoint.cable, savedName: savedCableName))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(endpoint.cable?.summary ?? "This cable has no e-marker chip, so it cannot describe itself.")
                }
            }
            Spacer(minLength: 4)
            LinkBadge(bps: endpoint.linkBps)
        }
        .padding(.vertical, 2)
    }
}

/// A USB-C port with something plugged in that is not a test device (a charger, an iPad, a display).
struct PortRow: View {
    let port: USBCPort
    var savedCableName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cable.connector").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Port \(port.number)" + (port.partner.map { ": \($0)" } ?? "")).fontWeight(.medium).lineLimit(1)
                Text(cableLine(port.cable, savedName: savedCableName))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(port.cable?.summary ?? "This cable has no e-marker chip, so it cannot describe itself.")
            }
        }
        .padding(.vertical, 2)
    }
}

struct DetectedBanner: View {
    @EnvironmentObject private var lab: LabModel
    let detected: DetectedCable

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: detected.identity == nil ? "cable.connector.slash" : "cable.connector")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if detected.isSuggestion {
                Button("Add Cable") { lab.addSuggested() }.buttonStyle(.borderedProminent)
            } else if detected.identity == nil {
                Button("Add Cable") {
                    lab.selection = .newCable
                    lab.dismissDetected()
                }
                .buttonStyle(.borderedProminent)
                .help("Open a new cable form: type the brand and ratings, press Return, then run a test")
            }
            if detected.isNew || detected.isSuggestion {
                Menu("This Is…") {
                    ForEach(lab.data.cables.filter { $0.id != detected.cableID && $0.emarker == nil }) { cable in
                        Button(cable.name) { lab.linkDetected(to: cable.id) }
                    }
                }
                .fixedSize()
                .help("Pick the saved cable this is. Its e-marker moves there and any new entry goes away.")
            }
            Button(detected.isSuggestion ? "Ignore" : "Dismiss") { lab.dismissDetected() }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: 820)
        .padding(.horizontal, 16)
    }

    private var title: String {
        guard detected.identity != nil else { return "Cable on port \(detected.port) has no e-marker chip" }
        if detected.isSuggestion { return "Unsaved cable on port \(detected.port)" }
        if detected.isNew { return "New cable on port \(detected.port). Cable Lab added it." }
        return "Port \(detected.port): \(lab.cable(detected.cableID)?.name ?? "known cable")"
    }

    private var detail: String {
        guard let identity = detected.identity else {
            return "The Mac got no answer from a cable chip. That is normal for 3 A (60 W) USB 2.0 cables, Apple’s 60 W charge cable included. 5 A (100 to 240 W) and 10 Gb/s or faster cables must have one. Add it by hand, then run a test."
        }
        if detected.isSuggestion {
            return "\(identity.summary). Add it, or use This Is… if you saved it before without an e-marker."
        }
        if detected.isNew {
            return "\(identity.summary). Type the brand and press Return; the name follows. Or use This Is… if you saved it before."
        }
        return "Recognized by its e-marker: \(identity.summary)."
    }
}

struct CableRow: View {
    let cable: Cable

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(cable.name).lineLimit(1)
                let sub = [cable.brand, cable.ratedData, cable.ratedPower].filter { !$0.isEmpty }.joined(separator: " · ")
                Text(sub.isEmpty ? "No details" : sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            LinkBadge(bps: cable.bestLink, untested: cable.results.isEmpty)
        }
    }
}

struct PasswordSheet: View {
    let request: PasswordRequest
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @AppStorage("rememberPassword") private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Administrator password", systemImage: "lock.fill").font(.headline)
            Text("The top folder of “\(request.endpoint.volume ?? "this disk")” belongs to root. Cable Lab runs the "
                 + "disk test through sudo, writes one test file, and deletes it.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if request.retry {
                Text("That password was not accepted. Try again.").foregroundStyle(.red)
            }
            SecureField("Mac password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            Toggle("Remember in my Keychain, so root tests do not ask again", isOn: $remember)
            Text("Cable Lab saves it only after sudo accepts it. Only Cable Lab can read it back. "
                 + "Remove it any time with Forget Saved Password on the Cable Map.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run Test", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let value = password
        password = ""
        onSubmit(value, remember)
    }
}

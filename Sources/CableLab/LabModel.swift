import AppKit
import CableLabCore
import Foundation

struct Job: Equatable {
    enum State: Equatable {
        case idle
        case running
        case done(CableResult)
        case failed(String)
    }

    var cableID: String?
    var state: State = .idle
    var steps: [String] = []
    var privacyBlocked = false

    var isRunning: Bool { state == .running }
}

/// A cable that was just plugged in, for the banner.
struct DetectedCable: Equatable {
    let port: Int
    let partner: String?
    let identity: CableIdentity?
    /// The saved cable it matched, or the one Cable Lab just added.
    let cableID: String?
    let isNew: Bool
}

struct PasswordRequest: Identifiable {
    let id = UUID()
    let cableID: String
    let endpoint: Endpoint
    let retry: Bool
}

@MainActor
final class LabModel: ObservableObject {
    @Published private(set) var data = CableData()
    @Published var endpoints: [Endpoint] = []
    @Published private(set) var job = Job()
    @Published var passwordRequest: PasswordRequest?
    @Published private(set) var repoURL: URL?
    @Published var problem: String?
    @Published var selection: SidebarItem? = .map
    @Published private(set) var hasSavedPassword = PasswordStore.hasPassword
    @Published private(set) var ports: [USBCPort] = []
    @Published var detected: DetectedCable?
    private var seenConnections: Set<String>?

    let host = HostInfo.model()
    var control: ControlServer?
    private var refreshing = false

    private static let repoKey = "repoPath"

    init() {
        repoURL = Self.initialRepo()
        reload()
        refreshEndpoints()
        startControlServer()
    }

    // MARK: Repo and data

    var dataURL: URL? { repoURL?.appendingPathComponent("data/cables.json") }
    var readmeURL: URL? { repoURL?.appendingPathComponent("README.md") }

    /// The folder the user picked, else the repo the app was built from (written into Info.plist).
    private static func initialRepo() -> URL? {
        let candidates = [UserDefaults.standard.string(forKey: repoKey),
                          Bundle.main.object(forInfoDictionaryKey: "MyCablesRepo") as? String]
        for case let path? in candidates where isRepo(URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func isRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("README.md").path)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("data").path)
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose your my-cables repo folder. It has README.md and a data folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.isRepo(url) else {
            problem = "That folder has no README.md and data folder."
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.repoKey)
        repoURL = url
        reload()
    }

    func reload() {
        guard let url = dataURL else { return }
        do {
            data = try CableData.load(from: url)
        } catch {
            problem = "Could not read data/cables.json: \(error.localizedDescription)"
        }
    }

    /// Apply a change, save the data file, and rebuild the README table.
    @discardableResult
    func change<T>(_ edit: (inout CableData) throws -> T) -> T? {
        guard let dataURL, let readmeURL else { return nil }
        var copy = data
        do {
            let result = try edit(&copy)
            try copy.save(to: dataURL)
            data = copy
            try Readme.render(copy, file: readmeURL)
            return result
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func cable(_ id: String?) -> Cable? {
        guard let id else { return nil }
        return data.cables.first { $0.id == id }
    }

    // MARK: Devices

    func refreshEndpoints() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let scan = Discovery.scan()
            await MainActor.run {
                self.apply(scan)
                self.refreshing = false
            }
        }
    }

    /// Scan now, on the main actor. For cablectl, which wants fresh answers.
    func rescanNow() {
        apply(Discovery.scan())
    }

    private func apply(_ scan: (endpoints: [Endpoint], ports: [USBCPort])) {
        if endpoints != scan.endpoints { endpoints = scan.endpoints }
        if ports != scan.ports { ports = scan.ports }
        noticeConnections(scan.ports)
    }

    // MARK: Cable detection

    /// React to plug-ins that happen while the app runs. Connections present at launch count as seen.
    private func noticeConnections(_ ports: [USBCPort]) {
        let live = ports.filter(\.connected)
        let ids = Set(live.map(\.connectionId))
        guard let seen = seenConnections else {
            seenConnections = ids
            return
        }
        for port in live where !seen.contains(port.connectionId) {
            detect(port)
        }
        seenConnections = ids
    }

    private func detect(_ port: USBCPort) {
        guard let identity = port.cable else {
            detected = DetectedCable(port: port.number, partner: port.partner, identity: nil, cableID: nil, isNew: false)
            return
        }
        if let match = data.cable(matching: identity) {
            detected = DetectedCable(port: port.number, partner: port.partner, identity: identity,
                                     cableID: match.id, isNew: false)
            if !job.isRunning && selection != .newCable { selection = .cable(match.id) }
            return
        }
        let date = Self.today()
        guard let newID = change({ try $0.addDetected(identity, date: date) }) else { return }
        detected = DetectedCable(port: port.number, partner: port.partner, identity: identity,
                                 cableID: newID, isNew: true)
        if !job.isRunning { selection = .cable(newID) }
    }

    /// The detected cable is one we already had: move its e-marker there, and drop the auto-added entry.
    func linkDetected(to existingID: String) {
        guard let d = detected, let identity = d.identity else { return }
        change { (data: inout CableData) throws -> Void in
            try data.link(identity, to: existingID)
            if d.isNew, let newID = d.cableID, newID != existingID,
               data.cables.first(where: { $0.id == newID })?.results.isEmpty == true {
                data.deleteCable(newID)
            }
        }
        selection = .cable(existingID)
        detected = nil
    }

    func dismissDetected() {
        detected = nil
    }

    // MARK: Tests

    func startTest(cableID: String, endpointID: String) {
        guard !job.isRunning, let ep = endpoints.first(where: { $0.id == endpointID }) else { return }
        job = Job(cableID: cableID, state: .running, steps: ["\(ep.label) linked at \(USBLink.name(ep.linkBps))."])
        // Check before the password prompt, so nobody types a password for a test that cannot run.
        if ep.isTimeMachine && Discovery.timeMachineRunning() {
            job.state = .failed(BenchError.backupRunning.localizedDescription)
            return
        }
        if ep.kind == .disk && Bench.diskNeedsRoot(ep) {
            if let saved = PasswordStore.load() {
                job.steps.append("The top folder of “\(ep.volume ?? "")” belongs to root. Using the password saved in the Keychain.")
                launch(cableID: cableID, endpoint: ep, password: saved, remember: false, fromKeychain: true)
                return
            }
            job.steps.append("The top folder of “\(ep.volume ?? "")” belongs to root. Waiting for your password.")
            passwordRequest = PasswordRequest(cableID: cableID, endpoint: ep, retry: false)
            return
        }
        launch(cableID: cableID, endpoint: ep, password: nil)
    }

    func submitPassword(_ password: String, remember: Bool) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        launch(cableID: request.cableID, endpoint: request.endpoint, password: password, remember: remember)
    }

    func forgetPassword() {
        PasswordStore.delete()
        hasSavedPassword = false
    }

    func cancelPassword() {
        passwordRequest = nil
        job.state = .failed("The test was cancelled.")
    }

    private func say(_ text: String) {
        job.steps.append(text)
    }

    private func launch(cableID: String, endpoint: Endpoint, password: String?,
                        remember: Bool = false, fromKeychain: Bool = false) {
        let helper = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let host = self.host
        let report: @Sendable (String) -> Void = { text in Task { @MainActor in self.say(text) } }
        Task.detached(priority: .userInitiated) {
            do {
                let numbers: BenchNumbers
                switch endpoint.kind {
                case .disk: numbers = try Bench.runDisk(endpoint, password: password, helper: helper, say: report)
                case .adb: numbers = try Bench.runADB(endpoint, say: report)
                }
                let result = CableResult(
                    date: Self.today(), endpoint: endpoint.label, kind: endpoint.kind.rawValue,
                    linkBps: endpoint.linkBps, host: host, bytes: numbers.bytes,
                    writeS: Self.round4(numbers.writeS), readS: Self.round4(numbers.readS))
                await MainActor.run {
                    // sudo accepted it, so it is safe to remember.
                    if remember, let password, PasswordStore.save(password) {
                        self.hasSavedPassword = true
                        self.say("Password saved in the Keychain. Root tests will not ask again.")
                    }
                    self.finish(cableID: cableID, result: result, endpoint: endpoint)
                }
            } catch BenchError.wrongPassword {
                await MainActor.run {
                    if fromKeychain {
                        self.forgetPassword()
                        self.say("The saved password no longer works, so it was removed from the Keychain.")
                    } else {
                        self.say("The password was not accepted.")
                    }
                    self.passwordRequest = PasswordRequest(cableID: cableID, endpoint: endpoint, retry: !fromKeychain)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } catch {
                await MainActor.run {
                    self.job.privacyBlocked = (error as? BenchError) == .blockedByPrivacy
                    self.job.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func finish(cableID: String, result: CableResult, endpoint: Endpoint) {
        let learn = endpoint.cable.flatMap { cable(cableID)?.emarker == nil ? $0 : nil }
        guard change({ (data: inout CableData) throws -> Void in
            try data.addResult(result, to: cableID)
            if let learn { try data.link(learn, to: cableID) }
        }) != nil else {
            job.state = .failed(problem ?? "Could not save the result.")
            return
        }
        let words = Readme.words(result.kind)
        say("Saved. \(Int(result.writeMBps.rounded())) MB/s \(words[0]), "
            + "\(Int(result.readMBps.rounded())) MB/s \(words[1]).")
        job.state = .done(result)
        refreshEndpoints()
    }

    nonisolated static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    nonisolated static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

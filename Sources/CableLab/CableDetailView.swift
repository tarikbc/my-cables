import CableLabCore
import SwiftUI

struct CableDetailView: View {
    @EnvironmentObject private var lab: LabModel
    let cableID: String?
    @Binding var selection: SidebarItem?

    @State private var fields = CableFields()
    @State private var confirmDelete = false

    private var cable: Cable? { lab.cable(cableID) }
    private var dirty: Bool { cable.map { CableFields($0) != fields } ?? !fields.name.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                GroupBox { editor.padding(8) } label: { Text("Details").font(.headline) }
                if let cable {
                    GroupBox { TestPanel(cable: cable).padding(8) } label: { Text("Test this cable").font(.headline) }
                    GroupBox { ResultsList(cable: cable).padding(8) } label: { Text("Results").font(.headline) }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle(cable?.name ?? "New Cable")
        .onAppear { fields = cable.map(CableFields.init) ?? CableFields() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(cable?.name ?? "New cable").font(.largeTitle.weight(.semibold))
                if let cable {
                    Text(Readme.verdict(cable)).foregroundStyle(.secondary)
                    if let e = cable.emarker {
                        Label("E-marker: \(e.summary)", systemImage: "cpu")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Label("No e-marker stored yet. A test stores it when the cable has one.", systemImage: "cpu")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if let cable { LinkBadge(bps: cable.bestLink, untested: cable.results.isEmpty).scaleEffect(1.3) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow { field("Name", "LTT USB-C cable", $fields.name).gridCellColumns(2) }
                GridRow {
                    field("Brand", "LTT Store", $fields.brand)
                    field("Ends", "USB-C to USB-C", $fields.ends)
                }
                GridRow {
                    field("Rated data", "40 Gb/s", $fields.ratedData)
                    field("Rated power", "240 W", $fields.ratedPower)
                }
                GridRow {
                    field("Length", "2 m", $fields.length)
                    field("How to spot it", "Black braid, orange tip", $fields.looks)
                }
                GridRow { field("Notes", "Came with the Insta360 X6", $fields.notes).gridCellColumns(2) }
            }
            HStack {
                if cable != nil {
                    Button("Delete Cable…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                if cable != nil && dirty {
                    Button("Revert") { fields = CableFields(cable!) }
                }
                Button(cable == nil ? "Add Cable" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || fields.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete “\(cable?.name ?? "")” and all its results?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = cableID { lab.change { $0.deleteCable(id) } }
                selection = .map
            }
        }
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func save() {
        if let id = lab.change({ try $0.upsert(id: cableID, fields: fields) }), cableID == nil {
            selection = .cable(id)
        } else if let cable {
            fields = CableFields(cable)
        }
    }
}

struct TestPanel: View {
    @EnvironmentObject private var lab: LabModel
    let cable: Cable
    @State private var endpointID: String?

    private var endpoint: Endpoint? { lab.endpoints.first { $0.id == endpointID } }
    private var job: Job? { lab.job.cableID == cable.id ? lab.job : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                Picker("Device on the other end", selection: $endpointID) {
                    if lab.endpoints.isEmpty { Text("No device connected").tag(String?.none) }
                    ForEach(lab.endpoints) { ep in
                        Text("\(ep.label) · \(USBLink.short(ep.linkBps))").tag(Optional(ep.id))
                    }
                }
                .disabled(lab.job.isRunning)
                Button {
                    if let endpointID { lab.startTest(cableID: cable.id, endpointID: endpointID) }
                } label: {
                    Label("Run Test", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(lab.job.isRunning || endpoint == nil)
            }
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let job { JobView(job: job) }
        }
        .onAppear(perform: pickDefault)
        .onChange(of: lab.endpoints) { pickDefault() }
    }

    private func pickDefault() {
        if endpoint == nil { endpointID = lab.endpoints.first?.id }
    }

    private var hint: String {
        guard let ep = endpoint else { return "Plug this cable between the Mac and the T7 or the Thor." }
        switch ep.kind {
        case .disk:
            return "Writes then reads \(Bench.diskTestSize(link: ep.linkBps) / Bench.gib) GiB on “\(ep.volume ?? "")”, "
                + "then deletes the file." + (ep.isTimeMachine ? " This is a Time Machine disk, so it needs your Mac password." : "")
        case .adb:
            return "Pushes 1 GiB of random data over adb, pulls it back, then deletes it."
        }
    }
}

struct JobView: View {
    @EnvironmentObject private var lab: LabModel
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            ForEach(Array(job.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    if index == job.steps.count - 1 && job.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                    Text(step)
                }
            }
            switch job.state {
            case .done(let r):
                let words = Readme.words(r.kind)
                HStack(spacing: 32) {
                    metric(String(format: "%.0f", r.writeMBps), "MB/s \(words[0])")
                    metric(String(format: "%.0f", r.readMBps), "MB/s \(words[1])")
                    metric(USBLink.short(r.linkBps), "USB link")
                }
                .padding(.top, 4)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if job.privacyBlocked {
                    Button("Open Full Disk Access Settings") { lab.openFullDiskAccessSettings() }
                }
            default:
                EmptyView()
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit()
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

struct ResultsList: View {
    @EnvironmentObject private var lab: LabModel
    let cable: Cable
    @State private var pendingDelete: Int?

    var body: some View {
        if cable.results.isEmpty {
            Text("No results yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(["Date", "Device", "Link", "Write / push", "Read / pull", ""], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(Array(cable.results.enumerated()), id: \.offset) { index, r in
                    GridRow {
                        Text(r.date).monospacedDigit()
                        Text(r.endpoint)
                        LinkBadge(bps: r.linkBps)
                        Text(String(format: "%.0f MB/s", r.writeMBps)).monospacedDigit()
                        Text(String(format: "%.0f MB/s", r.readMBps)).monospacedDigit()
                        Button("Remove") { pendingDelete = index }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .confirmationDialog("Remove this result?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Remove", role: .destructive) {
                    if let i = pendingDelete { lab.change { try $0.deleteResult(at: i, of: cable.id) } }
                    pendingDelete = nil
                }
            }
        }
    }
}

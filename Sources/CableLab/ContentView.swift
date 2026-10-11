import CableLabCore
import Combine
import SwiftUI

enum SidebarItem: Hashable {
    case map
    case newCable
    case cable(String)
}

struct ContentView: View {
    @EnvironmentObject private var lab: LabModel
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button { lab.refreshEndpoints() } label: { Label("Refresh Devices", systemImage: "arrow.clockwise") }
                    .help("Read the USB links again")
                Button { lab.selection = .newCable } label: { Label("New Cable", systemImage: "plus") }
                    .help("Add a cable")
                    .disabled(lab.repoURL == nil)
            }
        }
        .onReceive(tick) { _ in
            if !lab.job.isRunning { lab.refreshEndpoints() }
        }
        .sheet(item: $lab.passwordRequest) { request in
            PasswordSheet(request: request, onSubmit: lab.submitPassword, onCancel: lab.cancelPassword)
                .interactiveDismissDisabled()
        }
        .alert("Cable Lab", isPresented: Binding(get: { lab.problem != nil }, set: { if !$0 { lab.problem = nil } })) {
            Button("OK") { lab.problem = nil }
        } message: {
            Text(lab.problem ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $lab.selection) {
            Section("Connected now") {
                if lab.endpoints.isEmpty {
                    Text("No external disk or adb device. Plug a cable between this Mac and the T7 or the Thor.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lab.endpoints) { ep in
                        DeviceRow(endpoint: ep, savedCableName: ep.cable.flatMap { lab.data.cable(matching: $0)?.name })
                    }
                }
                ForEach(otherPorts) { port in
                    PortRow(port: port, savedCableName: port.cable.flatMap { lab.data.cable(matching: $0)?.name })
                }
            }
            Section("Overview") {
                Label("Cable Map", systemImage: "tablecells").tag(SidebarItem.map)
            }
            Section("Cables") {
                ForEach(lab.data.cables) { cable in
                    CableRow(cable: cable).tag(SidebarItem.cable(cable.id))
                }
                if lab.data.cables.isEmpty {
                    Text("No cables yet.").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Connected ports that are not already shown as a test device.
    private var otherPorts: [USBCPort] {
        let used = Set(lab.endpoints.compactMap(\.port))
        return lab.ports.filter { $0.connected && !used.contains($0.number) }
    }

    @ViewBuilder
    private var detail: some View {
        // An overlay never changes the column's size, so the split view keeps its layout.
        detailContent
            .overlay(alignment: .bottom) {
                if let detected = lab.detected {
                    DetectedBanner(detected: detected)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: lab.detected)
    }

    @ViewBuilder
    private var detailContent: some View {
        if lab.repoURL == nil {
            ContentUnavailableView {
                Label("Choose the my-cables folder", systemImage: "folder")
            } description: {
                Text("Cable Lab saves results to data/cables.json and README.md in your my-cables repo.")
            } actions: {
                Button("Choose Folder…") { lab.chooseRepo() }.buttonStyle(.borderedProminent)
            }
        } else {
            switch lab.selection {
            case .cable(let id) where lab.cable(id) != nil:
                CableDetailView(cableID: id, selection: $lab.selection).id(id)
            case .newCable:
                CableDetailView(cableID: nil, selection: $lab.selection).id("new")
            default:
                CableMapView()
            }
        }
    }
}

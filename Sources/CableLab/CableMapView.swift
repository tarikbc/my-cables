import AppKit
import CableLabCore
import SwiftUI

struct CableMapView: View {
    @EnvironmentObject private var lab: LabModel

    var body: some View {
        let cables = Readme.sorted(lab.data.cables)
        let columns = Readme.columns(cables)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cable Map").font(.largeTitle.weight(.semibold))
                    Text("What each cable negotiated with this Mac, and how fast it really moved data.")
                        .foregroundStyle(.secondary)
                }
                if cables.isEmpty {
                    Text("No cables yet. Click + to add the first one.").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
                            GridRow {
                                ForEach(["Cable", "How to spot it", "Rated", "E-marker says", "Best link"]
                                        + columns.map(\.title) + ["Verdict"],
                                        id: \.self) {
                                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            ForEach(cables) { cable in
                                GridRow(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cable.name).fontWeight(.semibold)
                                        if !cable.brand.isEmpty {
                                            Text(cable.brand).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    dim(cable.looks)
                                    dim(Readme.rated(cable))
                                    dim(Readme.emarker(cable))
                                    if cable.results.isEmpty { dim("") } else { LinkBadge(bps: cable.bestLink) }
                                    ForEach(columns, id: \.self) { col in
                                        if let b = Readme.best(cable, col) {
                                            Text(String(format: "%.0f / %.0f", b.writeMBps, b.readMBps)).monospacedDigit()
                                        } else {
                                            dim("")
                                        }
                                    }
                                    Text(Readme.verdict(cable))
                                        .frame(maxWidth: 210, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Divider()
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    Text("MB/s means 1,000,000 bytes per second. Each cell is the best run. "
                         + "Cable Lab writes the same table into README.md after every change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let repo = lab.repoURL {
                    HStack {
                        Text(repo.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        if lab.hasSavedPassword {
                            Button("Forget Saved Password") { lab.forgetPassword() }
                                .help("Delete the Mac password that Cable Lab saved in your Keychain")
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repo]) }
                        Button("Change Folder…") { lab.chooseRepo() }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Cable Map")
    }

    private func dim(_ text: String) -> some View {
        Text(text.isEmpty ? "–" : text).foregroundStyle(text.isEmpty ? .tertiary : .primary)
    }
}

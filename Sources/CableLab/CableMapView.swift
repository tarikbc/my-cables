import AppKit
import CableLabCore
import SwiftUI

/// The ranked cable map: summary tiles, then one card per cable, best first (see Ranking).
struct CableMapView: View {
    @EnvironmentObject private var lab: LabModel

    var body: some View {
        let cables = Ranking.ranked(lab.data.cables)
        let columns = Readme.columns(cables)
        let scale = Dictionary(uniqueKeysWithValues: columns.map { col in
            (col, cables.compactMap { Readme.best($0, col) }.map { max($0.writeMBps, $0.readMBps) }.max() ?? 1)
        })
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cable Map").font(.largeTitle.weight(.semibold))
                    Text("Best cable first: fastest link, then what the cable can carry, then measured speed.")
                        .foregroundStyle(.secondary)
                }
                if cables.isEmpty {
                    ContentUnavailableView("No cables yet", systemImage: "cable.connector",
                                           description: Text("Plug one in, or click + to add it."))
                } else {
                    SummaryTiles(cables: cables)
                    VStack(spacing: 10) {
                        ForEach(Array(cables.enumerated()), id: \.element.id) { index, cable in
                            CableCard(rank: index + 1, cable: cable, columns: columns, scale: scale)
                                .onTapGesture { lab.selection = .cable(cable.id) }
                        }
                    }
                    Text("Bars compare cables on the same device. MB/s means 1,000,000 bytes per second, best run "
                         + "shown. Cable Lab writes the same ranking into README.md after every change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keep the last card clear of the floating cable banner.
        .contentMargins(.bottom, lab.detected == nil ? 0 : 110, for: .scrollContent)
        .navigationTitle("Cable Map")
    }

    @ViewBuilder
    private var footer: some View {
        if let repo = lab.repoURL {
            HStack {
                Text(repo.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1)
                Spacer()
                if lab.hasSavedPassword {
                    Button("Forget Saved Password") { lab.forgetPassword() }
                        .help("Delete the Mac password that Cable Lab saved in your Keychain")
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repo]) }
                Button("Change Folder…") { lab.chooseRepo() }
            }
            .controlSize(.small)
        }
    }
}

private struct SummaryTiles: View {
    let cables: [Cable]

    var body: some View {
        let tested = cables.filter { !$0.results.isEmpty }
        let fast = tested.filter { ($0.bestLink ?? 0) >= 10_000_000_000 }.count
        let slow = tested.filter { ($0.bestLink ?? 0) <= 480_000_000 }.count
        HStack(spacing: 10) {
            tile("\(cables.count)", "cables mapped", .accentColor)
            tile("\(fast)", "full speed (10 Gb/s)", .green)
            tile("\(slow)", "USB 2.0 only", .red)
            tile("\(cables.count - tested.count)", "not tested yet", .secondary)
        }
    }

    private func tile(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }
}

private struct CableCard: View {
    let rank: Int
    let cable: Cable
    let columns: [Readme.Column]
    let scale: [Readme.Column: Double]
    @State private var hover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                identity.frame(minWidth: 280, maxWidth: 400, alignment: .leading)
                Spacer(minLength: 0)
                measurements.frame(width: 330)
            }
            VStack(alignment: .leading, spacing: 14) {
                identity
                measurements
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(hover ? 0.075 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0 }
        .help("Open \(cable.name)")
    }

    private var tier: USBLink.Tier { cable.results.isEmpty ? .unknown : USBLink.tier(cable.bestLink) }

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(rank)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 34, height: 34)
                .foregroundStyle(rank == 1 ? Color.white : Color.secondary)
                .background(Circle().fill(rank == 1 ? Color.accentColor : Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cable.name).font(.title3.weight(.semibold)).lineLimit(1)
                    LinkBadge(bps: cable.bestLink, untested: cable.results.isEmpty)
                }
                let sub = Readme.brandAndLength(cable)
                if !sub.isEmpty {
                    Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if !Readme.rated(cable).isEmpty { chip("Rated", Readme.rated(cable), "tag") }
                    if let e = cable.emarker {
                        chip("Chip", [e.ratedData, e.ratedPower].filter { !$0.isEmpty }.joined(separator: " · "), "cpu")
                            .help(e.summary)
                    }
                }
                Text(Readme.verdict(cable))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tier == .unknown ? Color.secondary : tier.color)
            }
        }
    }

    private func chip(_ title: String, _ value: String, _ symbol: String) -> some View {
        Label {
            Text(title).foregroundStyle(.secondary) + Text(" \(value)")
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 12) {
            if columns.isEmpty || cable.results.isEmpty {
                Text("Not tested yet. Open it and click Run Test.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(columns, id: \.self) { col in
                    MeasureBlock(column: col, result: Readme.best(cable, col), scale: scale[col] ?? 1)
                }
            }
        }
    }
}

private struct MeasureBlock: View {
    let column: Readme.Column
    let result: CableResult?
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(column.device).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let result {
                let words = Readme.words(column.kind)
                let color = USBLink.tier(result.linkBps).color
                bar(words[0], result.writeMBps, color)
                bar(words[1], result.readMBps, color)
            } else {
                Text("Not tested on this device").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func bar(_ word: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(word).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.gradient)
                        .frame(width: max(4, geo.size.width * min(1, value / max(scale, 1))))
                }
            }
            .frame(height: 8)
            Text("\(value.safeRoundedInt) MB/s")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
        }
    }
}

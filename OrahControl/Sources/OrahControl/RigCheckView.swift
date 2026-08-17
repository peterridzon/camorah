import SwiftUI
import AppKit
import OrahKit

/// The screen for the hours before a show, while cameras are being hung.
///
/// It answers one question continuously — what is ready, what is not, and what
/// is actually wrong — and it does it from a roster, because the thing that
/// matters most on a rig day is the camera that is **not** there, which no
/// amount of discovery can tell you.
@MainActor
struct RigCheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rig = model.rig
        VStack(spacing: 0) {
            strip(rig.summary)

            if model.roster.entries.isEmpty {
                emptyRoster
            } else {
                HStack(spacing: 0) {
                    ScrollView { nodes(rig.positions) }
                        .frame(maxWidth: .infinity)

                    Rectangle().fill(Theme.line).frame(width: 1)

                    ScrollView { rail(rig) }
                        .frame(width: 330)
                }
            }
        }
        .background(Theme.bg)
    }

    // MARK: - The one line that decides

    private func strip(_ summary: RigSummary) -> some View {
        HStack(spacing: 26) {
            stat("Expected", "\(summary.expected)", Theme.fg)
            stat("Ready", "\(summary.ready)", Theme.yellow)
            stat("Working on it", "\(summary.working)", Theme.orange)
            stat("Not there", "\(summary.absent)", Theme.red)
            if summary.beingFixed > 0 {
                stat("Being fixed", "\(summary.beingFixed)", Theme.orange)
            }

            Spacer()

            Text(summary.verdict)
                .font(Theme.value(12))
                .foregroundStyle(summary.isReady ? Theme.yellow : Theme.orange)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(summary.isReady ? Theme.yellow : Theme.orange, lineWidth: 1)
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func stat(_ key: String, _ value: String, _ colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key.uppercased())
                .font(Theme.label(9.5)).tracking(1.8)
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(Theme.value(15))
                .foregroundStyle(colour)
        }
    }

    // MARK: - Cameras, grouped by node

    private func nodes(_ positions: [RigPosition]) -> some View {
        let grouped = Dictionary(grouping: positions) { $0.nodeID }
        let order = grouped.keys.sorted { ($0 ?? .max) < ($1 ?? .max) }

        return VStack(alignment: .leading, spacing: 18) {
            ForEach(order, id: \.self) { node in
                let cameras = (grouped[node] ?? []).sorted { $0.number < $1.number }
                let dark = cameras.count > 1 && cameras.allSatisfy { $0.state == .absent }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(node.map { String(format: "N%02d", $0) } ?? "UNASSIGNED")
                            .font(Theme.value(12))
                            .foregroundStyle(Theme.fg)
                        Text("\(cameras.count) cameras")
                            .font(Theme.value(10.5))
                            .foregroundStyle(Theme.faint)
                        Rectangle().fill(Theme.line).frame(height: 1)

                        // Four failures behind one node is one fault. Said here
                        // rather than left to be worked out from four tiles.
                        if dark {
                            Text("ALL DARK — LOOK AT THE NODE, NOT THE CAMERAS")
                                .font(Theme.label(9.5)).tracking(0.8)
                                .foregroundStyle(Theme.red)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 7)], spacing: 7) {
                        ForEach(cameras) { position in
                            RigTile(position: position)
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - What to do next

    private func rail(_ rig: (positions: [RigPosition], summary: RigSummary)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO DO NEXT")
                .font(Theme.label(10)).tracking(2.2)
                .foregroundStyle(Theme.faint)

            // Whole nodes first: they explain the most failures at once.
            ForEach(rig.summary.darkNodes, id: \.self) { node in
                issue(colour: Theme.red,
                      title: String(format: "N%02d — every camera dark", node),
                      body: "Four failures behind one node is one fault, not four. "
                          + "Check its power and uplink before touching a camera on it.")
            }

            ForEach(rig.positions.filter { $0.state.isFault || $0.state == .beingFixed(sinceSeconds: 0) || isFixing($0) }) { position in
                issue(colour: isFixing(position) ? Theme.orange : Theme.red,
                      title: "Camera \(position.number)\(position.position.isEmpty ? "" : " · \(position.position)")",
                      body: advice(for: position))
            }

            if !model.unassignedCameras.isEmpty {
                Text("ON THE NETWORK, NOT IN THE ROSTER")
                    .font(Theme.label(10)).tracking(2.2)
                    .foregroundStyle(Theme.faint)
                    .padding(.top, 12)

                ForEach(model.unassignedCameras, id: \.serial) { stranger in
                    UnassignedRow(serial: stranger.serial, host: stranger.host)
                }
            }
        }
        .padding(16)
    }

    private func isFixing(_ position: RigPosition) -> Bool {
        if case .beingFixed = position.state { return true }
        return false
    }

    private func advice(for position: RigPosition) -> String {
        switch position.state {
        case .absent:
            return "Nothing at this address and nothing with Orah's MAC prefix on the "
                 + "network. Power first — PoE, and the injector's data side into the switch."
        case .linkFault(let loss):
            return String(format: "%.0f %% of packets lost while the router answers cleanly. ", loss)
                 + "That is this camera's own run — cable, then switch port."
        case .beingFixed:
            return "Marked as yours. Nothing is being sent to it. Clear the mark and "
                 + "it is checked again from the top."
        default:
            return position.state.label
        }
    }

    private func issue(colour: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.value(11.5))
                .foregroundStyle(Theme.fg)
            Text(body)
                .font(Theme.value(11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(colour).frame(width: 2) }
        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - No roster yet

    private var emptyRoster: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("NO ROSTER")
                .font(Theme.label(11)).tracking(2.2)
                .foregroundStyle(Theme.dim)
            Text("A rig check needs to know which cameras to expect. Without that it can\nonly report what it found, and the camera that is missing is the point.")
                .font(Theme.value(12))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)

            Button {
                model.seedRosterFromRecords()
                if model.needsRecordsFolder { chooseRecordsFolder() }
            } label: {
                Text("BUILD FROM CHECKED CAMERAS")
                    .font(Theme.label(10)).tracking(1.4)
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(Theme.orange, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Text("They are written by `orahctl checkout` into camera-records/.")
                .font(Theme.value(10.5))
                .foregroundStyle(Theme.dead)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The app cannot guess where the repository is, so it asks once.
    private func chooseRecordsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Where are the camera records?"
        panel.message = "Choose the camera-records folder that `orahctl checkout` writes to."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        model.needsRecordsFolder = false
        model.seedRosterFromRecords(from: chosen)
    }
}

// MARK: - One position

@MainActor
private struct RigTile: View {
    @Environment(AppModel.self) private var model
    let position: RigPosition

    private var colour: Color {
        switch position.state {
        case .ready:                 Theme.yellow
        case .absent, .linkFault:    Theme.red
        case .beingFixed:            Theme.orange
        default:                     Theme.orange
        }
    }

    private var isFixing: Bool {
        if case .beingFixed = position.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%02d", position.number))
                    .font(Theme.value(15).weight(.bold))
                    .foregroundStyle(colour)
                Text(position.position.isEmpty ? (position.serial ?? "—") : position.position)
                    .font(Theme.value(10.5))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)

                Button { model.toggleFixing(position.number) } label: {
                    Text(isFixing ? "FIXING" : "FIX")
                        .font(Theme.label(8)).tracking(0.8)
                        .foregroundStyle(isFixing ? Theme.bg : Theme.faint)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background { if isFixing { Theme.orange } }
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(isFixing ? Theme.orange : Theme.dead, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
            }

            Text(position.state.label.uppercased())
                .font(Theme.label(9.5)).tracking(1.3)
                .foregroundStyle(colour)
                .padding(.top, 7)

            Text(position.state.detail(roundTrip: position.roundTripMilliseconds,
                                       lenses: position.lensesArriving))
                .font(Theme.value(10))
                .foregroundStyle(Theme.faint)
                .padding(.top, 3)

            // Four marks, one per lens. Half a camera is a real state.
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < position.lensesArriving ? Theme.yellow : Theme.dead)
                        .frame(height: 3)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(position.state == .absent ? Theme.panel : Theme.raised)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(colour.opacity(position.state == .ready ? 0.55 : 0.8),
                              style: StrokeStyle(lineWidth: 1,
                                                 dash: position.state == .absent || isFixing ? [3, 3] : []))
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Cameras the roster does not know

@MainActor
private struct UnassignedRow: View {
    @Environment(AppModel.self) private var model
    let serial: String
    let host: String

    @State private var number = ""

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(serial)
                    .font(Theme.value(11))
                    .foregroundStyle(Theme.fg)
                Text(host)
                    .font(Theme.value(9.5))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)

            TextField("no.", text: $number)
                .textFieldStyle(.plain)
                .font(Theme.value(11))
                .frame(width: 34)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .overlay { RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1) }

            Button {
                guard let value = Int(number) else { return }
                model.install(serial: serial, at: value)
                number = ""
            } label: {
                Text("INSTALL")
                    .font(Theme.label(8.5)).tracking(0.8)
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .disabled(Int(number) == nil)
            .opacity(Int(number) == nil ? 0.4 : 1)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

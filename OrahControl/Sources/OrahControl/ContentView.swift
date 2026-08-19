import SwiftUI
import OrahKit

/// The operating screen.
///
/// Laid out the way the job runs, left to right: what goes next, the action that
/// puts it there, what is out. Setup lives elsewhere and stays out of the way
/// once a show starts.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip()
            Divider().overlay(Theme.line)

            switch model.screen {
            case .rigCheck:
                RigCheckView()
            case .colour:
                ColourView()
            case .desk:
                // Multiview over console, the way the eye works: what is
                // available, then what puts it to air. The rail keeps the parts
                // of setup that a show still needs at hand.
                HStack(spacing: 0) {
                    // Both axes: the desk is wider than some windows, and
                    // clipping the left of it is worse than a scrollbar.
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 12) {
                            // The strip stays whatever happens to the panes —
                            // it is how a generator on another screen is called
                            // back, and it cannot live inside the thing it
                            // opens.
                            MultiviewTabs()

                            // Multiview 1 lives here until it is pulled onto a
                            // screen of its own; then the console moves up into
                            // the space rather than leaving a hole where a wall
                            // used to be.
                            if model.showsInlineMultiview { MultiviewPane(generator: 1) }
                            ConsoleView()
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().overlay(Theme.line)
                    ControlRail().frame(width: 250)
                }
            }

            Divider().overlay(Theme.line)
            SignalChain()
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}

// MARK: - Status strip

private struct StatusStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 20) {
            // First thing in the bar: which of the two jobs this is.
            ModeSwitch()

            Stat(label: "Cameras",
                 value: "\(model.camerasStreaming)/\(model.cameras.count)",
                 lit: !model.cameras.isEmpty)

            Stat(label: "Nodes",
                 value: "\(model.nodesOnline)/\(model.nodes.count)",
                 lit: model.nodesOnline == model.nodes.count && !model.nodes.isEmpty,
                 warn: model.nodesOnline < model.nodes.count)

            if let shortest = model.shortestNodeSeconds {
                Stat(label: "Shortest",
                     value: shortest > 3600
                        ? "\(shortest / 3600)h \((shortest % 3600) / 60)m"
                        : "\(shortest / 60)m",
                     lit: shortest > 7200,
                     warn: shortest <= 7200)
            }

            Spacer()

            LoadMeters()

            // The output monitor belongs one click away, not buried in a menu:
            // it is the only place the encoded result can actually be judged.
            OpenOutputMonitorButton()

            if let error = model.lastError {
                Text(error)
                    .font(Theme.value(11))
                    .foregroundStyle(Theme.red)
                    .lineLimit(1)
            }

            if model.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(Theme.red).frame(width: 7, height: 7)
                    Text("REC \(model.recordingDuration)")
                        .font(Theme.value(11).weight(.semibold))
                }
                .foregroundStyle(Theme.red)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(Theme.red, lineWidth: 1) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Theme.panel)
    }

    /// CPU and GPU, as bars rather than numbers.
    ///
    /// The number is there too, but the bar is what gets read across a gallery
    /// — and what matters is not 61% or 64%, it is whether the machine still
    /// has room before another camera is plugged in. Amber up to three
    /// quarters, then it goes hot, which is the same language the rest of the
    /// desk uses for "this is fine" and "look at this".
    struct LoadMeters: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            HStack(spacing: 12) {
                Meter(label: "CPU", value: model.load.cpu)
                Meter(label: "GPU", value: model.load.gpu)
            }
        }

        struct Meter: View {
            let label: String
            /// Absent when the machine will not say — drawn dark rather than
            /// drawn as zero, because zero is a claim and this is a shrug.
            let value: Double?

            private var colour: Color {
                guard let value else { return Theme.dead }
                return value > 0.9 ? Theme.red : value > 0.75 ? Theme.yellow : Theme.orange
            }

            var body: some View {
                HStack(spacing: 6) {
                    Text(label)
                        .font(Theme.label(10)).tracking(1.1)
                        .foregroundStyle(Theme.dim)

                    HStack(spacing: 1.5) {
                        ForEach(0..<12, id: \.self) { cell in
                            let lit = Double(cell) < (value ?? 0) * 12
                            RoundedRectangle(cornerRadius: 1)
                                .fill(lit ? colour : Theme.line)
                                .frame(width: 4, height: 10)
                        }
                    }

                    Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(Theme.value(11).weight(.semibold))
                        .foregroundStyle(value == nil ? Theme.dim : Theme.fg)
                        .frame(width: 38, alignment: .trailing)
                        .monospacedDigit()
                }
                // The whole machine, not this app — which is the number that
                // decides whether another camera can be plugged in.
                .help("\(label) load across the whole Mac")
            }
        }
    }

    struct Stat: View {
        let label: String
        let value: String
        var lit = false
        var warn = false

        var body: some View {
            HStack(spacing: 7) {
                Circle()
                    .fill(warn ? Theme.orange : (lit ? Theme.orange : Theme.dead))
                    .frame(width: 7, height: 7)
                Text(label.uppercased())
                    .font(Theme.label(10)).tracking(1.1)
                    .foregroundStyle(Theme.dim)
                Text(value)
                    .font(Theme.value(12).weight(.semibold))
                    .foregroundStyle(warn ? Theme.yellow : Theme.fg)
            }
        }
    }
}

// MARK: - Desk

@MainActor
private struct DeskView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Desk", trailing: "only these two cameras are decoded")

            HStack(alignment: .top, spacing: 12) {
                Monitor(role: .preview,
                        title: label(for: model.previewSlot),
                        detail: detail(for: model.previewSlot),
                        sink: model.previewSink,
                        lens: model.previewLens,
                        hasSignal: model.previewHasPicture,
                        phase: model.state(slot: model.previewSlot),
                        startedAt: model.startingSince(slot: model.previewSlot),
                        lensesArriving: model.camera(slot: model.previewSlot)?.lensesArriving ?? 0,
                        step: model.startingStep(slot: model.previewSlot))

                TakeColumn().frame(width: 176)

                Monitor(role: .program,
                        title: label(for: model.programSlot),
                        detail: detail(for: model.programSlot),
                        sink: model.programSink,
                        lens: model.programLens,
                        hasSignal: model.programHasPicture,
                        phase: model.state(slot: model.programSlot),
                        startedAt: model.startingSince(slot: model.programSlot),
                        lensesArriving: model.camera(slot: model.programSlot)?.lensesArriving ?? 0,
                        step: model.startingStep(slot: model.programSlot))
            }
        }
    }

    private func label(for slot: Int?) -> String {
        guard let camera = model.camera(slot: slot) else { return "—" }
        return String(format: "CAM %02d · %@", camera.slot, camera.name)
    }

    private func detail(for slot: Int?) -> String {
        guard let camera = model.camera(slot: slot) else { return "no camera selected" }
        return camera.isStreaming
            ? "1920×1440 · 29.97p · delay \(Int(camera.delayMilliseconds)) ms"
            : "not streaming"
    }
}

/// Take, the transition selector, and the T-bar — the same 0…1 value, three ways
/// of driving it.
private struct TakeColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 8) {
            Text("TRANSITION")
                .font(Theme.label(9)).tracking(1.4)
                .foregroundStyle(Theme.faint)

            HStack(spacing: 4) {
                ForEach([("FADE", false), ("CUT", true)], id: \.0) { name, isCut in
                    Text(name)
                        .font(Theme.label(9)).tracking(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(model.transitionIsCut == isCut ? Theme.raised : .clear)
                        .foregroundStyle(model.transitionIsCut == isCut ? Theme.orange : Theme.dim)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(model.transitionIsCut == isCut ? Theme.orange : Theme.line,
                                        lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture { model.transitionIsCut = isCut }
                }
            }

            HStack(spacing: 8) {
                Button { model.take() } label: {
                    Text("TAKE")
                        .font(.system(size: 15, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.program)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(model.previewSlot == nil)

                TBar(mix: Binding(get: { model.mix }, set: { model.setMix($0) }))
                    .frame(width: 58)
            }
            .frame(height: 104)

            Text(model.transitionIsCut
                 ? "instant"
                 : "\(Int(model.transitionMilliseconds)) ms · or by hand")
                .font(Theme.label(9)).tracking(1.0)
                .foregroundStyle(Theme.faint)
        }
    }
}

/// The T-bar. Take runs the dissolve on a timer; this runs it on your wrist.
/// Underneath they are the same number, so the bar costs nothing extra.
private struct TBar: View {
    @Binding var mix: Double

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.height - 26

            VStack(spacing: 6) {
                Text("PST").font(Theme.label(7.5)).tracking(1.4).foregroundStyle(Theme.dim)

                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.line).frame(width: 8)
                    Capsule().fill(Theme.orange)
                        .frame(width: 8, height: max(0, travel * mix))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Theme.yellow, Theme.orange],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 42, height: 18)
                        .overlay {
                            VStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Rectangle().fill(.black.opacity(0.45)).frame(height: 1)
                                }
                            }
                            .frame(width: 20)
                        }
                        .offset(y: -travel * mix)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let fromBottom = geometry.size.height - value.location.y - 13
                                    mix = min(max(fromBottom / travel, 0), 1)
                                })
                }
                .frame(maxHeight: .infinity)

                Text("PGM").font(Theme.label(7.5)).tracking(1.4).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.35))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Theme.lineHi, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Start or stop this camera on its own.
@MainActor
private struct SoloButton: View {
    @Environment(AppModel.self) private var model
    let camera: AppModel.Camera

    /// Running means pictures are arriving, not that somebody pressed Start.
    ///
    /// A camera resumes streaming on its own after a power cut, and the app
    /// adopts it — so it can be live without this session ever having asked.
    /// Reading the button off the request rather than the pictures makes it
    /// offer to start a camera that is already on air.
    private var isRunning: Bool { model.isRunning(slot: camera.slot) }

    var body: some View {
        Button {
            if isRunning { model.stopCamera(camera.slot) }
            else { model.startCamera(camera.slot) }
        } label: {
            Text(isRunning ? "STOP" : "START")
                .font(Theme.label(8)).tracking(0.9)
                .foregroundStyle(isRunning ? Theme.red : Theme.orange)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isRunning ? Theme.red : Theme.orange, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(camera.state == .disconnected)
        .opacity(camera.state == .disconnected ? 0.35 : 1)
    }
}

/// Desk or rig check.
///
/// The same app and the same data, an hour apart: rigging is about what is
/// missing, the show is about what is on air. One window, two questions.
@MainActor
private struct ModeSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Strip {
            StripButton(title: "DESK", selected: model.screen == .desk) {
                model.setScreen(.desk)
            }
            StripButton(title: "COLOUR", selected: model.screen == .colour) {
                model.setScreen(.colour)
            }
            StripButton(title: "RIG CHECK", selected: model.screen == .rigCheck) {
                model.setScreen(.rigCheck)
            }
        }
    }

}

/// Opens the window showing the four lanes that leave for the stitcher.
@MainActor
private struct OpenOutputMonitorButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: OrahControlApp.outputMonitorWindow)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 9, weight: .semibold))
                Text("OUTPUT")
                    .font(Theme.label(9)).tracking(1.2)
            }
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Multiview

private struct MultiviewGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 7)]

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                SectionLabel(text: "Multiview")
                HStack(spacing: 5) {
                    Text("LENS").font(Theme.label(9)).foregroundStyle(Theme.faint)
                    ForEach(Array(Switcher.lenses.enumerated()), id: \.offset) { index, lens in
                        Text(lens)
                            .font(Theme.label(9)).tracking(0.6)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(model.multiviewLens == index ? Theme.orange : Theme.dim)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(model.multiviewLens == index ? Theme.orange : Theme.line,
                                            lineWidth: 1)
                            }
                            .onTapGesture { model.multiviewLens = index }
                    }
                }
            }

            if model.cameras.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text("LOOKING FOR CAMERAS")
                            .font(Theme.label(11)).tracking(1.8)
                            .foregroundStyle(Theme.dim)
                        Text("They announce themselves over Bonjour once powered.")
                            .font(Theme.value(11))
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer()
                }
                .padding(.vertical, 34)
            } else {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(model.cameras) { camera in
                        CameraTile(camera: camera)
                            .onTapGesture { model.selectPreview(camera.slot) }
                    }
                }
            }
        }
    }
}

@MainActor
private struct CameraTile: View {
    @Environment(AppModel.self) private var model
    let camera: AppModel.Camera

    private var isProgram: Bool { camera.slot == model.programSlot }
    private var isPreview: Bool { camera.slot == model.previewSlot }

    private var edge: Color {
        if isProgram { Theme.program }
        else if isPreview { Theme.preview }
        else if camera.isStreaming { Theme.lineHi }
        else { Theme.line }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(camera.isStreaming ? Theme.raised : Theme.panel)
                    .aspectRatio(1440.0/1920.0, contentMode: .fit)

                if !camera.isStreaming || camera.lensesArriving < 4 {
                    StartupStatus(phase: model.state(slot: camera.slot),
                                  startedAt: model.startingSince(slot: camera.slot),
                                  lensesArriving: camera.lensesArriving,
                                  step: model.startingStep(slot: camera.slot),
                                  compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // A camera carrying a correction has to admit it here. Otherwise
                // one camera going out differently shaded from the rest is
                // invisible until somebody notices it on air.
                if model.gradedSlots.contains(camera.slot) {
                    Text("CC")
                        .font(Theme.label(7.5)).tracking(0.8)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Theme.amber)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                }

                if isProgram || isPreview {
                    Text(isProgram ? "ON AIR" : "PREVIEW")
                        .font(Theme.label(8)).tracking(1.1)
                        .foregroundStyle(isProgram ? .white : Theme.preview)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background { if isProgram { Theme.program } else { Color.black.opacity(0.7) } }
                        .overlay {
                            if isPreview {
                                RoundedRectangle(cornerRadius: 2).stroke(Theme.preview, lineWidth: 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .padding(5)
                }
            }

            HStack(spacing: 6) {
                Text(String(format: "%02d", camera.slot))
                    .font(Theme.value(11).weight(.bold))
                Text(camera.name)
                    .font(Theme.value(10.5))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if camera.isStreaming && model.isRecording {
                    Circle().fill(Theme.red).frame(width: 5, height: 5)
                }

                // Start all is for the top of the show. Once it is running, one
                // camera at a time is what actually gets used — a camera that
                // dropped out has to be brought back without touching the other
                // twenty-three.
                SoloButton(camera: camera)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Theme.raised)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(edge, lineWidth: isProgram ? 2 : 1) }
        .opacity(camera.state == .disconnected ? 0.5 : 1)
    }
}

// MARK: - Control rail

private struct ControlRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    SectionLabel(text: "Cameras")
                    // Says how many it will touch, because the answer is never
                    // "all of them" once a show is running — the ones already up
                    // are left exactly as they are.
                    RailButton(title: model.camerasNeedingStart == 0
                               ? "Start all — none missing"
                               : "Start the \(model.camerasNeedingStart) not running",
                               tint: Theme.orange) { model.startAllCameras() }
                        .disabled(model.camerasNeedingStart == 0)
                    RailButton(title: "Stop all") { model.stopAllCameras() }
                }

                if let slot = model.previewSlot, let camera = model.camera(slot: slot) {
                    Group {
                        SectionLabel(text: "Delay — cam \(String(format: "%02d", slot))")
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("OFFSET").font(Theme.label(9)).foregroundStyle(Theme.dim)
                                Spacer()
                                Text("\(Int(camera.delayMilliseconds)) ms")
                                    .font(Theme.value(11)).foregroundStyle(Theme.yellow)
                            }
                            Slider(value: Binding(
                                get: { camera.delayMilliseconds },
                                set: { model.setDelay(slot: slot, milliseconds: $0) }),
                                   in: 0...500)
                            .tint(Theme.orange)
                        }
                        .padding(8)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }

                Group {
                    SectionLabel(text: "Recording")
                    if model.isRecording {
                        RailButton(title: "Stop recording", tint: Theme.red) { model.stopRecording() }
                    } else {
                        RailButton(title: "Start recording", tint: Theme.orange) { model.startRecording() }
                    }
                    Text("Runs on the nodes, independent of the desk.")
                        .font(Theme.value(10.5))
                        .foregroundStyle(Theme.faint)
                }

                Group {
                    SectionLabel(text: "Nodes")
                    if model.nodes.isEmpty {
                        Text("None configured yet.")
                            .font(Theme.value(11)).foregroundStyle(Theme.faint)
                    } else {
                        ForEach(model.nodes) { node in NodeChip(node: node) }
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.panel)
    }
}

private struct RailButton: View {
    let title: String
    var tint: Color = Theme.dim
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.label(10.5)).tracking(0.8)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.6), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct NodeChip: View {
    let node: AppModel.Node

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(node.online ? Theme.orange : Theme.dead)
                    .frame(width: 7, height: 7)
                Text("Node \(String(format: "%02d", node.id))")
                    .font(Theme.value(11.5))
                Spacer()
                Text(node.online ? "\(node.streamsArriving)/\(node.streamsExpected)" : "offline")
                    .font(Theme.value(10.5))
                    .foregroundStyle(node.online ? Theme.dim : Theme.red)
            }
            if let seconds = node.secondsRemaining {
                Text("records \(seconds / 3600)h \((seconds % 3600) / 60)m more")
                    .font(Theme.value(10))
                    .foregroundStyle(seconds < 7200 ? Theme.yellow : Theme.faint)
            }
        }
        .padding(8)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Signal chain

private struct SignalChain: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Box(title: "Cameras",
                value: "\(model.camerasStreaming) streaming",
                detail: "\(model.camerasStreaming * 4) RTMP · to own nodes",
                lit: model.camerasStreaming > 0)
            Arrow()
            Box(title: "Nodes",
                value: "\(model.nodesOnline) of \(model.nodes.count)",
                detail: "record + proxy",
                lit: model.nodesOnline > 0,
                warn: !model.nodes.isEmpty && model.nodesOnline < model.nodes.count)
            Arrow()
            Box(title: "Switcher",
                value: "2 dec · 4 enc",
                detail: "hardware · CFR",
                lit: model.programSlot != nil)
            Arrow()
            Box(title: "Vahana",
                value: "pulls 4 inputs",
                detail: "stitching PC",
                lit: false)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.panel)
    }

    struct Box: View {
        let title: String
        let value: String
        let detail: String
        var lit = false
        var warn = false

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(warn ? Theme.yellow : (lit ? Theme.orange : Theme.dead))
                        .frame(width: 6, height: 6)
                    Text(title.uppercased())
                        .font(Theme.label(9)).tracking(1.1)
                        .foregroundStyle(Theme.dim)
                }
                Text(value).font(Theme.value(11.5))
                Text(detail).font(Theme.value(9.5)).foregroundStyle(Theme.faint)
            }
            .frame(minWidth: 118, alignment: .leading)
            .padding(9)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    struct Arrow: View {
        var body: some View {
            Text("→").font(.system(size: 13)).foregroundStyle(Theme.lineHi)
        }
    }
}

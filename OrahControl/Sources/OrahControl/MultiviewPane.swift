import SwiftUI
import OrahKit

/// A multiview generator: a wall of sources, a band of large boxes, and the
/// rail that decides how they are arranged.
///
/// There are two of these and they feed two displays. They are rarely wanted
/// the same way round — the screen in front of the operator carries the boxes,
/// the one on the wall carries every camera — so the layout belongs to the
/// generator rather than to the application.
///
/// Tiles are 3:4 because the camera composes a 1440×1920 portrait. A tile in
/// any other shape either letterboxes or lies about the framing, and on a
/// multiview the framing is the whole point.
@MainActor
struct MultiviewPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var generator = 1
    /// Hidden when the pane is already the window, so the button never offers
    /// to open a second copy of what you are looking at.
    var showsUndock = true

    @State private var showsLabels = true
    @State private var showsMeters = false

    private var layout: AppModel.MultiviewLayout { model.layout(for: generator) }

    var body: some View {
        VStack(spacing: 10) {
            paneChips
            HStack(alignment: .top, spacing: 10) {
                screen
                rail.frame(width: 336).fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1) }
    }

    private func chip(_ title: String, on: Bool = false,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.value(11.5))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundStyle(on ? Color(hex: 0x141417) : Theme.dim)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(on ? AnyShapeStyle(Theme.amberFill)
                             : AnyShapeStyle(Color(hex: 0x232327))))
                .overlay { RoundedRectangle(cornerRadius: 7)
                    .stroke(on ? Theme.amberGlow : Theme.line, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    /// Pop out, labels and meters live on the pane because they are about this
    /// pane. The generator tabs do not — they outlive it.
    private var paneChips: some View {
        HStack(spacing: 8) {
            Spacer()
            if showsUndock {
                chip("⇱ Pop out") {
                    openWindow(id: OrahControlApp.multiviewWindow, value: generator)
                }
            }
            chip("Aa labels", on: showsLabels) { showsLabels.toggle() }
            chip("▮ meters", on: showsMeters) { showsMeters.toggle() }
        }
    }

    // MARK: - The screen

    private var screen: some View {
        VStack(spacing: 6) {
            if layout.boxes > 0 && layout.boxesOnTop { boxRow }
            if layout.sourceRows > 0 || layout.boxes == 0 { sources }
            if layout.boxes > 0 && !layout.boxesOnTop { boxRow }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1) }
    }

    private var boxRow: some View {
        HStack(spacing: 6) {
            if layout.boxes >= 1 { bigBox(role: .preview) }
            if layout.boxes >= 2 { bigBox(role: .program) }
            if layout.boxes >= 3 && model.isBoxOn(3, generator: generator) { quadBox(0, number: 3) }
            if layout.boxes >= 4 && model.isBoxOn(4, generator: generator) { quadBox(1, number: 4) }
        }
    }

    private enum Role { case preview, program }

    private func bigBox(role: Role) -> some View {
        let isProgram = role == .program
        let slot = isProgram ? model.programSlot : model.previewSlot
        let camera = slot.flatMap { model.camera(slot: $0) }
        let accent = isProgram ? Theme.program : Theme.preview

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black)
            VideoView(sink: isProgram ? model.programSink : model.previewSink,
                      lens: isProgram ? model.programLens : model.previewLens)

            tag(isProgram ? "PROGRAM" : "PREVIEW",
                fg: isProgram ? .white : Color(hex: 0x04240F), bg: accent)

            if showsMeters { meter }
            if showsLabels {
                caption(camera.map {
                    "\($0.name.uppercased()) · CAM \(String(format: "%02d", $0.slot))" } ?? "—")
            }
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(accent, lineWidth: 2) }
    }

    /// A quad box divided 2×2 gives quadrants of exactly the same 3:4 as the box
    /// itself, so four portraits fit one frame with nothing left over.
    private func quadBox(_ index: Int, number: Int) -> some View {
        let cameras = index < model.freeBoxes.count ? model.freeBoxes[index] : []

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2),
                                GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(0..<4, id: \.self) { quadrant in
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(quadrant < cameras.count
                                         ? Theme.raised : Color(hex: 0x101012))
                        if quadrant < cameras.count, showsLabels {
                            Text(cameras[quadrant].name.uppercased())
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Theme.amberGlow)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Color.black.opacity(0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(3)
                        }
                    }
                    .aspectRatio(3.0/4.0, contentMode: .fill)
                    .clipped()
                }
            }
            .padding(2)

            tag("BIG \(number)", fg: Color(hex: 0x141417), bg: Theme.amber)
            if showsMeters { meter }
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Theme.amber, lineWidth: 2) }
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1.2)
            .foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 2.5)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .padding(5)
    }

    /// Indicative only — in the finished path these are fed by the LPCM that
    /// arrives on lenses 0_0 and 1_0.
    private var meter: some View {
        VStack(spacing: 1) {
            ForEach(0..<14, id: \.self) { index in
                Rectangle()
                    .fill(index < 4 ? Theme.program.opacity(0.25)
                          : index < 7 ? Theme.amber.opacity(0.3)
                          : Theme.preview.opacity(index > 9 ? 0.85 : 0.45))
                    .frame(width: 5)
            }
        }
        .padding(.vertical, 22).padding(.leading, 5)
        .frame(maxHeight: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.amberGlow)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 5)
    }

    private var sources: some View {
        let present = model.buttons.compactMap { $0 }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: layout.columns)

        return Group {
            if present.isEmpty {
                Text("NO CAMERAS ON THE NETWORK")
                    .font(Theme.label(10)).tracking(2).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(present.prefix(layout.sourceCount)) { camera in
                        SourceTile(camera: camera, showsLabel: showsLabels)
                    }
                }
            }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 10) {
            railSection("BOXES") {
                VStack(spacing: 6) {
                    boxRowEntry(1, key: "PVW", tint: Theme.preview,
                                text: model.camera(slot: model.previewSlot)
                                    .map { "\($0.name) · CAM \(String(format: "%02d", $0.slot)) — from switcher" } ?? "—")
                    boxRowEntry(2, key: "PGM", tint: Theme.program,
                                text: model.camera(slot: model.programSlot)
                                    .map { "\($0.name) · CAM \(String(format: "%02d", $0.slot)) — from switcher" } ?? "—")
                    boxRowEntry(3, key: "BIG 3", tint: Theme.amber,
                                text: model.freeBoxes.first?.map(\.name).joined(separator: ", ") ?? "—")
                    boxRowEntry(4, key: "BIG 4", tint: Theme.amber,
                                text: model.freeBoxes.count > 1
                                    ? model.freeBoxes[1].map(\.name).joined(separator: ", ") : "—")
                }
            }

            railSection("LAYOUT") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7),
                                    GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    ForEach(AppModel.MultiviewLayout.all) { option in
                        LayoutChoice(layout: option, selected: option.id == layout.id) {
                            model.setLayout(option, for: generator)
                        }
                    }
                }
            }

            railSection("SAVED LAYOUTS") {
                VStack(spacing: 6) {
                    ForEach(model.savedLayouts) { saved in
                        HStack(spacing: 9) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.name).font(Theme.value(12))
                                Text("\(AppModel.MultiviewLayout.named(saved.layoutID).title) · \(saved.when)")
                                    .font(Theme.value(10)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Button("Recall") { model.recall(saved, generator: generator) }
                                .buttonStyle(.plain)
                                .font(Theme.value(10.5)).foregroundStyle(Theme.dim)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(hex: 0x232327)))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                        .overlay { RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.line, lineWidth: 1) }
                    }
                    Button("+ Save layout") {
                        model.saveLayout(named: "Layout \(model.savedLayouts.count + 1)",
                                         generator: generator)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.value(11)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x232327)))
                }
            }
        }
    }

    private func railSection<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.label(9.5)).tracking(2).foregroundStyle(Theme.faint)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1) }
    }

    /// Preview and program cannot be switched off — they are the two the
    /// operator is judging, and a desk that can hide what is on air is a desk
    /// nobody should be given.
    private func boxRowEntry(_ number: Int, key: String, tint: Color,
                             text: String) -> some View {
        let locked = number < 3
        let on = model.isBoxOn(number, generator: generator)

        return HStack(spacing: 9) {
            Text(key)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(0.8)
                .foregroundStyle(tint).frame(width: 40, alignment: .leading)
            Text(text)
                .font(Theme.value(11)).foregroundStyle(Theme.dim)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Capsule()
                .fill(on ? Theme.amber.opacity(locked ? 0.4 : 1) : Color(hex: 0x232327))
                .frame(width: 32, height: 18)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(on ? .white : Color(hex: 0x5A5A62))
                        .frame(width: 13, height: 13).padding(2.5)
                }
                .opacity(locked ? 0.45 : 1)
                .onTapGesture { model.toggleBox(number, generator: generator) }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1) }
    }
}

/// The little picture of a layout.
///
/// Drawn from the same numbers the screen is drawn from, so it can never show
/// an arrangement the generator does not actually produce.
@MainActor
private struct LayoutChoice: View {
    let layout: AppModel.MultiviewLayout
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                GeometryReader { geometry in
                    let cell = geometry.size.width / CGFloat(layout.columns)
                    let rows = layout.boxes > 0
                        ? layout.boxHeight + layout.sourceRows : layout.sourceRows

                    VStack(spacing: 1.5) {
                        if layout.boxes > 0 && layout.boxesOnTop { band(cell) }
                        sourceRows(cell)
                        if layout.boxes > 0 && !layout.boxesOnTop { band(cell) }
                    }
                    .frame(height: cell * CGFloat(max(rows, 1)))
                }
                .aspectRatio(CGFloat(layout.columns) /
                             CGFloat(max(1, (layout.boxes > 0 ? layout.boxHeight : 0)
                                            + layout.sourceRows)),
                             contentMode: .fit)

                Text(layout.title)
                    .font(Theme.value(9.5)).foregroundStyle(selected ? Theme.amber : Theme.dim)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(layout.sourceCount) sources")
                    .font(Theme.value(8.5)).foregroundStyle(Theme.faint)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay { RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Theme.amber : Theme.line, lineWidth: selected ? 1.5 : 1) }
        }
        .buttonStyle(.plain)
    }

    private func band(_ cell: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<layout.boxes, id: \.self) { _ in
                Rectangle().fill(Color(hex: 0x7A7A84))
                    .frame(width: cell * CGFloat(layout.boxWidth) - 1.5,
                           height: cell * CGFloat(layout.boxHeight) - 1.5)
            }
            let rest = max(0, layout.columns - layout.boxes * layout.boxWidth)
            if rest > 0 {
                VStack(spacing: 1.5) {
                    ForEach(0..<layout.boxHeight, id: \.self) { _ in
                        HStack(spacing: 1.5) {
                            ForEach(0..<rest, id: \.self) { _ in
                                Rectangle().fill(Color(hex: 0x37373E)).frame(height: cell - 1.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sourceRows(_ cell: CGFloat) -> some View {
        VStack(spacing: 1.5) {
            ForEach(0..<layout.sourceRows, id: \.self) { _ in
                HStack(spacing: 1.5) {
                    ForEach(0..<layout.columns, id: \.self) { _ in
                        Rectangle().fill(Color(hex: 0x37373E)).frame(height: cell - 1.5)
                    }
                }
            }
        }
    }
}

/// One source, with the keys that send it somewhere.
@MainActor
private struct SourceTile: View {
    @Environment(AppModel.self) private var model
    let camera: AppModel.Camera
    var showsLabel = true

    private var isProgram: Bool { camera.slot == model.programSlot }
    private var isPreview: Bool { camera.slot == model.previewSlot }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.raised)

            // Only programme and preview are decoded — that is the rule that
            // makes twenty-four cameras possible on one Mac — so those two
            // tiles carry a live picture and the rest carry their status.
            if isProgram {
                VideoView(sink: model.programSink, lens: model.lens(for: camera.slot))
            } else if isPreview {
                VideoView(sink: model.previewSink, lens: model.lens(for: camera.slot))
            }

            Group {
                // What the camera is doing, while it is not yet a picture.
                // "Not on the network", "still booting", "ready — press Start",
                // and how many of the four lenses have arrived. Losing this in
                // the rewrite made a tile that is empty for a good reason look
                // exactly like one that is empty for a bad one.
                if !camera.isStreaming || camera.lensesArriving < 4 {
                    StartupStatus(phase: model.state(slot: camera.slot),
                                  startedAt: model.startingSince(slot: camera.slot),
                                  lensesArriving: camera.lensesArriving,
                                  step: model.startingStep(slot: camera.slot),
                                  compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 14)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Text(model.legend(for: camera))
                            .font(.system(size: 8.5, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(Theme.amberGlow)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        Spacer(minLength: 0)
                        startKey(camera)
                    }
                    .padding(3)
                }

                Text(isProgram ? "PGM" : isPreview ? "PVW"
                     : String(format: "%02d", camera.slot))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isProgram ? .white
                                     : isPreview ? Color(hex: 0x04240F) : Color(hex: 0xC9C9CF))
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(isProgram ? AnyShapeStyle(Theme.program)
                                : isPreview ? AnyShapeStyle(Theme.preview)
                                : AnyShapeStyle(Color.black.opacity(0.66)))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(3)

                // Which of the camera's four lenses this tile shows. All four
                // are always available — a camera is four sensors and any of
                // them can be the one worth watching.
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { lens in
                        lensKey(lens, camera: camera)
                    }
                }
                .padding(3)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(isProgram ? Theme.program : isPreview ? Theme.preview
                        : Color(hex: 0x1E1E22), lineWidth: 2)
        }
        .onTapGesture { model.selectPreview(camera.slot) }
    }

    /// Start or stop this camera on its own.
    ///
    /// Start All is for the top of a show; this is for the camera that came up
    /// late, or the one somebody had to power cycle halfway through. It says
    /// what pressing it will do rather than what the camera is currently doing,
    /// because a button is an instruction, not a status light — the status is
    /// already written across the tile above it.
    private func startKey(_ camera: AppModel.Camera) -> some View {
        let running = model.isRunning(slot: camera.slot)
        return Button {
            if running { model.stopCamera(camera.slot) }
            else { model.startCamera(camera.slot) }
        } label: {
            Text(running ? "STOP" : "START")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .foregroundStyle(running ? Theme.program : Color(hex: 0x141417))
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(running ? AnyShapeStyle(Color.black.opacity(0.8))
                                  : AnyShapeStyle(Theme.amberFill)))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(running ? Theme.program.opacity(0.8) : Theme.amberGlow,
                                lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(running ? "Stop cam \(camera.slot)" : "Start cam \(camera.slot)")
    }

    /// One of the four lenses. Lit is the one being shown; a lens that has not
    /// arrived yet is dimmed rather than hidden, so the row always reads as the
    /// same four positions and a missing half of a camera is visible as a gap
    /// rather than as a shorter row.
    private func lensKey(_ lens: Int, camera: AppModel.Camera) -> some View {
        let shown = model.lens(for: camera.slot) == lens
        let arrived = lens < camera.lensesArriving

        return Button {
            model.setLens(lens, for: camera.slot)
        } label: {
            Text("\(lens + 1)")
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .frame(width: 14, height: 14)
                .foregroundStyle(shown ? Color(hex: 0x141417)
                                 : arrived ? Theme.amberGlow : Color(hex: 0x6B4D18))
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(shown ? AnyShapeStyle(Theme.amberFill)
                          : AnyShapeStyle(Color.black.opacity(0.86))))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(shown ? Theme.amberGlow
                                : arrived ? Theme.amber.opacity(0.75) : Color(hex: 0x4A3811),
                                lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("Lens \(Switcher.lenses[lens])")
    }
}


/// The generator strip.
///
/// It lives in the desk window and not inside the pane, because it has to
/// survive the pane being pulled onto another screen — the strip is how a
/// generator is called back, so tying it to the thing it opens would mean the
/// only way to reach a window is a window you have just closed.
@MainActor
struct MultiviewTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    // MARK: - Tabs

    var body: some View {
        Strip {
            ForEach(1...AppModel.multiviewCount, id: \.self) { number in
                StripButton(title: "MULTIVIEW \(number)",
                            detail: "\(model.output(for: number)) · \(model.layout(for: number).title)",
                            selected: isLive(number)) {
                    openWindow(id: OrahControlApp.multiviewWindow, value: number)
                }
            }
        }
    }

    /// Live means on a screen somewhere — in a window of its own, or the one
    /// embedded in this window. Amber says the same thing in both strips.
    private func isLive(_ number: Int) -> Bool {
        model.detachedMultiviews.contains(number)
            || (number == 1 && model.showsInlineMultiview)
    }
}

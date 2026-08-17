import SwiftUI
import OrahKit

/// Four large boxes over every source.
///
/// Preview and program are the two being judged, so they stay whole. The other
/// two are free and are quad splits — four sources each, which is what makes a
/// twenty-four camera rig watchable without a wall of monitors. Every source
/// carries amber keys that send it to one of them.
///
/// Tiles are 3:4 because the camera composes a 1440×1920 portrait. A tile in
/// any other shape either letterboxes or lies about the framing, and on a
/// multiview the framing is the whole point.
@MainActor
struct MultiviewPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Hidden when the pane is already the window, so the button never offers
    /// to open a second copy of what you are looking at.
    var showsUndock = true

    /// Only cameras that are actually here get a tile, and the tiles grow to
    /// fill what is left. Twenty-four empty rectangles when three cameras are
    /// plugged in is twenty-one holes taking space from the three that matter —
    /// and the desk keys already hold the positions, which is where finger
    /// memory belongs.
    private let sourceColumns = [GridItem(.adaptive(minimum: 132, maximum: 260), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "MULTIVIEW",
                    subtitle: "\(model.cameras.count) sources") {
                if showsUndock {
                    Button("⇱ Own window") {
                        openWindow(id: OrahControlApp.multiviewWindow)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.value(11)).foregroundStyle(Theme.dim)
                }
            }

            VStack(spacing: 7) {
                boxes
                sources
            }
            .padding(11)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1) }
    }

    // MARK: - Boxes

    private var boxes: some View {
        HStack(spacing: 6) {
            bigBox(role: .preview)
            bigBox(role: .program)
            quadBox(0)
            quadBox(1)
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

            Text(isProgram ? "PROGRAM" : "PREVIEW")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(isProgram ? .white : Color(hex: 0x04240F))
                .padding(.horizontal, 5).padding(.vertical, 2.5)
                .background(accent)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(5)

            caption(camera.map { "\($0.name.uppercased()) · CAM \(String(format: "%02d", $0.slot))" }
                    ?? "—")
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .frame(maxHeight: 238)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(accent, lineWidth: 2) }
    }

    /// A quad box divided 2×2 gives quadrants of exactly the same 3:4 as the box
    /// itself, so four portraits fit one frame with nothing left over.
    private func quadBox(_ index: Int) -> some View {
        let cameras = index < model.freeBoxes.count ? model.freeBoxes[index] : []

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2),
                                GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(0..<4, id: \.self) { quadrant in
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(quadrant < cameras.count ? Theme.raised : Color(hex: 0x101012))
                        if quadrant < cameras.count, !cameras[quadrant].isStreaming {
                            Text(model.state(slot: cameras[quadrant].slot).label.uppercased())
                                .font(Theme.label(7)).tracking(0.8)
                                .foregroundStyle(Theme.faint)
                                .multilineTextAlignment(.center)
                                .lineLimit(2).minimumScaleFactor(0.7)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if quadrant < cameras.count {
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

            Text("BOX \(index + 3)")
                .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1.2)
                .foregroundStyle(Color(hex: 0x141417))
                .padding(.horizontal, 5).padding(.vertical, 2.5)
                .background(Theme.amber)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(5)
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .frame(maxHeight: 238)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Theme.amber, lineWidth: 2) }
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

    // MARK: - Sources

    private var sources: some View {
        // In button order, so the wall reads left to right the same way the
        // desk does, but with the gaps closed up.
        let present = model.buttons.compactMap { $0 }

        return Group {
            if present.isEmpty {
                Text("NO CAMERAS ON THE NETWORK")
                    .font(Theme.label(10)).tracking(2).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                LazyVGrid(columns: sourceColumns, spacing: 6) {
                    ForEach(present) { camera in SourceTile(camera: camera) }
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
                                  : AnyShapeStyle(Theme.amberGradient)))
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
                    .fill(shown ? AnyShapeStyle(Theme.amberGradient)
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

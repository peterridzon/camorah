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

    private let sourceColumns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 12)

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "MULTIVIEW",
                    subtitle: "2 boxes + 2 quads + \(model.cameras.count) sources") {
                EmptyView()
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
        LazyVGrid(columns: sourceColumns, spacing: 5) {
            ForEach(0..<AppModel.keysPerBus, id: \.self) { index in
                SourceTile(camera: index < model.buttons.count ? model.buttons[index] : nil)
            }
        }
    }
}

/// One source, with the keys that send it somewhere.
@MainActor
private struct SourceTile: View {
    @Environment(AppModel.self) private var model
    let camera: AppModel.Camera?

    private var isProgram: Bool { camera?.slot == model.programSlot }
    private var isPreview: Bool { camera?.slot == model.previewSlot }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(camera == nil ? Color(hex: 0x101012) : Theme.raised)

            if let camera {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(model.legend(for: camera))
                        .font(.system(size: 8.5, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(Theme.amberGlow)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
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

                // Amber keys, on the source because that is where the eye is
                // when choosing. Pressing one twice takes it back out.
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { box in
                        sendKey(box: box, camera: camera)
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
                        : camera == nil ? Theme.dead : Color(hex: 0x1E1E22),
                        lineWidth: 2)
        }
        .onTapGesture { if let camera { model.previewSlot = camera.slot } }
    }

    /// Keys 1 and 2 are preview and program, which the desk owns — they are
    /// shown dark rather than hidden so the four keys always mean the same four
    /// boxes wherever you look.
    private func sendKey(box: Int, camera: AppModel.Camera) -> some View {
        let isFree = box >= 2
        let freeIndex = box - 2
        let on = isFree && model.boxContains(freeIndex, serial: camera.serial)

        return Button {
            guard isFree else { return }
            model.sendToBox(freeIndex, serial: camera.serial)
        } label: {
            Text("\(box + 1)")
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .frame(width: 13, height: 13)
                .foregroundStyle(on ? Color(hex: 0x141417)
                                 : isFree ? Color(hex: 0xB98B45) : Theme.dead)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(on ? AnyShapeStyle(Theme.amberGradient)
                          : AnyShapeStyle(Color.black.opacity(0.86))))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(on ? Theme.amberGlow
                                : isFree ? Color(hex: 0x6B4D18) : Theme.dead, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isFree)
    }
}

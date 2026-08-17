import SwiftUI
import OrahKit

/// Shading, one camera at a time.
///
/// The layout is a remote control panel rather than a settings sheet, because
/// that is what the job is: two controls under one hand — how bright it is and
/// where the blacks sit — and everything else is trim. The lever and the puck
/// are dragged, never typed, so the eye can stay on the picture while the hand
/// works. The read-outs underneath are for writing a number down afterwards.
@MainActor
struct ColourView: View {
    @Environment(AppModel.self) private var model

    @State private var slot: Int?
    @State private var showsGraded = true

    private var current: Int? { slot ?? model.programSlot ?? model.cameras.first?.slot }

    private var grade: ColourGrade {
        current.map { model.grade(slot: $0) } ?? ColourGrade()
    }

    private func edit(_ change: (inout ColourGrade) -> Void) {
        guard let current else { return }
        var g = model.grade(slot: current)
        change(&g)
        model.setGrade(g, slot: current)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            path
            cameraStrip

            HStack(alignment: .top, spacing: 12) {
                shading
                trim
            }
            .padding(12)

            Spacer(minLength: 0)
        }
        .background(Theme.bg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("COLOUR").font(Theme.label(10)).tracking(2.4).foregroundStyle(Theme.dim)
            Text(current.map { model.camera(slot: $0)?.name ?? "—" } ?? "no camera")
                .font(Theme.value(11)).foregroundStyle(Theme.amber)
            Spacer()
            Text("\(model.gradedSlots.count) of \(model.cameras.count) graded")
                .font(Theme.label(9.5)).tracking(1.4).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel)
    }

    /// The one thing worth remembering about colour here, drawn rather than
    /// written in a manual: the recording never sees any of this.
    private var path: some View {
        HStack(spacing: 7) {
            node("camera", Theme.faint)
            arrow
            node("MediaMTX", Theme.faint)
            arrow
            node("RECORD · ISO — untouched", Theme.preview)
            Spacer().frame(width: 14)
            node("COLOUR · per camera", Theme.amber)
            arrow
            node("mix", Theme.faint)
            arrow
            node("PROGRAM · Vahana", Theme.program)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel.opacity(0.5))
    }

    private func node(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(Theme.value(9.5)).foregroundStyle(colour)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(colour.opacity(0.5), lineWidth: 1))
    }
    private var arrow: some View {
        Text("→").font(Theme.value(9.5)).foregroundStyle(Theme.dead)
    }

    // MARK: - Cameras

    private var cameraStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.cameras) { camera in
                    Button {
                        slot = camera.slot
                    } label: {
                        HStack(spacing: 5) {
                            Text(camera.name.uppercased())
                                .font(Theme.label(11)).tracking(1)
                            if model.gradedSlots.contains(camera.slot) {
                                Circle().fill(current == camera.slot ? Color.black : Theme.amber)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .foregroundStyle(current == camera.slot ? Color.black : Theme.amberGlow)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(current == camera.slot ? Theme.amber : Theme.keyBody)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).stroke(
                                camera.slot == model.programSlot ? Theme.program
                                : camera.slot == model.previewSlot ? Theme.preview
                                : Theme.amber, lineWidth: 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    /// The camera being shaded, all four lenses, live.
    ///
    /// Shading against a memory of what the picture looked like is guessing.
    /// Four lenses rather than one because a camera is four sensors and they do
    /// not always match each other either — a correction that fixes the front
    /// can easily wreck the one facing the lights.
    private var pictures: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(showsGraded ? "GRADED" : "BYPASS")
                    .font(Theme.label(9.5)).tracking(2)
                    .foregroundStyle(showsGraded ? Theme.amber : Theme.dim)
                Text(current.map { model.camera(slot: $0)?.name.uppercased() ?? "—" } ?? "—")
                    .font(Theme.value(10)).foregroundStyle(Theme.faint)
                Spacer()
                Text("all four lenses")
                    .font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dead)
            }

            // Four across, above the wheels. The picture is what the eye is on
            // while the hand works, so it sits over the controls rather than
            // beside them — anything to the side of a wheel competes with it.
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { lens in
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(.black)
                        VideoView(sink: model.inspectSinks[lens], lens: lens)
                        Text(Switcher.lenses[lens])
                            .font(Theme.value(9)).foregroundStyle(Theme.amberGlow)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .padding(4)
                    }
                    .aspectRatio(1440.0/1920.0, contentMode: .fit)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        // The switcher only makes these pictures while somebody is looking.
        .onAppear { model.watch(slot: current, bypass: !showsGraded) }
        .onDisappear { model.watch(slot: nil) }
        .onChange(of: current) { model.watch(slot: current, bypass: !showsGraded) }
        .onChange(of: showsGraded) { model.watch(slot: current, bypass: !showsGraded) }
    }

    // MARK: - Shading panel

    private var shading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SHADING").font(Theme.label(9.5)).tracking(2).foregroundStyle(Theme.faint)

            HStack(spacing: 5) {
                abButton("BYPASS", on: !showsGraded) { showsGraded = false }
                abButton("GRADED", on: showsGraded) { showsGraded = true }
            }

            HStack(alignment: .top, spacing: 11) {
                lever
                puck
            }

            HStack(spacing: 5) {
                readout("EXPOSURE", grade.exposure)
                readout("GAMMA", grade.gamma)
                readout("BLACK", grade.black)
            }

            HStack(spacing: 6) {
                smallButton("↺ RESET") { edit { $0 = ColourGrade() } }
                smallButton("COPY TO ALL") {
                    let g = grade
                    for camera in model.cameras { model.setGrade(g, slot: camera.slot) }
                }
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    /// Exposure. OPEN at the top, as on every shading panel — a hand that has
    /// done this before must not have to think about which way is brighter.
    private var lever: some View {
        VStack(spacing: 6) {
            Text("OPEN").font(Theme.label(8.5)).tracking(1.6).foregroundStyle(Theme.faint)
            GeometryReader { geometry in
                let height = geometry.size.height
                let knob: CGFloat = 34
                let travel = max(1, height - knob)
                let y = CGFloat((1 - (grade.exposure + 1) / 2)) * travel

                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8).fill(.black)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                    Capsule().fill(Theme.amberGradient)
                        .frame(height: knob)
                        .shadow(color: Theme.amber.opacity(0.45), radius: 8)
                        .offset(y: y)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let p = min(max(0, (value.location.y - knob / 2) / travel), 1)
                    edit { $0.exposure = Float((1 - p) * 2 - 1) }
                })
            }
            .frame(width: 56)
            Text("CLOSE").font(Theme.label(8.5)).tracking(1.6).foregroundStyle(Theme.faint)
        }
        .frame(height: 196)
    }

    /// Master black up and down, gamma left and right — one hand, two values,
    /// which is the whole reason a shading panel has a puck instead of two more
    /// sliders.
    private var puck: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let x = (0.5 + CGFloat(grade.gamma) * 0.9) * size.width
            let y = (0.5 - CGFloat(grade.black) * 0.9) * size.height

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                Path { p in
                    p.move(to: CGPoint(x: size.width / 2, y: 8))
                    p.addLine(to: CGPoint(x: size.width / 2, y: size.height - 8))
                    p.move(to: CGPoint(x: 8, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width - 8, y: size.height / 2))
                }
                .stroke(Theme.line, lineWidth: 1)

                Circle().fill(Theme.amberGradient)
                    .frame(width: 32, height: 32)
                    .shadow(color: Theme.amber.opacity(0.5), radius: 10)
                    .position(x: x, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let gx = Float(min(max(-1, (value.location.x / size.width - 0.5) / 0.45), 1)) * 0.5
                let gy = Float(min(max(-1, (0.5 - value.location.y / size.height) / 0.45), 1)) * 0.5
                edit { $0.gamma = gx; $0.black = gy }
            })
        }
        .frame(height: 196)
    }

    // MARK: - Trim

    private var trim: some View {
        VStack(alignment: .leading, spacing: 14) {
            pictures

            HStack(alignment: .top, spacing: 12) {
                wheel("LIFT", \.lift, range: -0.5...0.5, base: 0)
                wheel("GAMMA", \.gammaRGB, range: -0.5...0.5, base: 0)
                wheel("GAIN", \.gain, range: 0...2, base: 1)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 9) {
                    slider("Contrast", \.contrast, 0...100, "%")
                    slider("Pivot", \.pivot, 0...1, "")
                }
                VStack(spacing: 9) {
                    slider("Saturation", \.saturation, 0...100, "%")
                    slider("Lum Mix", \.lumMix, 0...100, "%")
                }
                VStack(spacing: 9) {
                    slider("Hue", \.hue, 0...360, "°")
                    slider("Tint", \.tint, -50...50, "")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private func wheel(_ name: String,
                       _ key: WritableKeyPath<ColourGrade, ColourGrade.Trio>,
                       range: ClosedRange<Float>, base: Float) -> some View {
        let trio = grade[keyPath: key]
        let span = range.upperBound - range.lowerBound

        return VStack(spacing: 8) {
            Text(name).font(Theme.label(9.5)).tracking(2).foregroundStyle(Theme.amber)

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle().fill(AngularGradient(colors: Theme.wheelColours, center: .center))
                        .overlay(Circle().inset(by: side * 0.16).fill(Theme.panel))
                    Circle().fill(.white).frame(width: 11, height: 11)
                        .position(
                            x: side / 2 + CGFloat((trio.r - trio.b) / span) * side * 0.36,
                            y: side / 2 - CGFloat((trio.g - base) / span) * side * 0.36)
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let dx = Float((value.location.x - side / 2) / (side / 2))
                    let dy = Float((value.location.y - side / 2) / (side / 2))
                    edit { g in
                        var t = g[keyPath: key]
                        t.r = base + (dx * 0.5 - dy * 0.5) * span / 2
                        t.b = base + (-dx * 0.5 - dy * 0.5) * span / 2
                        t.g = base + (-dy * 0.5) * span / 2
                        g[keyPath: key] = t
                    }
                })
            }
            .frame(height: 128)

            Slider(value: Binding(
                get: { Double(trio.y) },
                set: { v in edit { $0[keyPath: key].y = Float(v) } }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            .controlSize(.mini).tint(Theme.amber)

            HStack(spacing: 3) {
                field(trio.y, .gray) { v in edit { $0[keyPath: key].y = v } }
                field(trio.r, .red) { v in edit { $0[keyPath: key].r = v } }
                field(trio.g, .green) { v in edit { $0[keyPath: key].g = v } }
                field(trio.b, .blue) { v in edit { $0[keyPath: key].b = v } }
            }
        }
    }

    private func field(_ value: Float, _ tint: Color,
                       _ set: @escaping (Float) -> Void) -> some View {
        TextField("", text: Binding(
            get: { String(format: "%.2f", value) },
            set: { if let v = Float($0) { set(v) } }))
        .textFieldStyle(.plain)
        .font(Theme.value(10.5))
        .multilineTextAlignment(.center)
        .padding(.vertical, 3)
        .background(.black)
        .overlay(Rectangle().frame(height: 2).foregroundStyle(tint), alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func slider(_ name: String, _ key: WritableKeyPath<ColourGrade, Float>,
                        _ range: ClosedRange<Float>, _ suffix: String) -> some View {
        let value = grade[keyPath: key]
        return VStack(spacing: 3) {
            HStack {
                Text(name).font(Theme.value(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(range.upperBound <= 1
                     ? String(format: "%.2f", value)
                     : "\(Int(value))\(suffix)")
                    .font(Theme.value(11)).foregroundStyle(Theme.fg)
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: { v in edit { $0[keyPath: key] = Float(v) } }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            .controlSize(.mini).tint(Theme.amber)
        }
    }

    // MARK: - Bits

    private func abButton(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(10)).tracking(1.6)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(on ? Theme.amberGlow : Theme.dim)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Theme.keyBody : Color(white: 0.13)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(on ? Theme.amber.opacity(0.6) : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(9.5)).tracking(1.2)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(Theme.dim)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func readout(_ name: String, _ value: Float) -> some View {
        VStack(spacing: 3) {
            Text(name).font(Theme.label(8)).tracking(1.2).foregroundStyle(Theme.faint)
            Text(String(format: "%+.2f", value))
                .font(Theme.value(12)).foregroundStyle(Theme.amber)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }
}

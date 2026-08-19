import SwiftUI
import OrahKit

/// The console: two buses, the transition block, and the T-bar.
///
/// Laid out as a vision mixer rather than as a form, because that is what it is
/// and because the hand has to find a key without the eye leaving the picture.
/// Twelve plus twelve on each bus, exact squares so the columns line up at any
/// window width, and the same amber frame the rig check uses — there it means
/// "this unit is ready", and it means the same here.
@MainActor
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showsAssign = false

    var showsUndock = true

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "CONSOLE", subtitle: "program · preview · transition") {
                Button("⚙ Assign") { showsAssign = true }.buttonStyle(.plain)
                    .font(Theme.value(11)).foregroundStyle(Theme.dim)
                if showsUndock {
                    Button("⇱ Own window") {
                        openWindow(id: OrahControlApp.consoleWindow)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.value(11)).foregroundStyle(Theme.dim)
                }
            }

            HStack(alignment: .top, spacing: 13) {
                buses
                TransitionBlock()
                TBarColumn()
                Spacer(minLength: 0)
            }
            .padding(11)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1) }
        .sheet(isPresented: $showsAssign) { AssignSheet() }
    }

    private var buses: some View {
        VStack(alignment: .leading, spacing: 11) {
            bus(.program)
            bus(.preview)
        }
        .padding(11)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1) }
    }

    private enum Bus { case program, preview }

    private func bus(_ which: Bus) -> some View {
        let isProgram = which == .program
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(isProgram ? "PROGRAM" : "PREVIEW")
                    .font(Theme.label(11)).tracking(2.2)
                    .foregroundStyle(isProgram ? Theme.program : Theme.preview)
                Text(isProgram ? "always live — pressing takes it to air"
                               : "next — takes via CUT, AUTO or the T-bar")
                    .font(Theme.label(9)).tracking(1.4).foregroundStyle(Theme.faint)
            }

            // Fixed width, packed left, black to the right of them.
            //
            // A grid shares its width out among the columns, so widening the
            // window pushed every key away from the label it belongs to. A desk
            // does not do that: the keys are where they were the last time you
            // looked, and the surface simply gets wider.
            ForEach([0, 12], id: \.self) { start in
                HStack(spacing: 5) {
                    ForEach(start..<(start + 12), id: \.self) { index in
                        KeyCap(index: index, isProgramBus: isProgram)
                            .frame(width: 58, height: 58)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - One key

/// A key, not a rectangle with a word in it.
///
/// An exact square through `aspectRatio`, so the two buses line up column to
/// column however wide the window is. The frame is amber whenever a camera sits
/// under it; the lamp along the top edge is the second sentence — "and it can
/// go to air". Red is on air, green is next, and nothing else is ever either.
@MainActor
private struct KeyCap: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let isProgramBus: Bool

    private var camera: AppModel.Camera? {
        let buttons = model.buttons
        return index < buttons.count ? buttons[index] : nil
    }
    private var isLit: Bool {
        guard let slot = camera?.slot else { return false }
        return isProgramBus ? slot == model.programSlot : slot == model.previewSlot
    }
    private var accent: Color { isProgramBus ? Theme.program : Theme.preview }

    /// A camera that cannot go to air holds its key — keys must not move under
    /// a hand that has learnt them — but the key is dark and will not press.
    /// This is what stops a fault reaching the programme, now that the wall
    /// shows faults rather than hiding them.
    private var isUsable: Bool {
        guard let slot = camera?.slot else { return false }
        return WallPolicy.canGoToAir(model.standing(slot: slot))
    }

    var body: some View {
        Button {
            guard let slot = camera?.slot else { return }
            if isProgramBus { model.takeToAir(slot) } else { model.selectPreview(slot) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isLit ? litBody : Theme.keyFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(camera == nil ? Theme.dead
                                    : isLit ? accent.opacity(0.95)
                                    : isUsable ? Theme.amber : Theme.dead,
                                    lineWidth: 1.5)
                    }
                    .shadow(color: isLit ? accent.opacity(0.32) : .clear, radius: 6)

                if camera != nil {
                    // The lamp. Read peripherally, without looking at the text.
                    Capsule()
                        .fill(isLit ? Color.white : isUsable ? Theme.amber : Theme.dead)
                        .frame(height: 3)
                        .padding(.horizontal, 13)
                        .shadow(color: isLit ? .white.opacity(0.5)
                                : isUsable ? Theme.amber.opacity(0.45) : .clear,
                                radius: 3)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 5)
                }

                if let camera {
                    Text(model.legend(for: camera))
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.6)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.55)
                        .lineLimit(2)
                        .foregroundStyle(isLit ? (isProgramBus ? .white : Color(hex: 0x04240F))
                                         : isUsable ? Theme.amberGlow : Theme.faint)
                        .padding(.horizontal, 4)
                        .padding(.top, 10)
                }

                if let camera, model.gradedSlots.contains(camera.slot) {
                    Circle()
                        .fill(isLit ? Color.white.opacity(0.9) : Theme.amber)
                        .frame(width: 5, height: 5)
                        .shadow(color: Theme.amber.opacity(0.5), radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomTrailing)
                        .padding(5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .disabled(camera == nil || !isUsable)
        .help(camera.map { camera in
            let base = "\(camera.name) · CAM \(String(format: "%02d", camera.slot))"
            return isUsable ? base
                 : base + " — not ready: \(model.state(slot: camera.slot).label.lowercased())"
        } ?? "")
    }

    private var litBody: Color { isProgramBus ? Theme.program : Theme.preview }
}

// MARK: - Transition

@MainActor
private struct TransitionBlock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 10) {
            label("Transition style")
            HStack(spacing: 5) {
                styleKey("MIX", selected: !model.transitionIsCut) { model.transitionIsCut = false }
                styleKey("WIPE", selected: model.transitionIsCut) { model.transitionIsCut = true }
            }
            HStack(spacing: 5) {
                futureKey(); futureKey()
            }

            VStack(spacing: 8) {
                HStack {
                    label("Rate")
                    Spacer()
                    Text(rateText)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.amber)
                }
                RateSlider(value: $model.transitionMilliseconds, range: 100...3000)
            }
            .padding(10)
            // Grey, not black. A black well inside a dark panel reads as a hole
            // punched through it; the same tone as its surroundings lets the
            // amber do the work without the frame shouting.
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raised))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Theme.amber, lineWidth: 1.5) }

            label("Transition")
            HStack(spacing: 5) {
                bigKey("CUT") { model.cut() }
                bigKey("AUTO") { model.take() }
            }
            commandKey("PREV TRANS", armed: false) {}
        }
        .frame(width: 202)
    }

    private var rateText: String {
        let frames = Int((model.transitionMilliseconds / 1000) * 30)
        return String(format: "%d:%02d", frames / 30, frames % 30)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.label(9.5)).tracking(2).foregroundStyle(Theme.faint)
    }

    private func styleKey(_ title: String, selected: Bool,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold)).tracking(1.2)
                .frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(selected ? Color(hex: 0x141417) : Theme.amberGlow)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Theme.amberFill : Theme.keyFill))
                .overlay { RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Theme.amberGlow : Theme.amber.opacity(0.55), lineWidth: 1.5) }
                .shadow(color: selected ? Theme.amber.opacity(0.28) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
    }

    /// Room left for later, drawn as a key that is not fitted yet rather than
    /// as a broken one.
    private func futureKey() -> some View {
        Text("—")
            .font(.system(size: 11.5, weight: .bold))
            .frame(maxWidth: .infinity).frame(height: 44)
            .foregroundStyle(Theme.dead)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x161619)))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Theme.dead, lineWidth: 1.5) }
    }

    private func bigKey(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold)).tracking(1.6)
                .frame(maxWidth: .infinity).frame(height: 66)
                .foregroundStyle(Theme.amberGlow)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.keyFill))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(Theme.amber, lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
    }

    private func commandKey(_ title: String, armed: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold)).tracking(1.4)
                .frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(armed ? .white : Theme.amberGlow.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(armed ? AnyShapeStyle(Theme.program) : AnyShapeStyle(Theme.keyFill)))
                .overlay { RoundedRectangle(cornerRadius: 9)
                    .stroke(armed ? Theme.program : Theme.amber.opacity(0.55), lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
    }
}

/// The rate control.
///
/// Built rather than borrowed: the system slider draws a white thumb, and on a
/// desk where amber means "this is the thing under your hand" a white one says
/// the opposite. What you grab is amber, the track it runs in is not, and the
/// travelled part fills behind it so the value can be read without looking at
/// the number.
@MainActor
private struct RateSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knob: CGFloat = 16
            let travel = max(1, width - knob)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x2E2E2C)).frame(height: 5)
                Capsule().fill(Theme.amberFill)
                    .frame(width: max(5, CGFloat(fraction) * travel + knob / 2), height: 5)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.amberFill)
                    .frame(width: knob, height: 20)
                    .overlay { RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(hex: 0x6B4415), lineWidth: 1) }
                    .shadow(color: Theme.amber.opacity(0.25), radius: 3)
                    .offset(x: CGFloat(fraction) * travel)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let p = min(max(0, (drag.location.x - knob / 2) / travel), 1)
                value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 22)
    }
}

// MARK: - T-bar

/// The only control on the desk that is dragged rather than pressed, so it is
/// the biggest thing on it and the one the hand finds first.
@MainActor
private struct TBarColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 9) {
            Text("T-BAR").font(Theme.label(9.5)).tracking(2).foregroundStyle(Theme.faint)

            HStack(spacing: 12) {
                Ladder(level: model.ladderLevel)
                track
                Ladder(level: model.ladderLevel)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("PGM").font(Theme.label(9)).tracking(1.4).foregroundStyle(Theme.faint)
                Spacer()
                Text("PST").font(Theme.label(9)).tracking(1.4).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 148)
        .frame(minHeight: 392)
    }

    private var track: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let handle: CGFloat = 52
            let travel = max(1, height - handle)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                    .overlay { RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.lineHi, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.5), radius: 8)

                // A real T: a crossbar to grab and a stem that keeps it in the
                // track. The crossbar overhangs on both sides so it can be
                // found without looking.
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.amberFill)
                        .frame(height: 26)
                        .overlay { RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(hex: 0x6B4415), lineWidth: 1) }
                        .shadow(color: Theme.amber.opacity(0.25), radius: 5)
                        .padding(.horizontal, -14)
                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                        .fill(Color(hex: 0xC9832A))
                        .frame(width: 26, height: 26)
                }
                .offset(y: CGFloat(model.tbarPosition) * travel)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let p = min(max(0, (value.location.y - handle / 2) / travel), 1)
                model.setTBar(Double(p))
            })
        }
        .frame(width: 66)
    }
}

/// One hue, brightness alone carrying the value. Red and green are spoken for
/// by program and preview — a second meaning for the same colour is exactly
/// what misreads on a desk.
private struct Ladder: View {
    let level: Double
    private let count = 26

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                // Measured from the top, because that is where the handle
                // starts and which way it travels.
                //
                // Counted against the number of lamps rather than against the
                // last one's position, or the bottom lamp could never light: at
                // full travel its own position is exactly 1, and 1 < 1 is
                // false. The scale stopped one short of the end.
                let position = Double(index) / Double(count - 1)
                let lit = Double(index) < level * Double(count)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? Color(hue: 0.094, saturation: 0.92,
                                      brightness: 0.42 + position * 0.5)
                              : Color(hex: 0x2A2622))
                    .frame(width: 13, height: 8)
                    .shadow(color: lit ? Theme.amber.opacity(0.5 + position * 0.4) : .clear,
                            radius: 3 + position * 4)
            }
        }
    }
}

// MARK: - Pane chrome

/// The bar every pane wears, with whatever that pane wants beside it.
@MainActor
struct PaneBar<Extra: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 11) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .tracking(2.2).foregroundStyle(Theme.amber)
            Text(subtitle.uppercased())
                .font(Theme.label(9)).tracking(1.6).foregroundStyle(Theme.faint)
            Spacer()
            extra()
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - Assign

/// Which camera sits under which key.
///
/// A button number is not a camera number: on the desk you want them left to
/// right in the order they stand on site. The legend switch is here for the
/// same reason — some operators read names, some read numbers, and both are
/// right.
@MainActor
private struct AssignSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Source assignment").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)
            .background(Theme.raised)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A button number is not a camera number — put them left to right in "
                         + "the order they stand on site. The assignment is shared by both buses.")
                        .font(Theme.value(12)).foregroundStyle(Theme.dim)

                    HStack(spacing: 8) {
                        Text("KEY LEGEND").font(Theme.label(9.5)).tracking(2)
                            .foregroundStyle(Theme.faint)
                        legendChip("BALCONY", on: model.keyLegendIsName) {
                            model.setKeyLegend(name: true)
                        }
                        legendChip("CAM 20", on: !model.keyLegendIsName) {
                            model.setKeyLegend(name: false)
                        }
                    }

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(0..<AppModel.keysPerBus, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("BTN \(String(format: "%02d", index + 1))")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.amber)
                                Picker("", selection: Binding(
                                    get: { model.buttons[index]?.serial ?? "" },
                                    set: { model.assign(button: index, to: $0.isEmpty ? nil : $0) })) {
                                    Text("— none —").tag("")
                                    ForEach(model.cameras) { camera in
                                        Text("\(camera.name) · \(String(format: "CAM %02d", camera.slot))")
                                            .tag(camera.serial)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            }
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                            .overlay { RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.line, lineWidth: 1) }
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 940, height: 620)
        .background(Theme.panel)
    }

    private func legendChip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(on ? Color(hex: 0x141417) : Theme.dim)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(on ? AnyShapeStyle(Theme.amberFill)
                             : AnyShapeStyle(Color(hex: 0x232327))))
        }
        .buttonStyle(.plain)
    }
}

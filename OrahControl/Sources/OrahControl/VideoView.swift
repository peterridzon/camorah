import SwiftUI
import AppKit
import CoreVideo
import QuartzCore
import OrahKit

/// A path for frames that does not go through SwiftUI.
///
/// Thirty frames a second arriving through an observable property would
/// re-evaluate the view tree thirty times a second in order to change one
/// layer's contents. The sink hands each frame straight to the layer instead, so
/// SwiftUI sees the sink once and never sees a frame at all.
final class VideoSink: @unchecked Sendable {

    private let lock = NSLock()
    private var deliver: ((CVPixelBuffer?) -> Void)?
    private var latest: CVPixelBuffer?

    /// Called by the view when its layer is ready. The most recent frame is
    /// replayed immediately, so a view that appears mid-show is not blank until
    /// the next one arrives.
    func connect(_ deliver: @escaping (CVPixelBuffer?) -> Void) {
        let replay = lock.withLock { () -> CVPixelBuffer? in
            self.deliver = deliver
            return latest
        }
        if let replay { deliver(replay) }
    }

    func disconnect() {
        lock.withLock { deliver = nil }
    }

    /// Called from the switcher's pump thread. Layer contents belong to the main
    /// thread, so the hop happens here rather than at every call site.
    func push(_ buffer: CVPixelBuffer?) {
        let deliver = lock.withLock { () -> ((CVPixelBuffer?) -> Void)? in
            latest = buffer
            return self.deliver
        }
        guard let deliver else { return }
        DispatchQueue.main.async { deliver(buffer) }
    }
}

/// Displays decoded frames without copying them.
///
/// The decoder hands out IOSurface-backed pixel buffers, and a `CALayer` can take
/// one directly as its contents — the frame goes from the hardware decoder to the
/// screen without ever passing through CPU memory, which is the rule the whole
/// video path is built on.
final class VideoLayerView: NSView {

    /// Held so the connection can be torn down when the view goes away.
    var sink: VideoSink?

    private let videoLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        // Order matters, and getting it wrong is silent. Setting `wantsLayer`
        // first lets AppKit make its own backing layer, and the one assigned
        // afterwards can be replaced again later — taking the video sublayer
        // with it. Assigning the layer first and then asking for layer backing
        // makes this view the owner of the layer, which AppKit leaves alone.
        let backing = CALayer()
        backing.backgroundColor = NSColor.black.cgColor
        layer = backing
        wantsLayer = true

        videoLayer.contentsGravity = .resizeAspect
        // Frames arrive on the decoder's queue at up to 30 fps; implicit
        // animation on every one would smear them together.
        videoLayer.actions = ["contents": NSNull()]
        backing.addSublayer(videoLayer)
    }

    /// How far to turn the picture, set per lens by the view above.
    ///
    /// Rotating here and nowhere else is deliberate. What leaves for the stitcher
    /// must stay exactly as the camera sent it: the calibration describes the
    /// lenses in that orientation, and turning the pixels would turn the seams
    /// with them. This is a property of the glass on the screen, not of the
    /// signal. See `LensOrientation`.
    var rotation: CGFloat = -.pi / 2 {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Rotating a layer rotates it about its centre, so it has to be given the
        // *unrotated* shape — width and height swapped — and then turned.
        videoLayer.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        videoLayer.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)

        CATransaction.commit()
    }

    func display(_ pixelBuffer: CVPixelBuffer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = pixelBuffer
        CATransaction.commit()
    }
}

struct VideoView: NSViewRepresentable {
    let sink: VideoSink

    /// Which of the four lenses this is. It decides how far the picture has to
    /// be turned: the camera's two boards face opposite ways.
    var lens: Int = 0

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView(frame: .zero)
        view.sink = sink
        view.rotation = LensOrientation.displayRotation(forLens: lens)
        sink.connect { [weak view] buffer in view?.display(buffer) }
        return view
    }

    func updateNSView(_ view: VideoLayerView, context: Context) {
        // Only the rotation comes through here; frames arrive on the sink.
        view.rotation = LensOrientation.displayRotation(forLens: lens)
    }

    static func dismantleNSView(_ view: VideoLayerView, coordinator: Void) {
        view.sink?.disconnect()
    }
}

/// What the camera is doing, while it is not yet a picture.
///
/// A camera takes about twenty seconds from Start to its first frame. Showing
/// only "NO SIGNAL" through that window is not wrong, it is just useless: it
/// looks the same as a camera that is switched off, and the same as an app that
/// has hung. So the wait is drawn as a wait.
@MainActor
struct StartupStatus: View {
    let phase: RigState
    let startedAt: Date?
    let lensesArriving: Int
    var step: String? = nil
    var compact = false

    /// Measured on the bench: about fifteen seconds from the command to the
    /// first packet, twenty to all four streams.
    private let expected: TimeInterval = 20

    /// Only a camera that has sent nothing at all is "waiting". Once any lens
    /// arrives the useful thing to show is how much of it is here.
    private var isWaitingForAnything: Bool {
        // A step in progress counts even before the state has caught up: the
        // sequence takes twenty seconds and the operator needs to see it move
        // from the instant the button is pressed.
        if step != nil { return lensesArriving == 0 }
        if case .starting = phase { return lensesArriving == 0 }
        return false
    }

    private var isQuiet: Bool {
        phase == .absent || phase == .onNetwork
    }

    var body: some View {
        VStack(spacing: compact ? 5 : 9) {
            if isWaitingForAnything, let startedAt {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt)
                    VStack(spacing: compact ? 4 : 7) {
                        // The step, when there is one: it says the sequence is
                        // moving. Falling back to the elapsed time only once
                        // there is nothing else to report.
                        Text((step ?? (elapsed > expected ? "still waiting" : phase.label)).uppercased())
                            .font(Theme.label(compact ? 8.5 : 10))
                            .tracking(compact ? 1.2 : 2.2)
                            .foregroundStyle(Theme.orange)
                            .lineLimit(1)

                        bar(progress: min(elapsed / expected, 1))

                        Text("\(Int(elapsed)) s")
                            .font(Theme.value(compact ? 8.5 : 10))
                            .foregroundStyle(Theme.dim)
                    }
                }
            } else {
                Text(phase.label.uppercased())
                    .font(Theme.label(compact ? 8.5 : 10))
                    .tracking(compact ? 1.2 : 2.2)
                    .foregroundStyle(isQuiet ? Theme.faint : Theme.dim)
            }

            if phase != .absent {
                lenses
            }
        }
        .padding(.horizontal, compact ? 8 : 20)
    }

    private func bar(progress: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.orange)
                    .frame(width: max(3, geometry.size.width * progress))
            }
        }
        .frame(height: compact ? 2.5 : 4)
        .frame(maxWidth: compact ? 90 : 220)
    }

    /// Four marks, one per lens. Half a camera arriving is a real state — one
    /// SoC comes up and the other does not — and a single number hides it.
    private var lenses: some View {
        HStack(spacing: compact ? 2.5 : 4) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lensesArriving ? Theme.yellow : Theme.dead)
                    .frame(width: compact ? 9 : 15, height: compact ? 2.5 : 3.5)
            }
        }
    }
}

/// A monitor: the picture, its tally border, and the labels that belong on it.
struct Monitor: View {
    enum Role {
        case program, preview

        var colour: Color {
            switch self {
            case .program: Theme.program
            case .preview: Theme.preview
            }
        }
        var caption: String {
            switch self {
            case .program: "● ON AIR"
            case .preview: "PREVIEW"
            }
        }
        var filled: Bool { self == .program }
    }

    let role: Role
    let title: String
    let detail: String
    let sink: VideoSink
    var lens: Int = 0
    var hasSignal: Bool = false
    var phase: RigState = .absent
    var startedAt: Date? = nil
    var lensesArriving: Int = 0
    var step: String? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black)

            // The layer stays mounted whether or not a picture is arriving:
            // tearing it down and rebuilding it on every cut would drop the
            // first frames of the camera being cut to, which is exactly the
            // moment worth seeing.
            VideoView(sink: sink, lens: lens)

            if !hasSignal {
                // Not an error state: before cameras are started there is simply
                // nothing to show, and what it is doing instead beats a black
                // rectangle.
                ZStack {
                    Rectangle().fill(Theme.panel)
                    StartupStatus(phase: phase,
                                  startedAt: startedAt,
                                  lensesArriving: lensesArriving,
                                  step: step)
                }
            }

            HStack(alignment: .top) {
                Text(role.caption)
                    .font(Theme.label(9.5))
                    .tracking(1.6)
                    .foregroundStyle(role.filled ? .white : role.colour)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background {
                        if role.filled { role.colour }
                        else { Color.black.opacity(0.6) }
                    }
                    .overlay {
                        if !role.filled {
                            RoundedRectangle(cornerRadius: 3).stroke(role.colour, lineWidth: 1)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer()

                Text(title)
                    .font(Theme.value(11))
                    .foregroundStyle(Theme.fg)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(9)

            VStack {
                Spacer()
                HStack {
                    Text(detail)
                        .font(Theme.value(10))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
            }
        }
        // 1440×1920 once it is the right way up.
        .aspectRatio(1440.0/1920.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(role.colour, lineWidth: 2)
        }
    }
}

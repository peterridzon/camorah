import Foundation
import CoreMedia
import CoreVideo

/// The switcher: four lanes that always move together.
///
/// A camera is not one picture, it is four — one per lens — and Vahana expects
/// those four on four fixed inputs. Switching camera therefore means switching
/// four streams *at the same instant*; if one lane crosses a few frames before
/// another, the stitcher spends the transition sewing one camera's lens to
/// another's, and it shows on the seams.
///
/// That is the whole reason this exists as one object rather than four. There is
/// a single mix value, a single output clock, and every lane reads both. Four
/// separate processes — which is what four OBS instances are — cannot make that
/// promise.
public final class Switcher: @unchecked Sendable {

    public static let lenses = ["0_0", "0_1", "1_0", "1_1"]

    public enum TransitionKind: Sendable {
        case cut
        case dissolve(Duration)
    }

    public struct Status: Sendable {
        public var programSlot: Int?
        public var previewSlot: Int?
        public var mix: Float
        public var isTransitioning: Bool
        public var outputFrames: Int
        public var lateFrames: Int
    }

    // MARK: - State

    private let lock = NSLock()
    private var programSlot: Int?
    private var previewSlot: Int?

    /// 0 = entirely program, 1 = entirely preview. Shared by all four lanes.
    private var mix: Float = 0
    private var transition: (start: ContinuousClock.Instant, duration: Duration)?

    /// Decoded frames, keyed by camera slot then lens index.
    private var buffers: [Int: [FrameBuffer]] = [:]

    /// One compositor per lane. They hold a pixel-buffer pool and counters, so a
    /// single shared instance driven by four concurrent lanes trapped in the
    /// Swift runtime. Separate instances also avoid contending for the pool.
    private let compositors: [MetalCompositor]
    private var encoders: [H264Encoder?] = Array(repeating: nil, count: 4)
    private var outputs: [FFmpegOutput?] = Array(repeating: nil, count: 4)

    private let fps: Int32
    private let bitrate: Int
    private var pump: Task<Void, Never>?
    private var outputFrameIndex: Int64 = 0
    private let clock = ContinuousClock()

    public private(set) var outputFrames = 0
    public private(set) var lateFrames = 0

    /// A tap for the on-screen monitors, one lens.
    ///
    /// Programme is the *composited* picture — what actually leaves the desk,
    /// dissolve included — while preview is its source untouched, because
    /// preview's job is to show what is coming, not what the mix is doing to it.
    /// Only one lens is tapped: four on screen would be four times the work to
    /// show the same camera from four angles nobody is judging.
    /// Programme picture, the lens it came from, preview picture, its lens.
    ///
    /// The lens matters: each one needs turning by a different amount to look
    /// right, because the two boards inside the camera face opposite ways.
    public var onMonitorFrame: ((CVPixelBuffer?, Int, CVPixelBuffer?, Int) -> Void)?

    /// Every lane, exactly as it leaves for the stitcher.
    ///
    /// The desk monitor shows one lens because the operator is judging framing,
    /// not encoding. This is the other question — what the output actually looks
    /// like — and it can only be answered by looking at all four at full size.
    /// The frames are already composited for the encoder, so the tap costs a
    /// retain and nothing else.
    public var onOutputFrames: (([CVPixelBuffer?]) -> Void)?

    /// Somewhere for the concurrent lane to leave its picture. The lanes run in
    /// parallel, so this cannot be a plain `var` captured by the block.
    private final class FrameSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CVPixelBuffer?
        func set(_ buffer: CVPixelBuffer) { lock.withLock { value = buffer } }
        var current: CVPixelBuffer? { lock.withLock { value } }
    }

    // Where the time in a tick actually goes, in seconds.
    public private(set) var timeTick = 0.0
    public private(set) var timeComposite = 0.0
    public private(set) var timeEncode = 0.0

    public init(fps: Int32 = 30, bitrate: Int = 12_000_000) throws {
        self.fps = fps
        self.bitrate = bitrate
        self.compositors = try (0..<4).map { _ in try MetalCompositor() }
    }

    // MARK: - Sources

    /// Registers a camera. Call before making it program or preview.
    public func addSource(slot: Int) {
        lock.withLock {
            guard buffers[slot] == nil else { return }
            buffers[slot] = (0..<4).map { _ in FrameBuffer() }
        }
    }

    public func removeSource(slot: Int) {
        lock.withLock { buffers[slot] = nil }
    }

    /// Feeds one decoded frame in. Called from the decoder for `slot`/`lens`.
    public func submit(slot: Int, lens: Int, frame: CVPixelBuffer, pts: CMTime) {
        lock.withLock { buffers[slot]?[lens] }?.append(frame, pts: pts)
    }

    /// Per-camera delay, applied to all four of its lenses together.
    ///
    /// Cameras free-run on their own crystals with no genlock, so they need
    /// aligning against each other — but the four lenses of one camera share a
    /// board and a clock, so they are always delayed as a set.
    public func setDelay(slot: Int, seconds: Double) {
        lock.withLock {
            buffers[slot]?.forEach { $0.delaySeconds = seconds }
        }
    }

    // MARK: - Outputs

    /// Attaches the four output lanes that feed the stitcher.
    public func startOutputs(urlForLens: (String) -> String) throws {
        for index in 0..<4 {
            let output = FFmpegOutput(url: urlForLens(Self.lenses[index]), fps: fps)
            try output.start()
            outputs[index] = output
        }
    }

    // MARK: - Switching

    public func setPreview(slot: Int?) {
        lock.withLock { previewSlot = slot }
    }

    public func setProgram(slot: Int?) {
        lock.withLock {
            programSlot = slot
            mix = 0
            transition = nil
        }
    }

    /// Puts preview on air.
    public func take(_ kind: TransitionKind = .dissolve(.milliseconds(600))) {
        lock.withLock {
            guard previewSlot != nil else { return }
            switch kind {
            case .cut:
                swapUnlocked()
            case .dissolve(let duration):
                transition = (clock.now, duration)
            }
        }
    }

    /// Drives the mix directly — the T-bar, or a MIDI fader.
    public func setMix(_ value: Float) {
        lock.withLock {
            transition = nil
            mix = min(max(value, 0), 1)
            if mix >= 0.9999 { swapUnlocked() }
        }
    }

    /// Once the transition completes, what was preview becomes program and the
    /// bar rests at zero again, ready for the next one.
    private func swapUnlocked() {
        let old = programSlot
        programSlot = previewSlot
        previewSlot = old
        mix = 0
        transition = nil
    }

    // MARK: - The output pump

    /// Starts producing output at a fixed rate.
    ///
    /// The clock drives the output, not the arrival of input frames. Vahana
    /// rejects variable frame rate outright, and a pump means input jitter never
    /// reaches the encoder: every tick takes whatever frame is current and sends
    /// exactly one out.
    public func start() {
        guard pump == nil else { return }
        let interval = Duration.seconds(1.0 / Double(fps))

        pump = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var next = self.clock.now
            while !Task.isCancelled {
                next = next.advanced(by: interval)
                self.tick()
                let now = self.clock.now
                if now < next {
                    try? await Task.sleep(until: next, clock: ContinuousClock())
                } else {
                    // Behind schedule: skip the wait and note it rather than
                    // letting the output rate quietly sag below CFR.
                    self.noteLate()
                    next = now
                }
            }
        }
        Log.info("switch", "output pump running at \(fps) fps")
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        for encoder in encoders { encoder?.finish() }
        for output in outputs { output?.stop() }
    }

    private func noteLate() {
        lock.withLock { lateFrames += 1 }
    }

    private func tick() {
        // Snapshot the shared state once, so all four lanes composite the same
        // instant of the same transition.
        let (program, preview, mixNow) = lock.withLock { () -> (Int?, Int?, Float) in
            if let t = transition {
                let elapsed = clock.now - t.start
                let progress = Float(elapsed / t.duration)
                if progress >= 1.0 {
                    swapUnlocked()
                } else {
                    mix = max(0, min(1, progress))
                }
            }
            return (programSlot, previewSlot, mix)
        }

        guard let program else { return }
        let tickStart = clock.now

        let pts = CMTime(value: outputFrameIndex, timescale: fps)
        outputFrameIndex += 1

        // Encoders are built here, serially, before anything runs in parallel.
        // Creating them inside the concurrent block meant four threads writing
        // into the same Swift array at once, which is not safe even at different
        // indices — it segfaulted.
        if encoders.contains(where: { $0 == nil }),
           let sample = lock.withLock({ buffers[program]?[0] })?.current() {
            let width = Int32(CVPixelBufferGetWidth(sample.pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(sample.pixelBuffer))
            for lens in 0..<4 where encoders[lens] == nil {
                do {
                    let encoder = try H264Encoder(settings: .init(
                        width: width, height: height, fps: fps, bitrate: bitrate))
                    let sink = outputs[lens]
                    encoder.onEncoded = { data, _, _ in sink?.write(data) }
                    encoders[lens] = encoder
                } catch {
                    Log.error("switch", "lane \(Self.lenses[lens]) encoder: \(error)")
                }
            }
        }

        // The four lanes are independent and each `encode` call carries a fixed
        // wait — measured at 43 ms for one lane, but only 57 ms for four, which is
        // the signature of latency rather than work. Called in sequence that wait
        // stacks up and drags the pump to a third of its rate; run side by side it
        // is paid once.
        let monitorTap = onMonitorFrame
        let monitorPicture = monitorTap == nil ? nil : FrameSlot()

        let outputTap = onOutputFrames
        let outputPictures = outputTap == nil ? nil : (0..<4).map { _ in FrameSlot() }

        // Which lens the monitors show.
        //
        // Not simply the first one: a camera routinely comes up with only half
        // its lenses, because it is two SoCs and one of them can fail to start.
        // Pinning the monitor to lens 0 means a camera that is visibly working —
        // two streams arriving, being switched, going out — shows a black
        // rectangle on the desk. So the monitor shows the first lens that has a
        // picture, preferring 0 when it does.
        let monitorLens = firstLensWithPicture(slot: program) ?? 0

        DispatchQueue.concurrentPerform(iterations: 4) { lens in
            guard let programFrame = lock.withLock({ buffers[program]?[lens] })?.current() else {
                return
            }
            let previewFrame = preview.flatMap { slot in
                lock.withLock { buffers[slot]?[lens] }?.current()
            }

            do {
                let t1 = clock.now
                let composed = try compositors[lens].composite(
                    from: programFrame.pixelBuffer,
                    to: mixNow > 0.0001 ? previewFrame?.pixelBuffer : nil,
                    mix: mixNow)
                if lens == monitorLens { monitorPicture?.set(composed) }
                outputPictures?[lens].set(composed)
                let t2 = clock.now

                try encoders[lens]?.encode(composed, pts: pts)
                let t3 = clock.now
                lock.withLock {
                    timeComposite += seconds(t2 - t1)
                    timeEncode += seconds(t3 - t2)
                }
            } catch {
                Log.warn("switch", "lane \(Self.lenses[lens]): \(error)")
            }
        }

        if let outputTap, let outputPictures {
            outputTap(outputPictures.map(\.current))
        }

        if let monitorTap {
            var previewLens = 0
            let previewPicture = preview.flatMap { slot -> CVPixelBuffer? in
                guard let lens = firstLensWithPicture(slot: slot) else { return nil }
                previewLens = lens
                return lock.withLock { buffers[slot]?[lens] }?.current()?.pixelBuffer
            }
            monitorTap(monitorPicture?.current, monitorLens, previewPicture, previewLens)
        }

        lock.withLock {
            outputFrames += 1
            timeTick += seconds(clock.now - tickStart)
        }
    }

    private func firstLensWithPicture(slot: Int) -> Int? {
        (0..<4).first { lens in
            lock.withLock { buffers[slot]?[lens] }?.current() != nil
        }
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public var status: Status {
        lock.withLock {
            Status(programSlot: programSlot,
                   previewSlot: previewSlot,
                   mix: mix,
                   isTransitioning: transition != nil,
                   outputFrames: outputFrames,
                   lateFrames: lateFrames)
        }
    }
}

/// Thin RTMP publisher: our encoded Annex B on stdin, RTMP out.
///
/// FFmpeg only rewraps the container here — no decode, no encode. Measured at
/// 0.7% CPU for both directions (MEASUREMENTS M1).
public final class FFmpegOutput: @unchecked Sendable {
    private let url: String
    private let fps: Int32
    private var process: Process?
    private var pipe: Pipe?
    private let lock = NSLock()
    public private(set) var bytesWritten = 0
    public private(set) var framesDroppedFromBacklog = 0

    /// Writes happen here, never on the encoder's callback thread.
    ///
    /// Writing straight from the VideoToolbox callback backpressures the whole
    /// encoder the moment the pipe fills: measured at 62 ms per tick across four
    /// lanes, which dragged a 30 fps pump down to 7 fps. The codec must never
    /// wait on I/O.
    private let writeQueue: DispatchQueue
    private var backlog = 0
    private let maxBacklog = 8

    public init(url: String, fps: Int32) {
        self.url = url
        self.fps = fps
        self.writeQueue = DispatchQueue(label: "orah.output.\(url.hashValue)", qos: .userInitiated)
    }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        let pipe = Pipe()
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "FFmpegOutput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"])
        }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer",
            // A raw H.264 stream carries no timestamps and the FLV muxer refuses
            // packets without them, so the demuxer stamps them on arrival.
            "-use_wallclock_as_timestamps", "1",
            // And it must not sit probing: the default 5 MB scan takes longer over
            // a live pipe than the server's publish timeout (MEASUREMENTS M1).
            "-probesize", "100000", "-analyzeduration", "100000",
            "-f", "h264", "-framerate", "\(fps)",
            "-i", "pipe:0",
            "-c", "copy",
            "-muxdelay", "0", "-muxpreload", "0",
            "-f", "flv", url,
        ]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        self.process = process
        self.pipe = pipe
    }

    public func write(_ data: Data) {
        guard let handle = pipe?.fileHandleForWriting else { return }

        // If the far end has stopped draining, drop rather than queue without
        // limit: unbounded growth would turn a slow link into exhausted memory,
        // and a dropped frame on a stalled output is already invisible.
        let accepted: Bool = lock.withLock {
            guard backlog < maxBacklog else {
                framesDroppedFromBacklog += 1
                return false
            }
            backlog += 1
            return true
        }
        guard accepted else { return }

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try handle.write(contentsOf: data)
                self.lock.withLock {
                    self.bytesWritten += data.count
                    self.backlog -= 1
                }
            } catch {
                self.lock.withLock { self.backlog -= 1 }
                Log.warn("switch", "output \(self.url) closed")
            }
        }
    }

    public func stop() {
        try? pipe?.fileHandleForWriting.close()
        process?.terminate()
    }
}

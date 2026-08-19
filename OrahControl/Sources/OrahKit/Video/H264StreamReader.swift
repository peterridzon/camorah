import Foundation
import CoreMedia
import CoreVideo

/// Pulls one RTMP stream and hands out decoded frames.
///
/// FFmpeg does nothing but unwrap the container — the elementary stream comes out
/// of a pipe, gets reassembled into access units here, and is decoded in hardware.
public final class H264StreamReader: @unchecked Sendable {

    public enum ReaderError: Error, CustomStringConvertible {
        case ffmpegNotFound
        case launchFailed(String)

        public var description: String {
            switch self {
            case .ffmpegNotFound: return "ffmpeg not found on PATH"
            case .launchFailed(let m): return "could not start input leg: \(m)"
            }
        }
    }

    public let url: String
    private let fps: Int32
    private var process: Process?
    private var pipe: Pipe?
    private let decoder = H264Decoder()

    private let lock = NSLock()
    private var stopped = false
    private var retry: Task<Void, Never>?
    private var attempts = 0

    /// Called for every decoded frame, on the decoder's queue.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var splitter = AccessUnitSplitter()
    private var frameIndex: Int64 = 0

    public private(set) var framesIn = 0

    public init(url: String, fps: Int32 = 30) {
        self.url = url
        self.fps = fps
    }

    /// Starts reading, and keeps trying until there is something to read.
    ///
    /// A camera takes about fifteen seconds from being told to start until it
    /// actually publishes, and MediaMTX closes a reader that asks for a path with
    /// nothing on it. Connecting once and giving up therefore means the desk sits
    /// black through exactly the window where the picture arrives.
    public func start() throws {
        lock.withLock { stopped = false }
        try launch()
    }

    private func launch() throws {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw ReaderError.ffmpegNotFound
        }

        decoder.onFrame = { [weak self] buffer, pts in
            self?.onFrame?(buffer, pts)
        }

        // A reconnect is a new byte stream with its own parameter sets, so
        // whatever was half-parsed from the last one has to go.
        lock.withLock {
            // A reconnect is a new byte stream with its own parameter sets.
            splitter.reset()
            attempts += 1
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-i", url,
            "-an",
            "-c:v", "copy",
            "-bsf:v", "h264_mp4toannexb",
            "-f", "h264", "pipe:1",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for unit in self.splitter.push(chunk) { self.emit(unit) }
        }

        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.relaunchLater()
        }

        do {
            try process.run()
        } catch {
            throw ReaderError.launchFailed(error.localizedDescription)
        }
        lock.withLock {
            self.process = process
            self.pipe = pipe
        }
    }

    /// Tries again, backing off.
    ///
    /// It used to try once a second for as long as the source was attached, and
    /// each try is a process launched and an RTMP connection opened and closed.
    /// One reader doing that is invisible; a rig where several cameras are on
    /// the network but not publishing is a dozen readers doing it at once, and
    /// that was enough to flood MediaMTX, fill the log, and make the desk lag —
    /// a spin loop wearing the costume of a retry.
    ///
    /// Quick at first, because a camera takes about fifteen seconds to publish
    /// after being told to start and the picture should appear the moment it
    /// does. Then it slows to once every ten seconds, which is often enough for
    /// something nobody is waiting on.
    private func relaunchLater() {
        let (shouldRetry, count) = lock.withLock { (!stopped, attempts) }
        guard shouldRetry else { return }

        let delay = ReaderPolicy.retryDelay(attempt: count)
        if ReaderPolicy.shouldLog(attempt: count) {
            Log.info("read", "waiting for \(url)")
        }

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.lock.withLock({ !self.stopped }) else { return }
            do { try self.launch() } catch { self.relaunchLater() }
        }
        lock.withLock { retry = task }
    }

    public func stop() {
        let running = lock.withLock { () -> Process? in
            stopped = true
            retry?.cancel()
            retry = nil
            pipe?.fileHandleForReading.readabilityHandler = nil
            pipe = nil
            defer { process = nil }
            return process
        }
        running?.terminate()
        // Make sure it is actually gone. A reader left behind keeps its RTMP
        // connection open, and the next run of the app finds the path already
        // taken by a process nobody owns any more — which is what happened after
        // several restarts today.
        if let running, running.isRunning {
            let deadline = Date().addingTimeInterval(1.0)
            while running.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
        decoder.flush()
    }

    // Splitting the byte stream into access units is its own part, with its own
    // rules and its own tests — `AccessUnitSplitter`. It lived here, where it
    // could not be tested, and it broke twice in one evening: once by rescanning
    // the whole buffer on every chunk from the pipe, and once by finding its own
    // start code at offset zero and spinning at eight hundred percent of a core.
    // The reader owns the process and the pipe. It does not own the bytes.

    private func emit(_ unit: Data) {
        guard !unit.isEmpty else { return }
        framesIn += 1

        // A raw stream carries no timestamps. The switcher's output clock is what
        // decides timing anyway, so a frame index is enough to keep the decoder
        // ordered.
        let pts = CMTime(value: frameIndex, timescale: fps)
        frameIndex += 1
        try? decoder.decode(annexB: unit, pts: pts)
    }
}

/// One camera: four streams, four decoders, feeding a switcher.
public final class CameraSource: @unchecked Sendable {

    public let slot: Int
    private let lock = NSLock()
    private var readers: [Int: H264StreamReader] = [:]
    /// Which path each lens is being read from — a lens can be the camera's own
    /// stream one moment and a node's proxy the next.
    private var paths: [Int: String] = [:]
    private var base = ""
    private var fps: Int32 = 30
    private weak var switcher: Switcher?

    public init(slot: Int) {
        self.slot = slot
    }

    /// Which lenses this source is currently decoding.
    public var lenses: [Int] { lock.withLock { readers.keys.sorted() } }

    /// What it is reading, in full — the pair matters, because a proxy is one
    /// path standing in for a lens.
    public var streams: [SourceRouting.Stream] {
        lock.withLock { paths.map { SourceRouting.Stream(lens: $0.key, path: $0.value) } }
            .sorted { $0.lens < $1.lens }
    }

    /// Attaches to `rtmp://host:1935/camNN/` and routes lenses into `switcher`.
    ///
    /// Not always all four. A camera on the desk needs every lens, because the
    /// mix sends four lanes out. A camera that is only a thumbnail needs the one
    /// lens somebody is looking at — decoding the other three to throw them away
    /// is three hardware decodes per camera, and with two dozen cameras that is
    /// the difference between a multiview and a slideshow.
    /// Every lens of the camera, read from its own streams.
    public static let everyLens = (0..<4).map {
        SourceRouting.Stream(lens: $0, path: Switcher.lenses[$0])
    }

    public func attach(to switcher: Switcher, rtmpBase: String, fps: Int32 = 30,
                       streams: [SourceRouting.Stream] = CameraSource.everyLens) throws {
        self.base = rtmpBase.hasSuffix("/") ? rtmpBase : rtmpBase + "/"
        self.fps = fps
        self.switcher = switcher
        switcher.addSource(slot: slot)
        try setStreams(streams)
        Log.info("switch", "camera \(slot) attached from \(base)")
    }

    /// Adds and removes lenses without disturbing the ones already running.
    ///
    /// This is why a source is never rebuilt to change its lenses. Putting a
    /// thumbnail on the programme bus used to stop its reader and start four new
    /// ones, so the picture the operator had been looking at went black and came
    /// back three seconds later — the exact three seconds in which a cut is
    /// supposed to have happened. The lens that is already decoding keeps
    /// decoding; the other three join it when their first keyframe lands.
    /// Locked, because this is called off the main thread.
    ///
    /// Starting a reader spawns a process and opens an RTMP connection, which
    /// takes long enough to be seen: doing it on the main thread meant that
    /// pressing a programme key stalled the interface while three ffmpegs were
    /// launched. A cut has to happen on the press. So this runs on a background
    /// queue, and two rapid cuts can therefore be in here at once.
    public func setStreams(_ wanted: [SourceRouting.Stream]) throws {
        guard let switcher else { return }
        var target: [Int: String] = [:]
        for stream in wanted where (0..<4).contains(stream.lens) {
            target[stream.lens] = stream.path
        }

        let (toStop, toStart) = lock.withLock { () -> ([H264StreamReader], [Int]) in
            let stopping = readers.filter { paths[$0.key] != target[$0.key] }
            for index in stopping.keys { readers[index] = nil; paths[index] = nil }
            let starting = target.keys.sorted().filter { readers[$0] == nil }
            return (Array(stopping.values), starting)
        }

        toStop.forEach { $0.stop() }

        for index in toStart {
            let path = target[index] ?? Switcher.lenses[index]
            let reader = H264StreamReader(url: base + path, fps: fps)
            reader.onFrame = { [weak switcher] buffer, pts in
                switcher?.submit(slot: self.slot, lens: index, frame: buffer, pts: pts)
            }
            try reader.start()
            // Another call may have started this lens while we were spawning.
            let duplicate = lock.withLock { () -> H264StreamReader? in
                if readers[index] != nil { return reader }
                readers[index] = reader
                paths[index] = target[index]
                return nil
            }
            duplicate?.stop()
        }
    }

    public func stop() {
        let running = lock.withLock { () -> [H264StreamReader] in
            let all = Array(readers.values)
            readers.removeAll()
            paths.removeAll()
            return all
        }
        running.forEach { $0.stop() }
    }

    public var framesIn: Int {
        lock.withLock { readers.values.reduce(0) { $0 + $1.framesIn } }
    }
}

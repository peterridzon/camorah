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

    private var pending = Data()
    private var currentUnit = Data()
    private var currentHasVCL = false
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
            pending.removeAll(keepingCapacity: true)
            currentUnit.removeAll(keepingCapacity: true)
            currentHasVCL = false
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
            self.pending.append(chunk)
            self.drainAccessUnits()
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

    /// Waits a second and tries again, for as long as the source is attached.
    ///
    /// The desk lets a camera go as soon as it stops streaming, so this does not
    /// run forever against a camera that is off — it runs exactly while one is
    /// expected and has not arrived yet.
    private func relaunchLater() {
        let (shouldRetry, count) = lock.withLock { (!stopped, attempts) }
        guard shouldRetry else { return }

        // A camera that never comes up would otherwise write a line a second for
        // the rest of the show.
        if count == 1 || count % 15 == 0 {
            Log.info("read", "waiting for \(url)")
        }

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
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

    // A raw H.264 pipe is a byte stream, not frames. A new access unit begins at
    // the first picture NAL that follows a previous one; parameter sets and SEI
    // belong to whatever comes next.
    private func drainAccessUnits() {
        let bytes = [UInt8](pending)
        var starts: [(offset: Int, codeLength: Int)] = []

        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3)); i += 3; continue
                }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }

        guard starts.count >= 2 else { return }

        for index in 0..<(starts.count - 1) {
            let begin = starts[index].offset
            let end = starts[index + 1].offset
            let nalStart = begin + starts[index].codeLength
            guard nalStart < end, nalStart < bytes.count else { continue }

            let nalType = bytes[nalStart] & 0x1F
            let isVCL = (1...5).contains(nalType)

            if isVCL && currentHasVCL { emitAccessUnit() }
            currentUnit.append(contentsOf: bytes[begin..<end])
            if isVCL { currentHasVCL = true }
        }

        pending = Data(bytes[starts[starts.count - 1].offset...])
    }

    private func emitAccessUnit() {
        defer {
            currentUnit.removeAll(keepingCapacity: true)
            currentHasVCL = false
        }
        guard !currentUnit.isEmpty else { return }
        framesIn += 1

        // A raw stream carries no timestamps. The switcher's output clock is what
        // decides timing anyway, so a frame index is enough to keep the decoder
        // ordered.
        let pts = CMTime(value: frameIndex, timescale: fps)
        frameIndex += 1
        try? decoder.decode(annexB: currentUnit, pts: pts)
    }
}

/// One camera: four streams, four decoders, feeding a switcher.
public final class CameraSource: @unchecked Sendable {

    public let slot: Int
    private var readers: [H264StreamReader] = []

    public init(slot: Int) {
        self.slot = slot
    }

    /// Attaches to `rtmp://host:1935/camNN/` and routes every lens into `switcher`.
    public func attach(to switcher: Switcher, rtmpBase: String, fps: Int32 = 30) throws {
        let base = rtmpBase.hasSuffix("/") ? rtmpBase : rtmpBase + "/"
        switcher.addSource(slot: slot)

        for (index, lens) in Switcher.lenses.enumerated() {
            let reader = H264StreamReader(url: base + lens, fps: fps)
            reader.onFrame = { [weak switcher] buffer, pts in
                switcher?.submit(slot: self.slot, lens: index, frame: buffer, pts: pts)
            }
            try reader.start()
            readers.append(reader)
        }
        Log.info("switch", "camera \(slot) attached from \(base)")
    }

    public func stop() {
        readers.forEach { $0.stop() }
        readers.removeAll()
    }

    public var framesIn: Int {
        readers.reduce(0) { $0 + $1.framesIn }
    }
}

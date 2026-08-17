import Foundation
import CoreMedia
import CoreVideo

/// One end-to-end video lane: RTMP in, hardware decode, hardware encode, RTMP out.
///
/// This is the switcher's spine with the interesting part left out — there is no
/// mixing here yet, one input goes to one output. It exists to prove the hardware
/// path and to measure it, because everything else in the design rests on that
/// path being cheap.
///
///     ffmpeg -c copy ──► Annex B ──► VTDecompression ──► CVPixelBuffer
///                                                             │
///     ffmpeg -c copy ◄── Annex B ◄── VTCompression ◄──────────┘
///
/// FFmpeg only ever rewraps containers; it never touches a pixel.
public final class TranscodeLane {

    public struct Stats {
        public var framesIn = 0
        public var framesDecoded = 0
        public var framesEncoded = 0
        public var bytesOut = 0
        public var firstFrameAt: Date?
    }

    public enum LaneError: Error, CustomStringConvertible {
        case inputFailed(String)
        case outputFailed(String)

        public var description: String {
            switch self {
            case .inputFailed(let m): return "input leg failed: \(m)"
            case .outputFailed(let m): return "output leg failed: \(m)"
            }
        }
    }

    private let inputURL: String
    private let outputURL: String
    private let fps: Int32
    private let bitrate: Int

    private var inputProcess: Process?
    private var outputProcess: Process?
    private var outputPipe: Pipe?

    private var decoder = H264Decoder()
    private var encoder: H264Encoder?

    private let lock = NSLock()
    private var stats = Stats()

    /// Output timestamps sit on a fixed grid. Vahana rejects variable frame rate,
    /// so the encoder is driven by a frame counter rather than by input timing.
    private var outputFrameIndex: Int64 = 0

    public init(input: String, output: String, fps: Int32 = 30, bitrate: Int = 8_000_000) {
        self.inputURL = input
        self.outputURL = output
        self.fps = fps
        self.bitrate = bitrate
    }

    public var currentStats: Stats {
        lock.withLock { stats }
    }

    // MARK: - Running

    public func start() throws {
        // A closed output pipe must surface as a write error, not as a signal that
        // kills the whole process. Without this the lane dies with SIGPIPE the
        // moment the downstream ffmpeg exits, and takes the diagnosis with it.
        signal(SIGPIPE, SIG_IGN)

        try startOutputLeg()
        try startInputLeg()
    }

    public func stop() {
        inputProcess?.terminate()
        decoder.flush()
        encoder?.finish()
        try? outputPipe?.fileHandleForWriting.close()
        outputProcess?.terminate()
    }

    /// Output leg: takes Annex B on stdin and republishes it. Streamcopy only.
    private func startOutputLeg() throws {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        if !FileManager.default.fileExists(atPath: process.executableURL!.path) {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        }
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer",
            // A raw H.264 pipe carries no timestamps, so the demuxer is told the
            // rate and asked to stamp packets as they arrive. Without this the
            // FLV muxer refuses them outright.
            "-use_wallclock_as_timestamps", "1",
            // And it must not sit scanning first: the default 5 MB probe takes
            // longer over a live pipe than the server's 10 s publish timeout, so
            // the connection was being opened and then dropped before a single
            // frame was sent.
            "-probesize", "100000", "-analyzeduration", "100000",
            "-f", "h264", "-framerate", "\(fps)",
            "-i", "pipe:0",
            "-c", "copy",
            // Without these the mpegts/flv muxers shift every timestamp forward
            // by 1.2s of default mux delay — measured, see docs/MEASUREMENTS.md.
            "-muxdelay", "0", "-muxpreload", "0",
            "-f", "flv", outputURL,
        ]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice

        // Keep the output leg's complaints: when it rejects our elementary stream
        // this is the only place that says why.
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            for line in text.split(separator: "\n") {
                Log.warn("lane/out", String(line))
            }
        }

        process.terminationHandler = { proc in
            Log.error("lane/out", "output ffmpeg exited with status \(proc.terminationStatus)")
        }

        do {
            try process.run()
        } catch {
            throw LaneError.outputFailed(error.localizedDescription)
        }

        outputProcess = process
        outputPipe = pipe
    }

    /// Input leg: pulls RTMP and emits an Annex B elementary stream. No decode.
    private func startInputLeg() throws {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        if !FileManager.default.fileExists(atPath: process.executableURL!.path) {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        }
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-i", inputURL,
            "-an",                       // video only for now; audio joins later
            "-c:v", "copy",
            "-bsf:v", "h264_mp4toannexb",
            "-f", "h264", "pipe:1",
        ]
        process.standardOutput = pipe

        let inErr = Pipe()
        process.standardError = inErr
        inErr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            for line in text.split(separator: "\n") {
                Log.warn("lane/in", String(line))
            }
        }

        wireDecoder()

        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            pending.append(chunk)
            self.drainAccessUnits(from: &pending)
        }

        do {
            try process.run()
        } catch {
            throw LaneError.inputFailed(error.localizedDescription)
        }
        inputProcess = process
    }

    // MARK: - Access unit assembly
    //
    // A raw H.264 pipe is a byte stream, not a sequence of frames. Frames have to
    // be reassembled: a new access unit begins at the first VCL NAL that follows
    // a previous one, with parameter sets and SEI belonging to whatever comes next.

    private var currentUnit = Data()
    private var currentHasVCL = false

    private func drainAccessUnits(from buffer: inout Data) {
        let bytes = [UInt8](buffer)
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

        guard starts.count >= 2 else { return }   // need a following start code to close a NAL

        // Everything up to the last start code is complete; keep the remainder.
        for index in 0..<(starts.count - 1) {
            let begin = starts[index].offset
            let end = starts[index + 1].offset
            let nalStart = begin + starts[index].codeLength
            guard nalStart < end, nalStart < bytes.count else { continue }

            let nalType = bytes[nalStart] & 0x1F
            let isVCL = (1...5).contains(nalType)

            // A VCL NAL when we already have one closes the previous frame.
            if isVCL && currentHasVCL {
                emitAccessUnit()
            }

            currentUnit.append(contentsOf: bytes[begin..<end])
            if isVCL { currentHasVCL = true }
        }

        buffer = Data(bytes[starts[starts.count - 1].offset...])
    }

    private func emitAccessUnit() {
        defer {
            currentUnit.removeAll(keepingCapacity: true)
            currentHasVCL = false
        }
        guard !currentUnit.isEmpty else { return }

        lock.withLock {
            stats.framesIn += 1
            if stats.firstFrameAt == nil { stats.firstFrameAt = Date() }
        }

        // Input timing is not carried by a raw stream, and it does not need to be:
        // the output must be a fixed grid regardless, so the grid is the clock.
        let pts = CMTime(value: outputFrameIndex, timescale: fps)
        outputFrameIndex += 1

        try? decoder.decode(annexB: currentUnit, pts: pts)
    }

    // MARK: - Decode → encode

    private func wireDecoder() {
        decoder.onFrame = { [weak self] pixelBuffer, pts in
            guard let self else { return }

            self.lock.withLock { self.stats.framesDecoded += 1 }

            // The encoder cannot exist until the first decoded frame reveals the
            // real picture size.
            if self.encoder == nil {
                let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
                let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
                do {
                    let encoder = try H264Encoder(settings: .init(
                        width: width, height: height, fps: self.fps, bitrate: self.bitrate))
                    encoder.onEncoded = { [weak self] data, _, _ in
                        self?.writeOut(data)
                    }
                    self.encoder = encoder
                } catch {
                    Log.error("lane", "encoder unavailable: \(error)")
                    return
                }
            }

            do {
                try self.encoder?.encode(pixelBuffer, pts: pts)
            } catch {
                Log.warn("lane", "encode failed: \(error)")
            }
        }
    }

    /// Set ORAH_DUMP to a path to also capture the raw encoded elementary stream.
    /// Invaluable when the downstream muxer refuses it and will not say why.
    private lazy var dumpHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["ORAH_DUMP"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = FileHandle(forWritingAtPath: path)
        Log.info("lane", "dumping encoded stream to \(path)")
        return handle
    }()

    private func writeOut(_ data: Data) {
        try? dumpHandle?.write(contentsOf: data)
        guard let handle = outputPipe?.fileHandleForWriting else { return }
        do {
            try handle.write(contentsOf: data)
            lock.withLock {
                stats.framesEncoded += 1
                stats.bytesOut += data.count
            }
        } catch {
            Log.warn("lane", "output pipe closed")
        }
    }
}

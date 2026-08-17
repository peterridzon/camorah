import Foundation

public enum CameraError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case timeout(String)
    case unexpectedReply(String)
    case commandFailed(String)
    case badURL(String)

    public var description: String {
        switch self {
        case .notConnected: return "camera not connected"
        case .timeout(let what): return "timed out waiting for \(what)"
        case .unexpectedReply(let what): return "unexpected reply: \(what)"
        case .commandFailed(let why): return "camera rejected command: \(why)"
        case .badURL(let u): return "invalid URL: \(u)"
        }
    }
}

/// One live control connection to one Orah camera.
///
/// Each camera gets its own session with its own RTMP target. That independence
/// is deliberate: the Python implementation kept the stream URL in a module-level
/// global, so starting a second camera overwrote the first one's destination and
/// only the last URL survived. Nothing here is shared between cameras.
public actor CameraSession {

    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case streaming

        /// Holding a control session for a client that is gone.
        ///
        /// Not a failure to reach it and not a fault in it: the camera is well,
        /// and it will refuse every connection until the session it thinks is
        /// open goes away — which it never does on its own. Reconnecting cannot
        /// help, so it is worth a state of its own rather than being retried
        /// forever behind a blinking button.
        case busy

        case failed(String)
    }

    // MARK: - Identity

    public let discovered: DiscoveredCamera
    public private(set) var info: CamAPI.CameraInfo?
    public private(set) var state: State = .disconnected

    /// Stable identity used to look up the camera's slot.
    ///
    /// Taken from the Bonjour name where possible: the camera advertises itself as
    /// `Atlas360@AQ1720000102`, so the serial is known before a single byte is
    /// exchanged. Asking the camera is neither necessary nor, on this firmware,
    /// obviously safe.
    public var identityKey: String {
        if let serial = info?.serialNumber, !serial.isEmpty { return serial }
        if let parsed = Self.identityFromServiceName(discovered.serviceName) { return parsed.serial }
        return discovered.serviceName
    }

    /// Splits `Model@SERIAL` as advertised over Bonjour.
    public static func identityFromServiceName(_ name: String) -> (model: String, serial: String)? {
        let parts = name.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Internals

    private let subprotocol = "camctrl-protobuf/1.0"

    /// Timing taken from the reference tool written by an Orah engineer
    /// (`wsock.py`), which deliberately paces everything it sends:
    ///
    ///   · `time.sleep(5)` in `onOpen` before the first command
    ///   · `time.sleep(1)` after every reply before sending the next
    ///
    /// That pacing is not stylistic. Driving the camera at full speed — connecting
    /// and immediately issuing commands, back to back — wedged a real Atlas360
    /// hard enough that it stopped answering its control socket and stopped
    /// advertising over Bonjour, while its second SoC carried on streaming.
    /// It took a power cycle to recover. Respect the delays.
    private let settleAfterConnect = Duration.seconds(5)
    private let minimumCommandSpacing = Duration.seconds(1)

    private var lastCommandFinished: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?

    /// The same socket, reachable without waiting for the actor.
    ///
    /// At termination there is no time for an actor hop: AppKit returns from
    /// `applicationWillTerminate` and the process is gone. The camera would be
    /// left holding a session that nobody is on the other end of, which is the
    /// state it does not recover from on its own.
    private let liveSocket = LiveSocket()

    /// Closes the control socket now, from wherever the caller happens to be.
    public nonisolated func closeImmediately() {
        liveSocket.close()
    }
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let commandLock = AsyncLock()

    /// What a pending request will accept as its answer.
    ///
    /// The video case carries the operation because `STOP` and `START` both come
    /// back as a video reply, and matching on the message type alone hands a
    /// late `STOP` answer to a waiting `START`. That produced a fictional
    /// `unknownError` two seconds after every stop — instantly, long before a
    /// camera could have replied — and looked exactly like two broken cameras.
    /// The reply carries the operation it belongs to; it only had to be read.
    private enum ReplyKind: Sendable, Equatable {
        case video(CamAPI.VideoOp)
        case cam
        case fs
    }

    private var pending: (kind: ReplyKind, continuation: CheckedContinuation<CamAPI.Message, Error>)?

    private var onStateChange: (@Sendable (State) -> Void)?
    private var onEvent: (@Sendable (CamAPI.EventID) -> Void)?

    public init(discovered: DiscoveredCamera) {
        self.discovered = discovered
    }

    /// Where calibration lands: one directory per camera serial.
    public var calibrationDirectory: URL {
        AppPaths.support
            .appendingPathComponent("calibration", isDirectory: true)
            .appendingPathComponent(identityKey, isDirectory: true)
    }

    public func setHandlers(
        onStateChange: (@Sendable (State) -> Void)? = nil,
        onEvent: (@Sendable (CamAPI.EventID) -> Void)? = nil
    ) {
        self.onStateChange = onStateChange
        self.onEvent = onEvent
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: - Connection

    public func connect() async throws {
        // A socket left over from a connection that has already been declared
        // dead would make this return as though it had connected, and the caller
        // would never knock again. Clear it out instead of trusting it.
        var isDead: Bool {
            if case .failed = state { return true }
            return state == .disconnected
        }
        if socket != nil, isDead {
            Log.warn("cam", "\(discovered.serviceName) had a socket left over from a dead "
                     + "session — clearing it")
            disconnect()
        }
        guard socket == nil else { return }
        guard let url = discovered.controlURL else {
            throw CameraError.badURL("ws://\(discovered.host):\(discovered.port)/control")
        }

        setState(.connecting)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url, protocols: [subprotocol])

        self.session = session
        self.socket = socket
        liveSocket.set(socket)
        socket.resume()

        startReceiveLoop()
        startKeepAlive()

        setState(.connected)
        Log.info("cam", "connected to \(discovered.serviceName) (\(discovered.host))")

        // Let the camera settle before saying anything to it. See the note on
        // `settleAfterConnect`.
        try? await Task.sleep(for: settleAfterConnect)

        // Nothing is sent here on purpose. The reference tool has its
        // GET_CAMERA_INFO call commented out and opens with a file fetch instead
        // — a detail that reads like a workaround by someone who knew this
        // firmware. Identity comes from the Bonjour name, which already carries
        // the model and serial, so the camera never has to be asked.
        if let parsed = Self.identityFromServiceName(discovered.serviceName) {
            Log.info("cam", "\(discovered.serviceName) is \(parsed.model) serial \(parsed.serial)")
        }
    }

    public func disconnect() {
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        receiveTask = nil
        keepAliveTask = nil

        liveSocket.close()
        socket = nil
        session?.invalidateAndCancel()
        session = nil

        if let pending {
            pending.continuation.resume(throwing: CameraError.notConnected)
            self.pending = nil
        }

        setState(.disconnected)
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                // Matches the reference tool's autoPingInterval of 5s.
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.ping()
            }
        }
    }

    private func ping() {
        socket?.sendPing { error in
            if let error {
                Log.warn("cam", "ping failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receiving

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let socket = await self.socket else { return }
                do {
                    let message = try await socket.receive()
                    guard case .data(let payload) = message else {
                        // The camera only ever speaks binary protobuf.
                        if case .string(let text) = message {
                            Log.warn("cam", "unexpected text frame: \(text.prefix(120))")
                        }
                        continue
                    }
                    await self.handle(payload: payload)
                } catch {
                    if !Task.isCancelled {
                        await self.handleDisconnect(error)
                    }
                    return
                }
            }
        }
    }

    private func handle(payload: Data) {
        let message: CamAPI.Message
        do {
            message = try CamAPI.decode(payload)
        } catch {
            Log.warn("cam", "undecodable frame (\(payload.count) bytes): \(error)")
            return
        }

        // Unsolicited notifications are never anybody's reply.
        if case .event(let id) = message {
            Log.warn("cam", "\(discovered.serviceName) event: \(id)")
            if id == .videoFail { setState(.failed("camera reported VIDEO_FAIL")) }
            onEvent?(id)
            return
        }

        guard let waiting = pending else {
            Log.debug("cam", "reply with nobody waiting: \(message)")
            return
        }

        let matches: Bool
        switch (waiting.kind, message) {
        case (.video(let wanted), .videoReply(let op, _, _)):
            matches = op == wanted
        case (.cam, .camReply): matches = true
        case (.fs, .fsReply): matches = true
        default: matches = false
        }

        guard matches else {
            Log.debug("cam", "ignoring \(message) while awaiting \(waiting.kind)")
            return
        }

        pending = nil
        waiting.continuation.resume(returning: message)
    }

    private func handleDisconnect(_ error: Error) {
        Log.warn("cam", "\(discovered.serviceName) disconnected: \(error.localizedDescription)")

        // URLSession renders every refused upgrade as "bad response from the
        // server", which is exactly as useful as silence. This camera has a
        // limited number of control sessions and answers 503 when they are all
        // taken — the single most common reason it appears dead — so when the
        // handshake is what failed, ask it directly and say so.
        if (error as NSError).code == NSURLErrorBadServerResponse {
            Task { await self.reportRefusal() }
        }
        if let pending {
            pending.continuation.resume(throwing: CameraError.notConnected)
            self.pending = nil
        }
        // Without this the keep-alive goes on pinging a socket that is gone, and
        // reconnecting later would leave two of them running.
        keepAliveTask?.cancel()
        keepAliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        liveSocket.set(nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        setState(.disconnected)
    }

    /// Repeats the upgrade by hand, purely to read the status code.
    ///
    /// A plain GET carrying the WebSocket headers gets the same answer the real
    /// handshake got, and URLSession hands back the status instead of hiding it.
    /// It never reaches 101 here — if the camera were free, the real connection
    /// would have worked — so this cannot cost a session slot.
    private func reportRefusal() async {
        guard let url = URL(string: "http://\(discovered.host):\(discovered.port)/control") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue("camctrl-protobuf/1.0", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
                         forHTTPHeaderField: "Sec-WebSocket-Key")

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }

        switch http.statusCode {
        case 503:
            setState(.busy)
            Log.error("cam", "\(discovered.serviceName) is busy: it already has a control session open (HTTP 503). It will not accept another until that one is closed, or the camera is power cycled.")
        default:
            Log.warn("cam", "\(discovered.serviceName) refused the control connection with HTTP \(http.statusCode)")
        }
    }

    // MARK: - Request / response

    private func send(_ payload: Data, expecting kind: ReplyKind, timeout: Duration = .seconds(10)) async throws -> CamAPI.Message {
        try await commandLock.withLock {
            guard let socket else { throw CameraError.notConnected }

            // Never send two commands back to back.
            if let last = lastCommandFinished {
                let since = clock.now - last
                if since < minimumCommandSpacing {
                    try? await Task.sleep(for: minimumCommandSpacing - since)
                }
            }
            defer { lastCommandFinished = clock.now }

            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.failPending(kind: kind)
            }
            defer { timeoutTask.cancel() }

            return try await withCheckedThrowingContinuation { continuation in
                pending = (kind, continuation)
                socket.send(.data(payload)) { error in
                    if let error {
                        Task { self.failPending(kind: kind, error: error) }
                    }
                }
            }
        }
    }

    private func failPending(kind: ReplyKind, error: Error? = nil) {
        guard let waiting = pending, waiting.kind == kind else { return }
        pending = nil
        waiting.continuation.resume(
            throwing: error ?? CameraError.timeout("\(kind) reply"))
    }

    // MARK: - Commands

    public func requestCameraInfo() async throws -> CamAPI.CameraInfo {
        let reply = try await send(CamAPI.getCameraInfo(), expecting: .cam)
        guard case .camReply(let ret, let info, _, _, _) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        guard ret == .success, let info else {
            throw CameraError.commandFailed("GET_CAMERA_INFO returned \(ret)")
        }
        return info
    }

    /// Asks the camera to reboot.
    ///
    /// Deliberately does not wait for an answer: a camera that is rebooting has
    /// nothing to say, and the connection goes with it. Success is the camera
    /// disappearing and coming back.
    public func restart() async throws {
        guard let socket else { throw CameraError.notConnected }
        Log.warn("cam", "\(discovered.serviceName) — asking it to restart")
        try await socket.send(.data(CamAPI.restartCamera()))
    }

    public func requestCameraMode() async throws -> CamAPI.CameraMode {
        let reply = try await send(CamAPI.getCameraMode(), expecting: .cam)
        guard case .camReply(let ret, _, let mode, _, _) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        guard ret == .success else {
            throw CameraError.commandFailed("GET_CAMERA_MODE returned \(ret)")
        }
        return mode ?? .unknown
    }

    /// Starts streaming to `rtmpBase`, which must end in a slash — the camera
    /// appends `0_0`, `0_1`, `1_0`, `1_1` to it.
    ///
    /// Pass `rtmp://<mac-lan-ip>:1935/cam07/` and the camera publishes
    /// `cam07/0_0` … `cam07/1_1`, which is exactly what MediaMTX and the recording
    /// agents expect. The original code passed a base with no per-camera path, so
    /// every camera published to the same four names and the recorders, watching
    /// `camNN/...`, captured nothing.
    /// STOP that never throws — for clearing state between attempts.
    public func stopStreamingIgnoringErrors() async throws -> String {
        guard let reply = try? await send(CamAPI.stopVideo(), expecting: .video(.stop), timeout: .seconds(10)),
              case .videoReply(_, let ret, _) = reply else { return "no reply" }
        return "\(ret)"
    }

    /// Called with each step of the start sequence, as it happens.
    ///
    /// Starting a camera is not one command, it is five, and it takes the better
    /// part of half a minute. A bar that only counts seconds looks the same
    /// whether the sequence is working or hung — and after twenty seconds it
    /// says "still waiting", which reads as failure while everything is fine.
    public func setStepHandler(_ handler: (@Sendable (String) -> Void)?) {
        onStep = handler
    }

    private var onStep: (@Sendable (String) -> Void)?

    private func step(_ text: String) {
        onStep?(text)
    }

    /// Returns whether the camera acknowledged the START.
    ///
    /// The return code is not proof that it started — only pictures are. But it
    /// is a good predictor of whether it ever will, and the caller needs that to
    /// decide whether asking again is worth anything. See `retryIsPointless`.
    @discardableResult
    public func startStreaming(rtmpBase: String) async throws -> Bool {
        let base = rtmpBase.hasSuffix("/") ? rtmpBase : rtmpBase + "/"

        // Mirror of the reference tool's start sequence, which is the only one
        // known to be exercised against this firmware from the factory:
        //
        //     getFile(factoryPresetsProject.ptv) → getFile(rigParameters.json)
        //         → START → AUDIO_SYNC
        //
        // Both files are genuinely downloaded, not merely requested — the
        // reference fetches the returned URL over HTTP before moving on. Whether
        // the camera depends on that or it is incidental is unknown, so it is
        // reproduced rather than trimmed. Failures are logged, never fatal.
        step("reading its calibration")
        await fetchCalibration(into: calibrationDirectory)

        // Stop before starting.
        //
        // The camera resumes streaming to its last destination on its own after
        // a power cut, so by the time anyone asks it to start it may already be
        // running — and START on a camera that is already live comes back
        // UNKNOWN_ERROR, which reads as a broken camera and is not one. The
        // reference tool never needed this because it only ever met a camera
        // that had just been switched on. NO_VIDEO_RUNNING here is the good
        // case, not a failure.
        step("stopping whatever it was doing")
        if let stop = try? await send(CamAPI.stopVideo(), expecting: .video(.stop), timeout: .seconds(10)),
           case .videoReply(_, let stopRet, _) = stop {
            Log.info("cam", "\(discovered.serviceName) STOP first: \(stopRet)")
            try? await Task.sleep(for: .seconds(2))
        }

        // Then START, once.
        //
        // The reference tool has a bug that turns out to be the whole story. It
        // reads the reply as:
        //
        //     if api.video_reply.op == Video.Reply.RetCode.Value('SUCCESS')
        //
        // comparing the *operation code* against a *return code*. START is 1 and
        // SUCCESS is 1, so every reply to a START looks like success to it,
        // whatever the camera actually said. It therefore never retries: it
        // sends START once, calls it started, and moves on to AUDIO_SYNC.
        //
        // Which means UNKNOWN_ERROR from START has never stopped anybody — the
        // camera may still bring the streams up a moment later, and the only
        // honest way to know whether it started is to watch for the streams
        // arriving, not to believe the return code.
        //
        // Retrying is actively harmful. Eight STARTs in sixteen seconds put a
        // camera into a state where even a file fetch that had just worked came
        // back UNKNOWN_ERROR (MEASUREMENTS M8). So: ask once, say what came
        // back, and carry on.
        step("asking it to start")
        let reply = try await send(CamAPI.startVideo(url: base),
                                   expecting: .video(.start), timeout: .seconds(30))
        guard case .videoReply(_, let ret, _) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        if ret != .success {
            Log.warn("cam", "\(discovered.serviceName) START answered \(ret) — carrying on anyway, as the reference tool does; whether it worked is decided by the streams arriving")
        }

        setState(.streaming)
        step("started — waiting for pictures")
        Log.info("cam", "\(discovered.serviceName) streaming to \(base)")

        // Audio sync pulses; firmware accepts this only right after start.
        do {
            let syncReply = try await send(CamAPI.audioSync(), expecting: .cam)
            if case .camReply(let syncRet, _, _, _, _) = syncReply, syncRet != .success {
                Log.warn("cam", "AUDIO_SYNC returned \(syncRet)")
            }
        } catch {
            // Non-fatal: the video is already up, only A/V alignment is affected.
            Log.warn("cam", "AUDIO_SYNC failed: \(error)")
        }

        return ret == .success
    }

    /// Measured on 2026-08-16 across sixteen cameras (MEASUREMENTS M10).
    ///
    /// A START answered `UNKNOWN_ERROR` never once produced pictures, on any
    /// camera, on any attempt. Camera 3 was asked three times, thirty seconds
    /// apart, and answered `UNKNOWN_ERROR` every time; a power cycle made the
    /// very next START succeed outright. Camera 11 did the same and got worse
    /// with each ask — by the second attempt even a file fetch that had worked a
    /// minute earlier came back `UNKNOWN_ERROR`, which is the degraded state
    /// M8 describes.
    ///
    /// Every camera that ever streamed answered `SUCCESS` to its first START.
    ///
    /// So `UNKNOWN_ERROR` is not "try again", it is "this one needs its power
    /// pulled" — and asking again spends two minutes making it less likely to
    /// work. It is still not a reason to declare failure on the spot: the
    /// reference tool never reads this code and cameras do sometimes come up
    /// anyway. Wait for the pictures; just do not ask twice.
    public static let retryIsPointless = "START answered UNKNOWN_ERROR"

    public func stopStreaming() async throws {
        let reply = try await send(CamAPI.stopVideo(), expecting: .video(.stop))
        guard case .videoReply(_, let ret, _) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        // NO_VIDEO_RUNNING just means it already stopped — that's success for us.
        guard ret == .success || ret == .noVideoRunning else {
            throw CameraError.commandFailed("STOP returned \(ret)")
        }
        setState(.connected)
        Log.info("cam", "\(discovered.serviceName) stopped streaming")
    }

    // MARK: - Read-only inspection
    //
    // Everything below only asks questions. No command here carries a payload that
    // would change camera state — see the notes on `CamAPI.getAudioGain` and
    // `CamAPI.getCameraTime` for why an empty request is a read.

    /// Where the camera believes it is publishing right now.
    public func requestStreamURLs() async throws -> [String] {
        let reply = try await send(CamAPI.getStreamURL(), expecting: .video(.getStreamURL))
        guard case .videoReply(_, let ret, let urls) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        guard ret == .success || ret == .noVideoRunning else {
            throw CameraError.commandFailed("GET_STREAM_URL returned \(ret)")
        }
        return urls
    }

    /// Current audio gain per channel, in dB. The count reveals the channel layout.
    public func requestAudioGains() async throws -> [Float] {
        let reply = try await send(CamAPI.getAudioGain(), expecting: .cam)
        guard case .camReply(let ret, _, _, _, let gains) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        guard ret == .success else {
            throw CameraError.commandFailed("AUDIO_GAIN returned \(ret)")
        }
        return gains
    }

    /// The camera's own clock, as UNIX time.
    public func requestCameraTime() async throws -> UInt64 {
        let reply = try await send(CamAPI.getCameraTime(), expecting: .cam)
        guard case .camReply(let ret, _, _, let time, _) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        guard ret == .success, let time else {
            throw CameraError.commandFailed("CAMERA_TIME returned \(ret)")
        }
        return time
    }

    /// Asks whether a file exists, without downloading it.
    /// Returns its URL, or nil when the camera reports it missing.
    public func locateFile(_ name: String) async throws -> String? {
        let reply = try await send(CamAPI.getFile(name), expecting: .fs)
        guard case .fsReply(let ret, let url) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        return ret == .success ? url : nil
    }

    /// Downloads a file the camera exposes (calibration data) into `directory`.
    /// Returns the local file URL.
    @discardableResult
    public func fetchFile(_ name: String, into directory: URL) async throws -> URL {
        let reply = try await send(CamAPI.getFile(name), expecting: .fs)
        guard case .fsReply(let ret, let urlString) = reply else {
            throw CameraError.unexpectedReply("\(reply)")
        }
        guard ret == .success, let urlString, let remote = URL(string: urlString) else {
            throw CameraError.commandFailed("GET \(name) returned \(ret)")
        }

        let (data, _) = try await URLSession.shared.data(from: remote)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        let destination = directory.appendingPathComponent("\(stamp)_\(name)")
        try data.write(to: destination, options: .atomic)

        Log.info("cam", "saved \(name) → \(destination.lastPathComponent)")
        return destination
    }

    /// Pulls both calibration artefacts. Failures are logged, not thrown — missing
    /// calibration must never stop a show from going live.
    public func fetchCalibration(into directory: URL) async {
        for file in [CamAPI.factoryCalibrationFile, CamAPI.rigParametersFile] {
            do {
                try await fetchFile(file, into: directory)
            } catch {
                Log.warn("cam", "could not fetch \(file): \(error)")
            }
        }
    }
}

extension ISO8601DateFormatter {
    static let filenameSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return f
    }()
}


/// Holds the live control socket outside the actor, so it can be closed from a
/// termination handler that has no time to await anything.
private final class LiveSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    func set(_ task: URLSessionWebSocketTask?) {
        lock.withLock { self.task = task }
    }

    func close() {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel(with: .goingAway, reason: nil)
    }
}

import Foundation
import Observation
import CoreVideo
import OrahKit

/// Everything the interface reads, and the only thing that talks to OrahKit.
///
/// Views observe this and nothing else; discovery, camera sessions and the
/// switcher all live behind it. That keeps the async, off-main-thread parts —
/// Bonjour callbacks, WebSocket replies, decoder callbacks — from leaking into
/// SwiftUI, where they would have to be hopped onto the main actor at every call
/// site instead of once, here.
@Observable
@MainActor
final class AppModel {

    // MARK: - Cameras

    struct Camera: Identifiable, Equatable {
        let serial: String
        let serviceName: String
        var host: String
        /// The MAC of the first SoC, learned from the ARP table.
        ///
        /// The address is a lease and moves; this does not. It is what tells a
        /// camera that came back on a new address from a different camera that
        /// took the old one — the two look identical from the port alone.
        var mac: String = ""
        var port: Int
        var slot: Int
        var label: String
        var state: CameraSession.State = .disconnected
        var lensesArriving: Int = 0
        var delayMilliseconds: Double = 0

        var id: String { serial }
        var name: String { label.isEmpty ? String(format: "cam%02d", slot) : label }
        var isStreaming: Bool { state == .streaming }
    }

    private(set) var cameras: [Camera] = []
    var programSlot: Int?
    var previewSlot: Int?

    /// 0 = programme, 1 = preview. Driven by Take, the T-bar, or a MIDI fader.
    var mix: Double = 0
    var transitionMilliseconds: Double = 600
    var transitionIsCut = false

    /// Which lens the multiview is showing. All cameras show the same one.
    var multiviewLens = 0

    // MARK: - Nodes

    struct Node: Identifiable, Equatable {
        let id: Int
        var host: String
        var online = false
        var streamsArriving = 0
        var streamsExpected = 0
        var secondsRemaining: Int?
        var writeBytesPerSecond: Int = 0
        var cpuPercent: Double?
        var loadPerCore: Double?
        var proxyEncoder: String?
        var cameras: [Int] = []
    }

    private(set) var nodes: [Node] = []

    // MARK: - Hardware Bonjour will not admit to

    struct UnannouncedCamera: Identifiable, Equatable, Sendable {
        let host: String
        let mac: String
        var controlAnswers = false
        var id: String { mac }
    }

    /// Orah hardware found on the wire that is not announcing itself.
    ///
    /// Bonjour is multicast, and multicast between a wireless client and wired
    /// devices is exactly what consumer access points rate-limit or drop. Seen
    /// here: three cameras on the network, all three answering on port 9989,
    /// one of them advertised. The MAC prefix is Orah's own and lives at the
    /// link layer, where none of that applies.
    private(set) var unannounced: [UnannouncedCamera] = []

    // MARK: - The rig

    /// Which cameras this event expects. Empty until seeded or built.
    var roster = RosterStore.load() {
        didSet { RosterStore.save(roster) }
    }

    /// Positions somebody is physically working on. Nothing is sent to these:
    /// a camera being recabled should not also be fighting the desk, and a
    /// control session opened while someone unplugs it is one the camera keeps.
    private(set) var fixingSince: [Int: Date] = [:]

    /// Which of the three screens is up.
    ///
    /// Three modes rather than a flag, because there are now three: cutting a
    /// show, checking a rig, and shading cameras. A second boolean would have
    /// made "both true" representable, and it never is.
    enum Screen: String, Sendable { case desk, rigCheck, colour }
    var screen: Screen = .desk

    var showsRigCheck: Bool { screen == .rigCheck }

    /// Logged so a click that does nothing can be told from a view that does not
    /// redraw — the two look identical from the outside.
    func setScreen(_ screen: Screen) {
        self.screen = screen
        Log.info("ui", "switched to \(screen.rawValue)")
    }

    func setRigCheck(_ on: Bool) { setScreen(on ? .rigCheck : .desk) }

    func toggleFixing(_ number: Int) {
        if fixingSince[number] == nil {
            fixingSince[number] = Date()
            Log.info("rig", "camera \(number) marked as being worked on — leaving it alone")
        } else {
            fixingSince[number] = nil
            Log.info("rig", "camera \(number) released — checking it again from the top")
        }
    }

    /// Binds a camera to a number and remembers it for next time.
    func install(serial: String, at number: Int) {
        roster.install(serial: serial, at: number)
        Log.info("rig", "\(serial) installed as camera \(number)")
    }

    /// Builds the roster from the records `orahctl checkout` wrote.
    ///
    /// Where those are cannot be worked out from inside the app: launched from
    /// Finder its working directory is `/`, while the command line tool runs
    /// from the repository. So it looks in the remembered place, then asks.
    func seedRosterFromRecords(from directory: URL? = nil) {
        let candidates: [URL] = [
            directory,
            configuration.cameraRecordsPath.isEmpty
                ? nil : URL(fileURLWithPath: configuration.cameraRecordsPath),
            RosterStore.url.deletingLastPathComponent()
                .appendingPathComponent("camera-records", isDirectory: true),
        ].compactMap { $0 }

        for candidate in candidates {
            let seeded = RosterStore.seedFromRecords(at: candidate)
            guard !seeded.entries.isEmpty else { continue }

            roster = seeded
            configuration.cameraRecordsPath = candidate.path
            ConfigStore.shared.config = configuration
            Log.info("rig", "roster seeded with \(seeded.entries.count) cameras from \(candidate.path)")
            lastError = nil
            return
        }

        needsRecordsFolder = true
    }

    /// Set when the records folder has to be pointed at by hand.
    var needsRecordsFolder = false

    /// Everything on the network that the roster does not account for.
    var unassignedCameras: [(serial: String, host: String)] {
        let claimed = Set(roster.entries.compactMap(\.serial))
        var out = cameras.filter { !claimed.contains($0.serial) }
            .map { (serial: $0.serial, host: $0.host) }
        // Hardware that never announced itself has no serial to go by yet.
        out += unannounced.map { (serial: "unknown at \($0.host)", host: $0.host) }
        return out
    }

    /// The roster, evaluated against what is actually out there.
    var rig: (positions: [RigPosition], summary: RigSummary) {
        var observations: [Int: RigEvaluator.Observation] = [:]

        for entry in roster.entries {
            var seen = RigEvaluator.Observation()
            seen.serial = entry.serial

            if let fixing = fixingSince[entry.number] {
                seen.beingFixedSecondsAgo = Int(Date().timeIntervalSince(fixing))
            }

            if let serial = entry.serial,
               let camera = cameras.first(where: { $0.serial == serial }) {
                seen.lockedOut = camera.state == .busy
                seen.host = camera.host
                seen.onNetwork = camera.state != .disconnected
                seen.controlConnected = camera.state == .connected || camera.state == .streaming
                seen.lensesArriving = camera.lensesArriving
                if let started = startRequestedAt[camera.slot] {
                    seen.startRequestedSecondsAgo = Int(Date().timeIntervalSince(started))
                }
            } else if unannounced.contains(where: { $0.host == entry.position }) {
                // Kept for rosters that carry an address rather than a serial.
                seen.onNetwork = true
            }

            observations[entry.number] = seen
        }

        return RigEvaluator.evaluate(roster: roster, observations: observations)
    }

    // MARK: - Status

    private(set) var isRecording = false
    private(set) var recordingStarted: Date?
    private(set) var log: [Log.Entry] = []
    var lastError: String?

    /// Spread between the earliest and latest camera, in milliseconds. Grows
    /// through a show as the cameras' crystals drift apart, which is why it is
    /// on screen rather than in a settings panel.
    private(set) var spreadMilliseconds: Double = 0

    // MARK: - Machinery

    private let discovery = CameraDiscovery()
    private var sessions: [String: CameraSession] = [:]
    private var pollTask: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?

    // MARK: - The desk

    /// Frames reach the two monitors through these, not through the view tree.
    let programSink = VideoSink()
    let previewSink = VideoSink()

    /// One per output lane, for the window that shows what goes to the stitcher.
    let outputSinks = (0..<4).map { _ in VideoSink() }

    private(set) var programHasPicture = false
    private(set) var previewHasPicture = false

    /// Which lens each monitor is showing, so it can be turned the right way:
    /// the camera's two boards face opposite ways and their pictures arrive
    /// upside down relative to each other.
    private(set) var programLens = 0
    private(set) var previewLens = 0

    private let lensTracker = LensTracker()

    final class LensTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var program = -1
        private var preview = -1

        func changed(program: Int, preview: Int) -> Bool {
            lock.withLock {
                guard program != self.program || preview != self.preview else { return false }
                self.program = program
                self.preview = preview
                return true
            }
        }
    }

    private var server: MediaMTXServer?
    private var switcher: Switcher?
    private var outputsStarted = false

    /// Only the cameras on the desk are decoded. Everything else on screen comes
    /// from the nodes' proxies, which is the whole reason twenty-four cameras fit
    /// on one Mac.
    private var deskSources: [Int: CameraSource] = [:]

    /// How many cameras to keep decoded at once.
    ///
    /// Four is two hardware decodes for the desk and two spare, which an M1 Pro
    /// does without noticing. Past that the multiview is meant to run on the
    /// nodes' proxies, which is the whole reason the nodes exist.
    var deskDecodeBudget = 4

    /// When Start was pressed, so the wait can be shown as a wait rather than as
    /// nothing happening.
    private var startRequestedAt: [Int: Date] = [:]

    /// What each camera is doing right now, in words, during its start sequence.
    private(set) var startStep: [Int: String] = [:]

    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var reconnectDelay: [String: Int] = [:]
    private var connectedAt: [String: Date] = [:]

    /// How many presence checks in a row a camera has failed. Two makes it show
    /// as off the network, five takes it off the list; any answer resets it.
    ///
    /// A count rather than a stopwatch because the check runs on a fixed clock
    /// and one lost packet should not evict a working camera.
    private var missedPresence: [String: Int] = [:]

    /// Addresses worth asking about even when no camera is there any more.
    ///
    /// A camera that reboots comes back on the same address within seconds. If
    /// the only way to notice were the subnet sweep, it would sit missing for
    /// half a minute for no reason.
    private var watchedHosts: Set<String> = []

    private var presenceTask: Task<Void, Never>?
    private var lastSweep = Date.distantPast

    /// The most lenses each camera has been seen delivering this session.
    private var streamProven: [Int: Int] = [:]

    /// Where the camera records live, once it is known.
    private var recordsDirectory: URL {
        configuration.cameraRecordsPath.isEmpty
            ? RosterStore.url.deletingLastPathComponent()
                .appendingPathComponent("camera-records", isDirectory: true)
            : URL(fileURLWithPath: configuration.cameraRecordsPath)
    }

    /// The address the cameras were last told to publish to.
    private var announcedAddress: String?

    /// Consecutive `VIDEO_FAIL` events per camera, cleared once it streams.
    private var videoFailures: [Int: Int] = [:]

    var configuration = ConfigStore.shared.config

    /// Nonisolated: it only installs a log sink and touches no isolated state,
    /// which lets the App struct create it as plain `@State`.
    nonisolated init() {
        Log.observer = { entry in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.append(entry)
                if self.log.count > 500 { self.log.removeFirst(self.log.count - 500) }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        startDesk()
        discovery.start { event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        startPolling()
        Log.info("app", "\(AppPaths.name) started")
    }

    func stop() {
        discovery.stop()
        pollTask?.cancel()
        housekeepingTask?.cancel()
        presenceTask?.cancel()
        transitionTask?.cancel()
        for task in reconnectTasks.values { task.cancel() }
        reconnectTasks.removeAll()
        for source in deskSources.values { source.stop() }
        deskSources.removeAll()
        switcher?.stop()
        switcher = nil
        server?.stop()
        server = nil
        for session in sessions.values {
            // Synchronously first: at termination the Task below may never get
            // to run, and a camera left holding an open session is the one
            // failure that needs a power cycle to clear.
            session.closeImmediately()
            Task { await session.disconnect() }
        }
    }

    /// Brings up the RTMP server and the switcher.
    ///
    /// Both are started whether or not there are nodes: the desk is this Mac's
    /// work either way, and with no node the cameras publish here instead, which
    /// is exactly the case on the bench.
    private func startDesk() {
        do {
            let server = MediaMTXServer(rtmpPort: configuration.rtmpPort,
                                        apiPort: configuration.apiPort,
                                        binaryPath: configuration.mediaMTXBinary)
            try server.start()
            self.server = server
        } catch {
            lastError = "\(error)"
            Log.error("app", "\(error)")
            return
        }

        do {
            let switcher = try Switcher()
            let flags = PictureFlags()
            switcher.onMonitorFrame = { [weak self] program, programLens, preview, previewLens in
                guard let self else { return }
                self.programSink.push(program)
                self.previewSink.push(preview)
                // The booleans only drive the NO SIGNAL overlay, so they are
                // written when they change rather than thirty times a second.
                self.monitorFrames.record(program: program != nil, preview: preview != nil)
                if flags.changed(program: program != nil, preview: preview != nil) {
                    Task { @MainActor [weak self] in
                        self?.programHasPicture = program != nil
                        self?.previewHasPicture = preview != nil
                    }
                }
                // Which lens is on screen decides how far it has to be turned.
                if self.lensTracker.changed(program: programLens, preview: previewLens) {
                    Task { @MainActor [weak self] in
                        self?.programLens = programLens
                        self?.previewLens = previewLens
                    }
                }
            }
            switcher.onOutputFrames = { [weak self] frames in
                guard let self else { return }
                for (index, frame) in frames.enumerated() where index < self.outputSinks.count {
                    self.outputSinks[index].push(frame)
                }
            }
            switcher.onInspectCameras = { [weak self] pictures in
                guard let self else { return }
                for (slot, picture) in pictures { self.cameraSink(slot: slot).push(picture) }
            }
            switcher.onInspectFrames = { [weak self] pictures in
                guard let self else { return }
                for (lens, picture) in pictures.enumerated() where lens < self.inspectSinks.count {
                    self.inspectSinks[lens].push(picture)
                }
            }
            switcher.start()
            self.switcher = switcher
            restoreGrades()
        } catch {
            lastError = "Switcher: \(error)"
            Log.error("app", "switcher: \(error)")
        }
    }

    /// Counts what the monitors are actually being given, so a black screen can
    /// be told apart from a screen with nothing to show.
    let monitorFrames = MonitorFrameCount()

    final class MonitorFrameCount: @unchecked Sendable {
        private let lock = NSLock()
        private var program = 0
        private var preview = 0

        func record(program: Bool, preview: Bool) {
            lock.withLock {
                if program { self.program += 1 }
                if preview { self.preview += 1 }
            }
        }

        var counts: (program: Int, preview: Int) {
            lock.withLock { (program, preview) }
        }
    }

    /// Tracks the last state pushed to the interface, from the pump's thread.
    private final class PictureFlags: @unchecked Sendable {
        private let lock = NSLock()
        private var program = false
        private var preview = false

        func changed(program: Bool, preview: Bool) -> Bool {
            lock.withLock {
                guard program != self.program || preview != self.preview else { return false }
                self.program = program
                self.preview = preview
                return true
            }
        }
    }

    private func handle(_ event: CameraDiscovery.Event) {
        switch event {
        case .found(let found):
            adopt(found)
        case .lost(let serviceName):
            // Bonjour saying a camera is gone is worth acting on, but it saying
            // nothing means nothing: an unplugged camera cannot announce its
            // departure. `dropCamerasThatWentAway` is what actually decides.
            if let index = cameras.firstIndex(where: { $0.serviceName == serviceName }) {
                cameras[index].state = .disconnected
                cameras[index].lensesArriving = 0
            }
        case .browserFailed(let message):
            lastError = "Discovery failed: \(message)"
        }
    }

    /// Slot numbers come from the serial, never from the order cameras appear.
    ///
    /// Discovery order changes between runs; binding the slot to the hardware is
    /// what keeps cam01 the same camera tomorrow, so recordings and scenes still
    /// line up with what they lined up with yesterday.
    private func adopt(_ found: DiscoveredCamera) {
        let identity = CameraSession.identityFromServiceName(found.serviceName)
        let serial = identity?.serial ?? found.serviceName

        if let index = cameras.firstIndex(where: { $0.serial == serial }) {
            cameras[index].host = found.host
            cameras[index].port = found.port
            watchedHosts.insert(found.host)
            missedPresence[serial] = 0
            connect(cameras[index])
            return
        }

        // The roster decides the number, when it knows this camera.
        //
        // Otherwise there are two numberings for one fleet: the roster's, taken
        // from the number painted on the case, and the app's own, handed out in
        // the order cameras happened to be discovered. They disagreed — the same
        // unit was camera 3 on the desk and camera 7 in the rig check — and the
        // RTMP path is built from this number, so the recordings would have
        // carried the wrong one too.
        let slot: Int
        if let fromRoster = roster.entry(forSerial: serial)?.number {
            slot = fromRoster
            _ = ConfigStore.shared.mutate { config in config.cameraSlots[serial] = fromRoster }
        } else {
            slot = ConfigStore.shared.mutate { config -> Int in
                if let existing = config.cameraSlots[serial] { return existing }
                // Never take a number the roster has reserved for somebody else.
                let used = Set(config.cameraSlots.values)
                    .union(roster.entries.map(\.number))
                let next = (1...99).first { !used.contains($0) } ?? (used.count + 1)
                config.cameraSlots[serial] = next
                return next
            }
        }

        let camera = Camera(
            serial: serial,
            serviceName: found.serviceName,
            host: found.host,
            port: found.port,
            slot: slot,
            label: ConfigStore.shared.config.cameraLabels[String(slot)] ?? "")

        cameras.append(camera)
        // Kept even after this camera leaves, so a reboot is noticed by the
        // presence check rather than waiting for the next subnet sweep.
        watchedHosts.insert(found.host)
        missedPresence[serial] = 0
        cameras.sort { $0.slot < $1.slot }
        Log.info("app", "camera \(serial) is slot \(slot)")

        connect(camera)
        // The first camera to appear takes both buses; the second one moves off
        // programme onto preview, so the desk is ready to cut the moment there is
        // something to cut to.
        if programSlot == nil { programSlot = slot }
        if previewSlot == nil || previewSlot == programSlot { previewSlot = slot }
        syncDesk()
    }

    private func connect(_ camera: Camera) {
        guard sessions[camera.serial] == nil else { return }

        let discovered = DiscoveredCamera(serviceName: camera.serviceName,
                                          host: camera.host, port: camera.port)
        let session = CameraSession(discovered: discovered)
        sessions[camera.serial] = session

        Task {
            await session.setHandlers(
                onStateChange: { state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.update(camera.serial) { $0.state = state }
                        if state == .streaming { self.videoFailures[camera.slot] = nil }
                        switch state {
                        case .connected, .streaming:
                            if self.connectedAt[camera.serial] == nil {
                                self.connectedAt[camera.serial] = Date()
                            }
                        case .busy:
                            // Knocking again cannot free the session. Stop, and
                            // say what will: unplugging it.
                            self.reconnectTasks[camera.serial]?.cancel()
                            self.reconnectTasks[camera.serial] = nil
                            self.lastError = "Camera \(camera.slot) is locked — power cycle it"
                        case .disconnected, .failed:
                            self.noteDisconnect(serial: camera.serial)
                            self.scheduleReconnect(serial: camera.serial, slot: camera.slot)
                        case .connecting:
                            break
                        }
                        // A camera that has just come up may be programme or
                        // preview already — it was selected before it had
                        // anything to send.
                        self.syncDesk()
                    }
                },
                onEvent: { event in
                    Task { @MainActor [weak self] in
                        guard event == .videoFail else { return }
                        self?.retryAfterVideoFail(slot: camera.slot)
                    }
                })
            do {
                try await session.connect()
                await self.checkRememberedTarget(session, slot: camera.slot)
            } catch {
                await MainActor.run { self.lastError = "Camera \(camera.slot): \(error)" }
            }
        }
    }

    /// Brings a camera back after its control connection drops.
    ///
    /// A camera closes the connection while it is still booting, and one that has
    /// been up for hours will drop eventually too. Without this the app simply
    /// stops being able to talk to it, and Start does nothing with no explanation.
    ///
    /// The backoff matters as much as the reconnect. Hammering the control port
    /// is what leaves these cameras refusing every command until they are power
    /// cycled (MEASUREMENTS M5), so each failure waits longer than the last, up
    /// to half a minute.
    /// Decides whether the last connection counts as having worked.
    ///
    /// Resetting the backoff the moment a socket opens is worse than having no
    /// backoff at all: a camera that accepts a connection and drops it a second
    /// later then gets retried every five seconds for ever, which is the precise
    /// pattern that leaves these cameras refusing every command. A connection has
    /// to survive long enough to have been useful before it earns a fast retry.
    private func noteDisconnect(serial: String) {
        let lasted = connectedAt[serial].map { Date().timeIntervalSince($0) } ?? 0
        connectedAt[serial] = nil
        if lasted >= 15 { reconnectDelay[serial] = nil }
    }

    private func scheduleReconnect(serial: String, slot: Int) {
        guard reconnectTasks[serial] == nil, sessions[serial] != nil else { return }

        let delay = min((reconnectDelay[serial] ?? 0) + 5, 30)
        reconnectDelay[serial] = delay
        Log.info("cam", "cam\(slot) dropped — reconnecting in \(delay)s")

        reconnectTasks[serial] = Task { @MainActor [weak self] in
            // `try?` here was the whole flicker. Cancelling a sleeping task
            // makes `Task.sleep` throw, and swallowing that throw turns "do not
            // reconnect" into "reconnect right now". A camera that answers 503
            // drops, schedules a reconnect, then reports `.busy` — which cancels
            // that reconnect — which fired it instantly instead, producing
            // another 503. Hundreds of control attempts a second at a camera
            // that is already refusing them, and a status that never settles.
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.reconnectTasks[serial] = nil
            guard let session = self.sessions[serial] else { return }
            do {
                try await session.connect()
            } catch {
                Log.warn("cam", "cam\(slot) reconnect failed: \(error)")
                self.scheduleReconnect(serial: serial, slot: slot)
            }
        }
    }

    /// Re-aims every running camera when this Mac's address changes.
    ///
    /// During an install this is not an edge case, it is Tuesday: a different
    /// network, a new lease, a switch to the 5 GHz side. The cameras keep
    /// publishing to the address they were given, which now belongs to nobody,
    /// and all they report is `VIDEO_FAIL` — indistinguishable from a fault.
    ///
    /// The fix has to be automatic, because the symptom points nowhere near the
    /// cause. Only cameras this app started are re-aimed; anything else is left
    /// alone, as always.
    private func checkOwnAddress() {
        guard let current = NetworkInterface.primaryIPv4() else { return }
        defer { announcedAddress = current }

        guard let previous = announcedAddress, previous != current else { return }

        let running = cameras.filter { startRequestedAt[$0.slot] != nil }
        Log.warn("app", "this Mac moved from \(previous) to \(current) — "
                 + "re-aiming \(running.count) camera\(running.count == 1 ? "" : "s")")

        for camera in running {
            videoFailures[camera.slot] = nil
            startCamera(camera.slot, reason: "this Mac moved from \(previous) to \(current)")
        }

        if running.isEmpty {
            lastError = "This Mac is now \(current) — press Start to send the cameras here"
        }
    }

    /// Says so when a camera is aimed somewhere that no longer exists.
    ///
    /// A camera keeps streaming to the last address it was given, across power
    /// cuts and across events. When this Mac changes address — a different
    /// network, a new lease — every camera is suddenly publishing into nothing,
    /// and all it reports for itself is `VIDEO_FAIL`. Which reads as a broken
    /// camera and is a stale address.
    private func checkRememberedTarget(_ session: CameraSession, slot: Int) async {
        guard let urls = try? await session.requestStreamURLs(), let first = urls.first,
              let remembered = URL(string: first)
        else { return }

        let wanted = URL(string: rtmpBase(forSlot: slot))
        guard let wanted else { return }

        // The host is not enough. Camera 3 arrived publishing happily to
        // `rtmp://192.168.0.251:1935/cam01/` — our address, and a number it had
        // been given under an older roster. Comparing hosts alone said "aimed at
        // us, nothing to report", while the desk read `cam03` and saw an empty
        // path. A camera streaming into the wrong slot is invisible in exactly
        // the same way as one that is not streaming at all, and it is a
        // different problem, so it has to be a different sentence.
        let sameHost = remembered.host == wanted.host
        let slotOf: (URL) -> String = { url in
            url.path.split(separator: "/").first.map(String.init) ?? ""
        }
        let sameSlot = slotOf(remembered) == slotOf(wanted)
        guard !sameHost || !sameSlot else { return }

        await MainActor.run {
            if sameHost {
                Log.warn("cam", "cam\(slot) is publishing to \(slotOf(remembered)) — this app "
                         + "reads \(slotOf(wanted)). Press Start to move it.")
                self.lastError = "Camera \(slot) is streaming into \(slotOf(remembered)), "
                    + "not \(slotOf(wanted)) — press Start"
            } else {
                let host = remembered.host ?? "?"
                Log.warn("cam", "cam\(slot) is still aimed at \(host) — we are "
                         + "\(wanted.host ?? "?"). Press Start to send it here.")
                self.lastError = "Camera \(slot) points at \(host), "
                    + "not \(wanted.host ?? "?") — press Start"
            }
        }
    }

    private func update(_ serial: String, _ change: (inout Camera) -> Void) {
        guard let index = cameras.firstIndex(where: { $0.serial == serial }) else { return }
        change(&cameras[index])
    }

    // MARK: - Camera control

    func startAllCameras() {
        for camera in cameras { startCamera(camera.slot, reason: "operator pressed Start All") }
    }

    func stopAllCameras() {
        for camera in cameras { stopCamera(camera.slot) }
    }

    /// `reason` is written to the log.
    ///
    /// A camera going to air is the one thing that must never be a mystery. When
    /// one starts and nobody remembers pressing anything, the log has to be able
    /// to say whether that was a person, a retry, or the address changing.
    func startCamera(_ slot: Int, reason: String = "operator pressed Start", attempt: Int = 1) {
        guard let camera = cameras.first(where: { $0.slot == slot }),
              let session = sessions[camera.serial] else { return }

        Log.info("cam", "cam\(slot) start requested — \(reason)")
        startRequestedAt[slot] = Date()
        startStep[slot] = "connecting"
        let base = rtmpBase(forSlot: slot)
        // Built outside the task so the nested closure captures the model once,
        // weakly, rather than an optional that has already been captured.
        // The handler runs off the main actor, so it hops back rather than
        // touching the model where it is called.
        let record: @Sendable (String) -> Void = { [weak self] text in
            let model = self
            Task { @MainActor in model?.startStep[slot] = text }
        }

        Task { [weak self] in
            await session.setStepHandler(record)
            let acknowledged: Bool
            do {
                acknowledged = try await session.startStreaming(rtmpBase: base)
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.lastError = "Start cam\(slot): \(error)"
                    self.startStep[slot] = "start failed"
                }
                return
            }
            await self?.watchForPictures(slot: slot, attempt: attempt,
                                         acknowledged: acknowledged)
        }
    }

    /// Waits for the pictures the start was for, and asks again if none come.
    ///
    /// `startStreaming` deliberately believes nothing the camera says about
    /// whether it started — the reference tool compares an opcode against a
    /// return code and so reads every reply as success, and the firmware really
    /// does answer `UNKNOWN_ERROR` to a START that then works. The only honest
    /// signal is a stream turning up. So the return code is not acted on here
    /// either; this waits for the streams, and acts on their absence.
    ///
    /// Retrying immediately is what must not happen: eight STARTs in sixteen
    /// seconds put a camera into a state where even a file fetch that had just
    /// worked came back `UNKNOWN_ERROR` (MEASUREMENTS M8).
    ///
    /// And a camera that answered `UNKNOWN_ERROR` is not asked again at all —
    /// that never worked once and made things worse. See
    /// `CameraSession.retryIsPointless` for the measurement.
    private func watchForPictures(slot: Int, attempt: Int, acknowledged: Bool) async {
        try? await Task.sleep(for: .seconds(30))

        guard cameras.contains(where: { $0.slot == slot }) else { return }
        guard startRequestedAt[slot] != nil else { return }        // stopped meanwhile
        guard (cameras.first { $0.slot == slot }?.lensesArriving ?? 0) == 0 else { return }

        func giveUp(_ why: String) {
            Log.warn("cam", "cam\(slot) sent nothing 30s after \(why) — this one needs a "
                     + "power cycle")
            startStep[slot] = "no pictures — power cycle it"
            lastError = "Camera \(slot) will not start — pull its power and plug it back in"
        }

        guard acknowledged else { return giveUp("refusing the START") }
        guard attempt < 2 else { return giveUp("being asked twice") }

        Log.warn("cam", "cam\(slot) accepted the START but no pictures arrived in 30s "
                 + "— asking once more")
        startCamera(slot, reason: "nothing arrived after attempt \(attempt)", attempt: attempt + 1)
    }

    /// Where this camera's four streams live.
    ///
    /// One address serves both directions: it is what the camera is told to
    /// publish to, and what the desk reads back from. Cameras publish to the node
    /// that owns them — at twenty-four cameras everything through this Mac would
    /// be several Gbit/s — and with no node configured they publish here, which
    /// is what happens on the bench.
    private func rtmpBase(forSlot slot: Int) -> String {
        let host = nodeHost(forSlot: slot) ?? NetworkInterface.primaryIPv4() ?? "127.0.0.1"
        return String(format: "rtmp://%@:%d/cam%02d/", host, configuration.rtmpPort, slot)
    }

    func stopCamera(_ slot: Int) {
        guard let camera = cameras.first(where: { $0.slot == slot }),
              let session = sessions[camera.serial] else { return }
        startRequestedAt[slot] = nil
        startStep[slot] = nil
        videoFailures[slot] = nil
        Task {
            do { try await session.stopStreaming() }
            catch { await MainActor.run { self.lastError = "Stop cam\(slot): \(error)" } }
        }
    }

    /// `VIDEO_FAIL` is a state, not an error.
    ///
    /// It is what the camera says when its encoder would not start, and the
    /// reference tool answers it by waiting a second and sending START again —
    /// indefinitely, because the camera does come up on the second or third try.
    /// Treating it as a failure and stopping is what makes a camera look dead
    /// when it is only slow. Repeated failures usually mean PoE power, so that is
    /// what the operator is eventually told.
    private func retryAfterVideoFail(slot: Int) {
        // Only retry a start this app asked for. A camera that was left
        // streaming by a previous session announces its own encoder failures the
        // moment we connect, and answering those with START would have the app
        // putting cameras to air on its own account, before anyone pressed
        // anything.
        guard startRequestedAt[slot] != nil else {
            Log.info("cam", "cam\(slot) reported video failed, but was not started here — leaving it alone")
            return
        }

        let count = (videoFailures[slot] ?? 0) + 1
        videoFailures[slot] = count
        Log.warn("cam", "cam\(slot) video failed, sending START again (attempt \(count))")

        if count >= 4 {
            lastError = "Camera \(slot): video keeps failing — check its PoE supply"
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.startCamera(slot, reason: "retry after VIDEO_FAIL (attempt \(count))")
        }
    }

    private func nodeHost(forSlot slot: Int) -> String? {
        configuration.nodes.first { $0.cameras.contains(slot) }?.host
    }

    // MARK: - The two decoded cameras

    /// Attaches programme and preview to the switcher, and lets everything else
    /// go.
    ///
    /// This is where "only these two cameras are decoded" is actually enforced.
    /// It also means a camera does not appear the instant it is selected — it has
    /// to be attached and its first frames decoded first, which is precisely why
    /// the desk is Preview → Take → Program rather than a straight cut.
    private func syncDesk() {
        guard let switcher else { return }

        // A camera counts as available to the desk if its streams are arriving,
        // whoever started them. These cameras resume streaming on their own after
        // a power cut, and they keep streaming when the app quits — so "we did
        // not start it" is not the same as "there is nothing there", and treating
        // it that way leaves a perfectly good picture off the desk.
        // Program and preview always; then as many more as the budget allows.
        //
        // Decoding only two is a rule for twenty-four cameras, not for four. With
        // a handful on the network there is no reason to tear a camera down and
        // build it back up on every click — which is why a thumbnail took seconds
        // to appear in preview. Keeping them decoded makes selection instant, and
        // costs nothing that is not already spare.
        let available = cameras
            .filter { $0.isStreaming || $0.lensesArriving > 0 }
            .map(\.slot)

        var wanted = Set([programSlot, previewSlot].compactMap { $0 })
            .filter { available.contains($0) }

        for slot in available.sorted() where wanted.count < deskDecodeBudget {
            wanted.insert(slot)
        }

        for slot in deskSources.keys where !wanted.contains(slot) {
            deskSources[slot]?.stop()
            deskSources[slot] = nil
            switcher.removeSource(slot: slot)
            Log.info("desk", "cam\(slot) released")
        }

        for slot in wanted where deskSources[slot] == nil {
            let source = CameraSource(slot: slot)
            do {
                try source.attach(to: switcher, rtmpBase: rtmpBase(forSlot: slot))
                deskSources[slot] = source
                if let delay = camera(slot: slot)?.delayMilliseconds {
                    switcher.setDelay(slot: slot, seconds: delay / 1000)
                }
            } catch {
                lastError = "Desk cam\(slot): \(error)"
                Log.error("desk", "cam\(slot): \(error)")
            }
        }

        switcher.setProgram(slot: programSlot)
        switcher.setPreview(slot: previewSlot)
        switcher.setMix(Float(min(mix, 0.999)))

        // The four output lanes are only worth running once there is something
        // to send down them.
        if !deskSources.isEmpty { startOutputs() }
    }

    /// Publishes the programme back into MediaMTX, on the four paths the stitcher
    /// expects. Vahana is always an RTMP client, so it pulls from here.
    private func startOutputs() {
        guard !outputsStarted, let switcher else { return }
        outputsStarted = true
        let host = "127.0.0.1"
        let port = configuration.rtmpPort
        do {
            try switcher.startOutputs { lens in
                "rtmp://\(host):\(port)/program/\(lens)"
            }
            Log.info("desk", "programme published to rtmp://\(host):\(port)/program/")
        } catch {
            outputsStarted = false
            lastError = "Programme output: \(error)"
            Log.error("desk", "programme output: \(error)")
        }
    }

    // MARK: - Switching

    /// The only way preview should ever change from the interface.
    ///
    /// Assigning `previewSlot` directly updates what the desk *draws* and
    /// nothing else — the switcher never hears about it, so the monitor keeps
    /// showing the old camera while the tile insists a new one is selected.
    /// That is exactly the "two sources for one state" the desk is built to
    /// avoid, so the setter does both or neither.
    func selectPreview(_ slot: Int) {
        guard slot != programSlot else { return }
        previewSlot = slot
        syncDesk()
    }

    /// Puts preview on air.
    ///
    /// A cut swaps immediately; a dissolve animates the mix and swaps at the
    /// end. Either way all four lanes move on the same value, which is the whole
    /// reason the switcher is one object and not four.
    func take() {
        guard previewSlot != nil else { return }
        transitionTask?.cancel()

        if transitionIsCut {
            swap()
            return
        }

        let duration = transitionMilliseconds / 1000
        let started = Date()
        autoRunning = true
        transitionTask = Task { @MainActor in
            defer { autoRunning = false }
            while !Task.isCancelled {
                let progress = Date().timeIntervalSince(started) / duration
                if progress >= 1 { swap(); return }
                mix = min(max(progress, 0), 1)
                // One clock drives the dissolve: this one. The switcher follows
                // it, so what is on the T-bar and what leaves the desk are the
                // same number and cannot drift apart. It is held below 1 because
                // reaching 1 would make the switcher swap on its own account too.
                switcher?.setMix(Float(min(mix, 0.999)))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// CUT, whatever the transition style says.
    ///
    /// A cut button that dissolves because a style was left selected is the
    /// kind of surprise a desk must never produce, so this does not consult
    /// `transitionIsCut` at all.
    func cut() {
        guard previewSlot != nil else { return }
        transitionTask?.cancel()
        mix = 0
        swap()
    }

    /// Pressing a key on the programme bus. The bus is always live, so this
    /// goes to air immediately — that is what makes it the programme bus.
    func takeToAir(_ slot: Int) {
        guard slot != programSlot else { return }
        transitionTask?.cancel()
        mix = 0
        if previewSlot == slot { previewSlot = programSlot }
        programSlot = slot
        switcher?.setMix(0)
        syncDesk()
        Log.info("desk", "cam\(slot) taken to air from the programme bus")
    }

    /// Where the T-bar handle physically is, 0 at the top, 1 at the bottom.
    ///
    /// Kept apart from `mix` because they are not the same thing. The mix is
    /// how far through a transition we are; the handle is where somebody's hand
    /// left it. They only agree while a transition is running in the downward
    /// direction.
    var tbarPosition: Double = 0

    /// The end the current transition started from.
    private var tbarAnchor: Double = 0

    /// True only while AUTO is running the dissolve on its own clock.
    private(set) var autoRunning = false

    /// What the ladders beside the T-bar show.
    ///
    /// The handle's position, not the transition's progress. A fader's scale
    /// says where the fader is, so it empties on the way back up the same way
    /// it filled on the way down — reading progress instead meant it filled
    /// again while the hand was returning, and never came back at all.
    ///
    /// The one exception is AUTO, which runs the dissolve without touching the
    /// handle. There is nothing else for the scale to say then, so it says how
    /// far through the transition is.
    var ladderLevel: Double { autoRunning ? mix : tbarPosition }

    /// The T-bar, or a MIDI fader.
    ///
    /// Flip-flop, as every hardware desk does it: pull it down to make the
    /// transition, and it **stays** at the bottom. The next transition is made
    /// by pushing it back up. Snapping the handle back to the top after every
    /// take is the behaviour of a progress bar, not of a fader — the hand is
    /// still on it, and it would fight you.
    func setTBar(_ value: Double) {
        transitionTask?.cancel()
        autoRunning = false
        tbarPosition = min(max(value, 0), 1)

        let travelled = abs(tbarPosition - tbarAnchor)
        if travelled >= 0.999 {
            swap()
            tbarAnchor = tbarPosition   // the far end becomes the new start
            switcher?.setMix(0)
            return
        }
        mix = travelled
        switcher?.setMix(Float(travelled))
    }

    /// Kept for MIDI and anything else that thinks in mix rather than in
    /// handle position.
    func setMix(_ value: Double) {
        transitionTask?.cancel()
        mix = min(max(value, 0), 1)
        if mix >= 0.999 { swap(); return }
        switcher?.setMix(Float(mix))
    }

    private func swap() {
        // The handle is not moved here on purpose. AUTO and CUT run the
        // transition without it, and yanking it across the desk while an
        // operator's hand rests on it is the one thing a fader must never do.
        let old = programSlot
        programSlot = previewSlot
        previewSlot = old
        mix = 0
        transitionTask = nil
        syncDesk()
    }

    // MARK: - Recording

    func startRecording() {
        isRecording = true
        recordingStarted = Date()
        Log.info("app", "recording started")
        for node in nodes where node.online {
            post("http://\(node.host):8000/record/start/all")
        }
    }

    func stopRecording() {
        isRecording = false
        recordingStarted = nil
        Log.info("app", "recording stopped")
        for node in nodes where node.online {
            post("http://\(node.host):8000/record/stop/all")
        }
    }

    private func post(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    var recordingDuration: String {
        guard let started = recordingStarted else { return "00:00:00" }
        let total = Int(Date().timeIntervalSince(started))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Nodes

    private func startPolling() {
        // Only work that finishes in milliseconds belongs here. What the screen
        // shows — which lenses are arriving — is read every second and nothing
        // is allowed to hold it up.
        pollTask = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                checkOwnAddress()
                await pollStreams()
                if tick % 2 == 0 { await pollNodes() }
                if tick % 5 == 0 { reportDesk() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // Everything slow gets its own clock. Awaiting a network sweep from
        // inside the one-second loop stalled it for tens of seconds, and the
        // desk went on saying "still waiting" next to a picture that was already
        // live — the numbers were right, they just never arrived.
        // Presence gets its own clock too, and a fast one. It is six pings and
        // one read of the ARP table — well under a second — and it is the thing
        // the operator watches while plugging cameras in, so it must not share a
        // loop with anything slow.
        presenceTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await updatePresence()
            }
        }

        housekeepingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                // The subnet sweep is two hundred and fifty-four pings and takes
                // tens of seconds. It is only worth running to find hardware on
                // an address nobody has ever seen — presence handles everything
                // already known, and re-adopts a rebooted camera without it.
                guard isMissingSomething,
                      Date().timeIntervalSince(lastSweep) > 60 else { continue }
                lastSweep = Date()
                await sweepForHardware()
            }
        }
    }

    /// A line in the log saying whether pictures are moving, and where they stop.
    ///
    /// Three numbers separate the three ways a monitor stays black: nothing was
    /// read from RTMP, frames were read but never composited, or frames reached
    /// the monitor and the view is at fault.
    private func reportDesk() {
        guard !deskSources.isEmpty else { return }
        let read = deskSources
            .sorted { $0.key < $1.key }
            .map { "cam\($0.key) read \($0.value.framesIn)" }
            .joined(separator: " · ")
        let counts = monitorFrames.counts
        Log.info("desk", "\(read) · monitor program \(counts.program) preview \(counts.preview)")
    }

    /// Who is really on the wire, asked every couple of seconds.
    ///
    /// Everything else the app can see lies about this, and each one lies for a
    /// different reason. The Bonjour record stays because an unplugged camera
    /// cannot announce its own departure. The control socket stays "connected"
    /// because nothing tells our end that the other end lost power. The ARP
    /// entry stays for twenty minutes. The MediaMTX path stays until the read
    /// times out, two minutes later — which is why a camera in a flight case
    /// went on showing four lit lenses.
    ///
    /// And the check this replaced asked the worst question of all: is a port
    /// open at the address this camera had? DHCP hands a released address to the
    /// next camera that asks for one. Unplug 2, 9 and 12, plug in 4, 5 and 7,
    /// and the new cameras take the old leases — so the old three answered on
    /// their own addresses, from hardware that was not them, and never left the
    /// desk. That is exactly what happened here.
    ///
    /// So: ICMP for "is anything alive at this address", and the MAC out of the
    /// ARP table for "is it still *this* camera". A MAC is burned in. If it has
    /// moved to another address the camera moved with it; if it is nowhere, the
    /// camera is gone, whatever else is answering in its place.
    private func updatePresence() async {
        let known = cameras.map { (serial: $0.serial, host: $0.host, mac: $0.mac) }
        let hosts = Array(Set(known.map(\.host)).union(watchedHosts))
        guard !hosts.isEmpty else { return }

        // Both of these spawn processes and wait on them, which on the main
        // actor is a beachball. Only the answer comes back.
        let (alive, arp) = await Task.detached(priority: .utility) {
            (NetworkProbe.reachable(hosts: hosts), NetworkProbe.arpTable())
        }.value

        var gone: [Camera] = []
        var changed = false

        for index in cameras.indices {
            let camera = cameras[index]

            // Learn the MAC the first time it can be read, then keep it.
            if camera.mac.isEmpty, let mac = arp[camera.host] {
                cameras[index].mac = mac
                continue
            }

            var here = alive.contains(camera.host)
            if here, !camera.mac.isEmpty, let at = arp[camera.host], at != camera.mac {
                // Something answers, but it is not this camera. Almost always a
                // recycled lease.
                here = false
            }

            // Followed its MAC to a new address: that is a move, not a loss.
            if !here, !camera.mac.isEmpty,
               let moved = arp.first(where: { $0.value == camera.mac && $0.key != camera.host })?.key,
               alive.contains(moved) {
                Log.info("app", "camera \(camera.slot) moved from \(camera.host) to \(moved)")
                cameras[index].host = moved
                watchedHosts.insert(moved)
                missedPresence[camera.serial] = 0
                connect(cameras[index])
                changed = true
                continue
            }

            if here {
                missedPresence[camera.serial] = 0
                continue
            }

            let misses = (missedPresence[camera.serial] ?? 0) + 1
            missedPresence[camera.serial] = misses

            // Two misses — about four seconds — and the tile stops claiming a
            // connection and stops showing lenses MediaMTX has not noticed are
            // dead yet. The operator sees the truth within a breath of pulling
            // the plug.
            if misses == 2 {
                cameras[index].state = .disconnected
                cameras[index].lensesArriving = 0
                startRequestedAt[camera.slot] = nil
                startStep[camera.slot] = nil
                changed = true
            }
            // Five — about ten seconds — and it is off the list. Its place in
            // the roster is untouched; that is what the roster is for.
            if misses >= 5 { gone.append(camera) }
        }

        for camera in gone {
            Log.info("app", "camera \(camera.slot) (\(camera.serial)) is no longer on the "
                     + "network — removing it")
            sessions[camera.serial]?.closeImmediately()
            sessions[camera.serial] = nil
            reconnectTasks[camera.serial]?.cancel()
            reconnectTasks[camera.serial] = nil
            deskSources[camera.slot]?.stop()
            deskSources[camera.slot] = nil
            switcher?.removeSource(slot: camera.slot)
            startRequestedAt[camera.slot] = nil
            startStep[camera.slot] = nil
            missedPresence[camera.serial] = nil
            cameras.removeAll { $0.serial == camera.serial }

            if programSlot == camera.slot { programSlot = cameras.first?.slot }
            if previewSlot == camera.slot { previewSlot = cameras.first?.slot }
        }

        // Anything Orah-made that is alive here and is not one of ours gets
        // picked up now rather than at the next subnet sweep. A camera that has
        // just been rebooted is back on the desk in seconds this way.
        let ours = Set(cameras.map(\.host))
        let strangers = arp
            .filter { $0.value.hasPrefix(NetworkProbe.orahOUI) }
            .filter { alive.contains($0.key) && !ours.contains($0.key) }
            .map(\.key)
            .sorted()

        for host in strangers where !adoptionsInFlight.contains(host) {
            adoptionsInFlight.insert(host)
            Task { @MainActor in
                defer { adoptionsInFlight.remove(host) }
                // The second SoC of a camera sits on the next address up and
                // does not listen for control, so it is not a camera of its own.
                guard await Task.detached(priority: .utility, operation: {
                    NetworkProbe.portOpen(host: host, port: 9989, timeout: 1)
                }).value else { return }
                await adoptUnannounced(host: host)
            }
        }

        if changed || !gone.isEmpty { syncDesk() }
        reconnectAnythingStranded(alive: alive)
    }

    /// A camera that is on the wire and has no control session gets one.
    ///
    /// The scheduled reconnect is one timer per drop, and a timer is a single
    /// point of failure: lose the wake-up — cancelled, raced against a second
    /// drop, swallowed by a `connect()` that returned without doing anything —
    /// and that camera never gets another chance. Seen exactly that: three
    /// cameras answered on 9989 all evening while the desk showed them still
    /// booting, because each had dropped once on a `videoFail` at start-up and
    /// nothing ever knocked again.
    ///
    /// This does not replace the backoff — it is the floor under it. Presence
    /// already knows who is reachable, so the check is free, and the answer to
    /// "why is it not connected" becomes "give it two seconds".
    private func reconnectAnythingStranded(alive: Set<String>) {
        for camera in cameras where alive.contains(camera.host) {
            // `.busy` is not stranded, it is refusing — the camera has a control
            // session open and only a power cycle will free it. Knocking is the
            // one thing that cannot help, and doing it in a loop is how a
            // locked-out camera turns into a locked-out camera plus a status
            // that flickers.
            guard camera.state != .busy else { continue }

            var isDead: Bool {
                if case .failed = camera.state { return true }
                return camera.state == .disconnected
            }
            guard isDead else { continue }
            guard reconnectTasks[camera.serial] == nil else { continue }
            guard let session = sessions[camera.serial] else { continue }

            // A floor under the rate, independent of how often this is asked.
            let last = lastKnock[camera.serial] ?? .distantPast
            guard Date().timeIntervalSince(last) > 10 else { continue }
            lastKnock[camera.serial] = Date()

            reconnectTasks[camera.serial] = Task { @MainActor [weak self] in
                defer { self?.reconnectTasks[camera.serial] = nil }
                Log.info("cam", "cam\(camera.slot) is on the network with no control session "
                         + "— knocking again")
                do { try await session.connect() }
                catch { Log.warn("cam", "cam\(camera.slot) would not take a session: \(error)") }
            }
        }
    }

    // MARK: - The desk

    /// How many keys each bus has. Two rows of twelve, because that is what a
    /// hand can cross without looking and what twenty-four cameras need.
    static let keysPerBus = 24

    /// Which camera is under each key. Empty positions are kept, not closed up:
    /// a gap in the middle of a bus is a position somebody's finger remembers.
    var buttons: [Camera?] {
        var out = [Camera?](repeating: nil, count: Self.keysPerBus)
        var unplaced = cameras.sorted { $0.slot < $1.slot }

        // Anything explicitly assigned goes where it was put.
        for (key, serial) in configuration.buttonAssignments {
            guard let index = Int(key), index >= 0, index < out.count,
                  let found = unplaced.firstIndex(where: { $0.serial == serial })
            else { continue }
            out[index] = unplaced.remove(at: found)
        }
        // The rest fall into the first free keys, in rig order, so a fresh
        // install is usable before anybody has assigned anything.
        for camera in unplaced {
            guard let free = out.firstIndex(where: { $0 == nil }) else { break }
            out[free] = camera
        }
        return out
    }

    func assign(button index: Int, to serial: String?) {
        _ = ConfigStore.shared.mutate { config in
            config.buttonAssignments = config.buttonAssignments.filter { $0.value != serial }
            if let serial { config.buttonAssignments[String(index)] = serial }
            else { config.buttonAssignments[String(index)] = nil }
        }
        configuration = ConfigStore.shared.config
    }

    var keyLegendIsName: Bool { configuration.keyLegend != "number" }

    func setKeyLegend(name: Bool) {
        _ = ConfigStore.shared.mutate { $0.keyLegend = name ? "name" : "number" }
        configuration = ConfigStore.shared.config
    }

    /// What a key reads. One line, capitals — two lines of small type on a
    /// square is unreadable at arm's length.
    func legend(for camera: Camera) -> String {
        keyLegendIsName ? camera.name.uppercased()
                        : String(format: "CAM %02d", camera.slot)
    }

    // MARK: - Multiview layout

    /// One way of arranging a multiview.
    ///
    /// Taken from the design rather than invented here: a band of large boxes
    /// at one end, a grid of sources filling the rest. Everything the interface
    /// needs to draw a layout — and to draw the little picture of it in the
    /// picker — comes from these numbers, so the thumbnail can never show
    /// something the screen does not do.
    struct MultiviewLayout: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let columns: Int
        /// Rows of sources beneath (or above) the band of boxes.
        let sourceRows: Int
        let boxes: Int
        /// A box measured in grid cells.
        let boxWidth: Int
        let boxHeight: Int
        let boxesOnTop: Bool

        /// Sources that fit: whatever is left beside the boxes, plus the rows.
        var sourceCount: Int {
            (boxes > 0 ? max(0, columns - boxes * boxWidth) * boxHeight : 0)
            + columns * sourceRows
        }

        static let all: [MultiviewLayout] = [
            .init(id: "wall24",  title: "24-up wall · 8×3", columns: 8, sourceRows: 3,
                  boxes: 0, boxWidth: 0, boxHeight: 0, boxesOnTop: true),
            .init(id: "wall18",  title: "18-up wall · 6×3", columns: 6, sourceRows: 3,
                  boxes: 0, boxWidth: 0, boxHeight: 0, boxesOnTop: true),
            .init(id: "big4top", title: "4 boxes top + 16", columns: 8, sourceRows: 2,
                  boxes: 4, boxWidth: 2, boxHeight: 2, boxesOnTop: true),
            .init(id: "big4bot", title: "4 boxes bottom + 16", columns: 8, sourceRows: 2,
                  boxes: 4, boxWidth: 2, boxHeight: 2, boxesOnTop: false),
            .init(id: "big2top", title: "2 boxes top + 20", columns: 8, sourceRows: 2,
                  boxes: 2, boxWidth: 2, boxHeight: 2, boxesOnTop: true),
            .init(id: "big2bot", title: "2 boxes bottom + 20", columns: 8, sourceRows: 2,
                  boxes: 2, boxWidth: 2, boxHeight: 2, boxesOnTop: false),
            .init(id: "pgmhalf", title: "program half + 12", columns: 8, sourceRows: 2,
                  boxes: 1, boxWidth: 4, boxHeight: 3, boxesOnTop: true),
            .init(id: "boxonly", title: "boxes only", columns: 8, sourceRows: 0,
                  boxes: 4, boxWidth: 2, boxHeight: 3, boxesOnTop: true),
        ]

        static func named(_ id: String) -> MultiviewLayout {
            all.first { $0.id == id } ?? all[2]
        }
    }

    /// How many multiview generators there are.
    ///
    /// Four, because a gallery on a big show has more than one wall and they
    /// are never wanted the same way round — boxes in front of the operator,
    /// the full rig behind, a quad for the director, one for whoever is
    /// watching audio. The first is also the one embedded in the main window.
    static let multiviewCount = 4

    private(set) var multiviewLayout: [Int: String] = [:]

    func layout(for generator: Int) -> MultiviewLayout {
        MultiviewLayout.named(multiviewLayout[generator]
                              ?? (generator == 1 ? "big4top" : "wall24"))
    }

    /// Generators currently open as windows of their own.
    ///
    /// The first one also lives in the main window, so this is what tells the
    /// desk to close that space up: once the wall is on its own screen, the
    /// main window has no reason to keep a hole where it used to be.
    private(set) var detachedMultiviews: Set<Int> = []

    func multiviewDetached(_ generator: Int, _ detached: Bool) {
        if detached { detachedMultiviews.insert(generator) }
        else { detachedMultiviews.remove(generator) }
    }

    var showsInlineMultiview: Bool { !detachedMultiviews.contains(1) }

    func setLayout(_ layout: MultiviewLayout, for generator: Int) {
        multiviewLayout[generator] = layout.id
        Log.info("ui", "multiview \(generator) laid out as \(layout.id)")
    }

    /// Where each generator's picture goes, for the label on its tab.
    func output(for generator: Int) -> String {
        generator == 1 && showsInlineMultiview ? "in the desk window"
                                               : "Window · display \(generator + 1)"
    }

    // MARK: - Saved layouts

    struct SavedLayout: Identifiable, Hashable, Sendable {
        let id = UUID()
        var name: String
        var layoutID: String
        var when: String
    }

    private(set) var savedLayouts: [SavedLayout] = [
        .init(name: "Gallery — show", layoutID: "big4top", when: "default"),
        .init(name: "Wall — full rig", layoutID: "wall24", when: "default"),
    ]

    func saveLayout(named name: String, generator: Int) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        savedLayouts.insert(.init(name: name, layoutID: layout(for: generator).id, when: stamp),
                            at: 0)
    }

    func recall(_ saved: SavedLayout, generator: Int) {
        setLayout(MultiviewLayout.named(saved.layoutID), for: generator)
    }

    /// Whether the two free boxes are switched on. Preview and program are
    /// bound to the desk and cannot be turned off — they are the two the
    /// operator is judging.
    private(set) var boxEnabled: [String: Bool] = [:]

    func toggleBox(_ number: Int, generator: Int) {
        guard number >= 3 else { return }
        let key = "\(generator)-\(number)"
        boxEnabled[key] = !(boxEnabled[key] ?? true)
    }

    func isBoxOn(_ number: Int, generator: Int) -> Bool {
        number < 3 || (boxEnabled["\(generator)-\(number)"] ?? true)
    }

    // MARK: - Which lens a source tile shows

    /// A camera is four lenses, and which one a tile shows is a per-camera
    /// choice: the front of one unit and the crowd side of another are what you
    /// want side by side, not the same numbered lens on every tile.
    private(set) var tileLens: [Int: Int] = [:]

    func lens(for slot: Int) -> Int { tileLens[slot] ?? 0 }

    func setLens(_ lens: Int, for slot: Int) {
        tileLens[slot] = max(0, min(3, lens))
        if !cameraSinkStore.isEmpty {
            switcher?.inspect(cameras: cameraSinkStore.keys.reduce(into: [:]) {
                $0[$1] = self.lens(for: $1)
            })
        }
        // Program and preview are the two the switcher actually decodes, so
        // changing their lens is the one case that has to reach it.
        if slot == programSlot || slot == previewSlot { syncDesk() }
    }

    // MARK: - Multiview boxes

    /// The four large boxes. The first two follow the desk; the other two are
    /// free, hold four sources each, and can be switched off.
    var freeBoxes: [[Camera]] {
        configuration.multiviewBoxes.map { serials in
            serials.compactMap { serial in cameras.first { $0.serial == serial } }
        }
    }

    var boxIsOn: [Bool] {
        configuration.multiviewBoxes.map { !$0.isEmpty }
    }

    /// Drops a camera into the first free quadrant of a box, or pushes out the
    /// oldest when all four are taken. Sending one that is already there takes
    /// it out again, so the same key both adds and removes.
    func sendToBox(_ box: Int, serial: String) {
        _ = ConfigStore.shared.mutate { config in
            guard box < config.multiviewBoxes.count else { return }
            var slots = config.multiviewBoxes[box]
            if let existing = slots.firstIndex(of: serial) { slots.remove(at: existing) }
            else if slots.count >= 4 { slots.removeFirst(); slots.append(serial) }
            else { slots.append(serial) }
            config.multiviewBoxes[box] = slots
        }
        configuration = ConfigStore.shared.config
    }

    func boxContains(_ box: Int, serial: String) -> Bool {
        guard box < configuration.multiviewBoxes.count else { return false }
        return configuration.multiviewBoxes[box].contains(serial)
    }

    // MARK: - Colour

    /// The four lenses of whichever camera the colour panel is watching.
    ///
    /// Shading without seeing the picture is guessing, and the camera being
    /// shaded is usually neither on air nor in preview — that is the point of
    /// doing it before you cut to it. These are fed only while the panel is
    /// open, so they cost nothing the rest of the time.
    let inspectSinks = (0..<4).map { _ in VideoSink() }

    /// Tells the switcher which camera to make a picture of, and whether to
    /// show it before or after its grade.
    func watch(slot: Int?, bypass: Bool = false) {
        switcher?.inspect(slot: slot, bypass: bypass)
        if slot == nil { for sink in inspectSinks { sink.push(nil) } }
    }

    /// One sink per camera, for the row of pictures over the colour controls.
    /// Made on demand — a camera nobody is shading costs nothing.
    private var cameraSinkStore: [Int: VideoSink] = [:]

    func cameraSink(slot: Int) -> VideoSink {
        if let existing = cameraSinkStore[slot] { return existing }
        let made = VideoSink()
        cameraSinkStore[slot] = made
        return made
    }

    /// Watch several cameras at once, each at its own chosen lens.
    func watch(cameras: [Int], bypass: Bool = false) {
        var map: [Int: Int] = [:]
        for slot in cameras { map[slot] = lens(for: slot) }
        switcher?.inspect(cameras: map, bypass: bypass)
        if cameras.isEmpty { for sink in cameraSinkStore.values { sink.push(nil) } }
    }

    /// The grade for a camera, by slot. Neutral when it has never been touched.
    func grade(slot: Int) -> ColourGrade {
        guard let serial = camera(slot: slot)?.serial else { return ColourGrade() }
        return configuration.colourGrades[serial] ?? ColourGrade()
    }

    /// Applies a grade and remembers it.
    ///
    /// Straight through to the switcher, which picks it up on the next frame —
    /// so a camera can be shaded while it is on air, which is exactly when
    /// somebody notices it needs shading.
    func setGrade(_ grade: ColourGrade, slot: Int) {
        guard let serial = camera(slot: slot)?.serial else { return }
        _ = ConfigStore.shared.mutate { config in
            if grade.isNeutral { config.colourGrades[serial] = nil }
            else { config.colourGrades[serial] = grade }
        }
        configuration = ConfigStore.shared.config
        switcher?.setGrade(grade, slot: slot)
    }

    /// Cameras carrying a correction — the desk shows a dot on their keys.
    var gradedSlots: Set<Int> {
        Set(cameras.filter { !(configuration.colourGrades[$0.serial] ?? ColourGrade()).isNeutral }
                   .map(\.slot))
    }

    /// Puts every remembered grade back after the switcher is rebuilt.
    private func restoreGrades() {
        for camera in cameras {
            let grade = configuration.colourGrades[camera.serial] ?? ColourGrade()
            if !grade.isNeutral { switcher?.setGrade(grade, slot: camera.slot) }
        }
    }

    /// When each camera was last knocked at, so no path can turn into a loop.
    private var lastKnock: [String: Date] = [:]

    /// Whether this address is the second SoC of a camera we already have.
    ///
    /// The two boards sit on consecutive addresses. The upper one does not
    /// listen for control, so anything found there is half of a camera already
    /// on the list, never a camera of its own.
    private func isSecondSoC(of host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, let last = Int(parts[3]), last > 0 else { return false }
        let below = parts.dropLast().joined(separator: ".") + ".\(last - 1)"
        return cameras.contains { $0.host == below }
    }

    /// Addresses currently being asked who they are, so two passes do not both
    /// open a control session to the same camera — the camera only has one.
    private var adoptionsInFlight: Set<String> = []

    /// Whether a sweep could tell us anything we do not already know.
    private var isMissingSomething: Bool {
        if roster.entries.isEmpty { return cameras.isEmpty }
        let present = Set(cameras.map(\.serial))
        return roster.entries.contains { entry in
            guard let serial = entry.serial else { return true }
            return !present.contains(serial)
        }
    }

    /// Looks for Orah hardware the way the wire sees it, not the way Bonjour
    /// reports it.
    ///
    /// Anything found here that is not already a known camera is real hardware
    /// that the app would otherwise be blind to — and on a rig day "the camera
    /// is there but not announcing" is a completely different problem from "the
    /// camera is not there", which is the distinction that decides whether
    /// somebody goes to check the power or the switch.
    private func sweepForHardware() async {
        // Every step of this spawns a process and waits for it, and this model
        // is on the main actor — so doing it here freezes the interface for as
        // long as the sweep takes. Measured: the main thread stuck in `read()`
        // waiting on `nc`, for the whole sample.
        //
        // So the work goes to a detached task and only the answer comes back.
        let knownHosts = Set(cameras.map(\.host))
        let strangers = await Task.detached(priority: .utility) { () -> [UnannouncedCamera] in
            var out: [UnannouncedCamera] = []
            for (host, mac) in await NetworkProbe.orahAddresses() where !knownHosts.contains(host) {
                // The second SoC of a camera sits on the next address up and
                // does not listen for control, so it is not a camera of its own.
                guard NetworkProbe.portOpen(host: host, port: 9989, timeout: 1) else { continue }
                out.append(UnannouncedCamera(host: host, mac: mac, controlAnswers: true))
            }
            return out
        }.value

        unannounced = strangers

        // Finding it is not enough — it has to become a camera.
        //
        // Bonjour misses cameras routinely: multicast from a wireless client to
        // wired devices is what access points drop, and a camera that has just
        // been plugged in may take minutes to be announced, or never be. The
        // wire always knows. So anything answering on the control port is
        // adopted, with its identity taken from the camera itself.
        for stranger in strangers where !adoptionsInFlight.contains(stranger.host) {
            adoptionsInFlight.insert(stranger.host)
            defer { adoptionsInFlight.remove(stranger.host) }
            Log.warn("discovery", "\(stranger.host) (\(stranger.mac)) answers on 9989 but is "
                     + "not announced — asking it who it is")
            await adoptUnannounced(host: stranger.host)
        }
    }

    /// Brings in a camera that Bonjour never mentioned.
    ///
    /// The serial cannot be read off an announcement that does not exist, so it
    /// is asked for directly. One short session, then the camera is adopted
    /// exactly as a discovered one would be.
    private func adoptUnannounced(host: String) async {
        // Asking who is there costs a control session, and a camera only has
        // one. Two guards, at the one place both discovery paths meet:
        //
        // A camera we already have, at an address we already know, has nothing
        // to tell us — and probing it takes the session away from the desk. Seen
        // here: camera 11 was already adopted at .179, already locked at 503,
        // and the sweep went and asked it who it was anyway.
        guard !cameras.contains(where: { $0.host == host }) else { return }
        guard !isSecondSoC(of: host) else { return }

        let probe = CameraSession(discovered: DiscoveredCamera(
            serviceName: "unannounced@\(host)", host: host, port: 9989))

        do {
            try await probe.connect()
            let info = try await probe.requestCameraInfo()
            probe.closeImmediately()
            await probe.disconnect()

            guard !info.serialNumber.isEmpty else { return }
            guard !cameras.contains(where: { $0.serial == info.serialNumber }) else { return }

            let model = info.model.isEmpty ? "Atlas360" : info.model
            Log.info("discovery", "\(host) is \(model) \(info.serialNumber) — adopting it")
            adopt(DiscoveredCamera(serviceName: "\(model)@\(info.serialNumber)",
                                   host: host, port: 9989))
        } catch {
            probe.closeImmediately()
            await probe.disconnect()
            Log.warn("discovery", "\(host) answers on 9989 but would not say who it is: \(error)")
        }
    }

    /// Asks MediaMTX which of the four streams per camera are actually there.
    ///
    /// This is the only honest answer to "is it working yet": the camera reports
    /// success the moment it accepts the command, long before a packet arrives,
    /// and half a camera turning up is a real and common state — one SoC comes
    /// up, the other does not.
    private func pollStreams() async {
        guard let url = URL(string: "http://127.0.0.1:\(configuration.apiPort)/v3/paths/list?itemsPerPage=1000")
        else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return }

        var arriving: [Int: Int] = [:]
        for item in items {
            guard let name = item["name"] as? String,
                  item["ready"] as? Bool == true,
                  name.hasPrefix("cam"),
                  let slash = name.firstIndex(of: "/"),
                  let slot = Int(name[name.index(name.startIndex, offsetBy: 3)..<slash])
            else { continue }
            arriving[slot, default: 0] += 1
        }

        var changed = false
        for index in cameras.indices {
            let slot = cameras[index].slot
            // A path outlives the camera that fed it: MediaMTX holds a publisher
            // open until the read times out, two minutes after the power went.
            // Presence is the authority on whether the camera is there at all.
            let missing = (missedPresence[cameras[index].serial] ?? 0) >= 2
            let count = missing ? 0 : (arriving[slot] ?? 0)
            if cameras[index].lensesArriving != count {
                cameras[index].lensesArriving = count
                changed = true
            }

            // Starting is over the moment a picture turns up. Leaving the clock
            // running turns a camera that is on air into one that has been
            // "still waiting" for twenty-eight minutes.
            if count > 0 {
                startRequestedAt[slot] = nil
                startStep[slot] = nil
            }

            // Proof, written where the fleet sheet can find it.
            if count > (streamProven[slot] ?? 0) {
                streamProven[slot] = count
                let serial = cameras[index].serial
                let directory = recordsDirectory
                Task.detached(priority: .utility) {
                    CameraCheckout.noteStreamed(serial: serial, lenses: count, in: directory)
                }
            }
        }
        if changed { syncDesk() }
    }

    private func pollNodes() async {
        var refreshed: [Node] = []
        for configured in configuration.nodes {
            var node = Node(id: configured.id, host: configured.host,
                            cameras: configured.cameras)
            if let status = await fetchStatus(host: configured.host, port: configured.port) {
                node.online = true
                node.streamsArriving = status.streamsArriving
                node.streamsExpected = status.streamsExpected
                node.secondsRemaining = status.secondsRemaining
                node.writeBytesPerSecond = status.writeRate
                node.cpuPercent = status.cpu
                node.loadPerCore = status.loadPerCore
                node.proxyEncoder = status.encoder
            }
            refreshed.append(node)
        }
        nodes = refreshed
    }

    private struct NodeStatus {
        var streamsArriving = 0
        var streamsExpected = 0
        var secondsRemaining: Int?
        var writeRate = 0
        var cpu: Double?
        var loadPerCore: Double?
        var encoder: String?
    }

    private func fetchStatus(host: String, port: Int) async -> NodeStatus? {
        guard let url = URL(string: "http://\(host):\(port)/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var status = NodeStatus()
        if let disk = json["disk"] as? [String: Any] {
            status.streamsArriving = disk["streams_arriving"] as? Int ?? 0
            status.streamsExpected = disk["streams_expected"] as? Int ?? 0
            status.secondsRemaining = disk["seconds_remaining"] as? Int
            status.writeRate = disk["write_bytes_per_second"] as? Int ?? 0
        }
        if let machine = json["machine"] as? [String: Any] {
            status.cpu = machine["cpu_percent"] as? Double
            status.loadPerCore = machine["load_per_core"] as? Double
        }
        if let proxy = json["proxy"] as? [String: Any] {
            status.encoder = proxy["encoder"] as? String
        }
        return status
    }

    // MARK: - Derived

    var camerasStreaming: Int { cameras.filter(\.isStreaming).count }
    var nodesOnline: Int { nodes.filter(\.online).count }

    /// Whichever node runs out of disk first takes the whole show's headroom
    /// with it, so this is the figure worth showing.
    var shortestNodeSeconds: Int? {
        nodes.compactMap(\.secondsRemaining).min()
    }

    func camera(slot: Int?) -> Camera? {
        guard let slot else { return nil }
        return cameras.first { $0.slot == slot }
    }

    /// What a camera is doing — the only answer, used by every view.
    ///
    /// There used to be four sources for this: the control connection's state,
    /// whether Start had been pressed, how many lenses MediaMTX had, and whether
    /// the desk had attached it. Each view combined a different two or three, so
    /// they disagreed — a camera on air with a button offering to start it, a
    /// tile counting "still waiting" for half an hour beside a live picture.
    ///
    /// One function, one state, and the same `RigState` the rig check uses.
    func state(slot: Int?) -> RigState {
        guard let slot, let camera = camera(slot: slot) else { return .absent }

        if let fixing = fixingSince[slot] {
            return .beingFixed(sinceSeconds: Int(Date().timeIntervalSince(fixing)))
        }

        if camera.state == .busy { return .lockedOut }

        var seen = RigEvaluator.Observation()
        seen.serial = camera.serial
        seen.host = camera.host
        seen.onNetwork = camera.state != .disconnected
        seen.controlConnected = camera.state == .connected || camera.state == .streaming
        seen.lensesArriving = camera.lensesArriving
        if let started = startRequestedAt[slot] {
            seen.startRequestedSecondsAgo = Int(Date().timeIntervalSince(started))
        }

        let (positions, _) = RigEvaluator.evaluate(
            roster: Roster(entries: [Roster.Entry(number: slot)]),
            observations: [slot: seen])
        return positions.first?.state ?? .absent
    }

    /// Pictures are arriving, whoever asked for them.
    func isRunning(slot: Int) -> Bool {
        switch state(slot: slot) {
        case .ready, .partial: true
        case .starting:        true
        default:               false
        }
    }

    /// How long this camera has been starting, for the progress it is shown as.
    /// The step this camera is on, if it is starting.
    func startingStep(slot: Int?) -> String? {
        guard let slot else { return nil }
        return startStep[slot]
    }

    func startingSince(slot: Int?) -> Date? {
        guard let slot else { return nil }
        return startRequestedAt[slot]
    }

    func isStartRequested(slot: Int) -> Bool { startRequestedAt[slot] != nil }

    func setDelay(slot: Int, milliseconds: Double) {
        update(cameras.first { $0.slot == slot }?.serial ?? "") {
            $0.delayMilliseconds = milliseconds
        }
        switcher?.setDelay(slot: slot, seconds: milliseconds / 1000)
    }
}

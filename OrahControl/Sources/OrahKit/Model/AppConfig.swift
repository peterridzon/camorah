import Foundation

/// Persisted settings, stored in `~/Library/Application Support/4idesk/config.json`.
public struct AppConfig: Codable, Sendable, Equatable {

    // MARK: - MediaMTX (RTMP ingest on this Mac)

    public var mediaMTXHost: String = "127.0.0.1"
    public var rtmpPort: Int = 1935
    public var apiPort: Int = 9997
    public var hlsPort: Int = 8888

    /// Address the *cameras* publish to. They live on the LAN, so `127.0.0.1`
    /// is never right for them — this must be this Mac's LAN address.
    /// Empty means "detect the primary LAN address automatically".
    public var publishHost: String = ""

    /// Where `orahctl checkout` writes its camera records.
    ///
    /// It cannot be derived. The command line tool is run from the repository
    /// and writes beside it; the app is launched from Finder, whose working
    /// directory is `/`. So the folder is chosen once and remembered.
    public var cameraRecordsPath: String = ""

    /// Path to the MediaMTX binary. Empty means "look on PATH".
    public var mediaMTXBinary: String = ""

    // MARK: - OBS

    public struct OBSInstance: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var host: String = "127.0.0.1"
        public var port: Int
        /// The camera sub-stream this instance is responsible for (`0_0` … `1_1`).
        public var stream: String
        /// obs-websocket v5 password. Empty if authentication is disabled.
        public var password: String = ""

        public init(id: Int, host: String = "127.0.0.1", port: Int, stream: String, password: String = "") {
            self.id = id
            self.host = host
            self.port = port
            self.stream = stream
            self.password = password
        }
    }

    public var obsInstances: [OBSInstance] = [
        .init(id: 1, port: 4455, stream: "0_0"),
        .init(id: 2, port: 4456, stream: "0_1"),
        .init(id: 3, port: 4457, stream: "1_0"),
        .init(id: 4, port: 4458, stream: "1_1"),
    ]

    // MARK: - Intel recording nodes

    public struct NodeConfig: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var host: String
        public var port: Int = 8000
        /// Camera slots this node records. Assigned by the Mac, pushed to the agent.
        public var cameras: [Int] = []

        public init(id: Int, host: String, port: Int = 8000, cameras: [Int] = []) {
            self.id = id
            self.host = host
            self.port = port
            self.cameras = cameras
        }
    }

    public var nodes: [NodeConfig] = []

    // MARK: - Camera identity

    /// Maps a camera's stable identity (serial number, falling back to its
    /// Bonjour service name) to its slot number — the `NN` in `camNN`.
    ///
    /// This is the fix for the most damaging flaw in the original design, which
    /// numbered cameras by *discovery order*. Discovery order changes between
    /// runs, so `cam01` and `cam02` would silently swap: OBS scenes would show
    /// the wrong angle and yesterday's recordings would no longer match today's.
    /// Binding the slot to hardware identity makes the numbering reproducible.
    public var cameraSlots: [String: Int] = [:]

    /// Friendly labels per slot, e.g. 1 → "Stage left".
    public var cameraLabels: [String: String] = [:]

    /// Which camera sits under which key on the desk, by serial.
    ///
    /// A button number is not a camera number. On the desk you want them left
    /// to right in the order they stand on site, and that order has nothing to
    /// do with how the rig happens to be numbered. Keyed by serial for the same
    /// reason grades are: it has to survive a renumbering.
    public var buttonAssignments: [String: String] = [:]

    /// What a key reads: the camera's name, or its number.
    public var keyLegend: String = "name"

    /// The two free multiview boxes, four sources each, by serial.
    public var multiviewBoxes: [[String]] = [[], []]

    /// Colour correction, keyed by camera **serial** rather than by slot.
    ///
    /// A grade describes a physical camera — its sensor, its age, how it
    /// happens to expose — so it has to follow the unit when the rig is
    /// renumbered. Keying it by slot would silently hand one camera's
    /// correction to another the first time somebody reorders the desk.
    public var colourGrades: [String: ColourGrade] = [:]

    // MARK: - MIDI

    /// MIDI note number → camera slot. Replaces the old assumption note == slot.
    public var midiMapping: [String: Int] = [:]
    public var midiPortName: String = ""

    // MARK: - Behaviour

    /// Start recording automatically as soon as a camera begins streaming.
    public var autoStartRecording: Bool = false

    public init() {}
}

// MARK: - Store

/// Thread-safe accessor for the on-disk config.
public final class ConfigStore: @unchecked Sendable {

    public static let shared = ConfigStore()

    private let lock = NSLock()
    private var cached: AppConfig
    private let url: URL

    public init(url: URL? = nil) {
        let resolved = url ?? ConfigStore.defaultURL
        self.url = resolved
        self.cached = ConfigStore.load(from: resolved) ?? AppConfig()
    }

    public static var defaultURL: URL {
        AppPaths.support.appendingPathComponent("config.json")
    }

    public var config: AppConfig {
        get { lock.withLock { cached } }
        set {
            lock.withLock { cached = newValue }
            save()
        }
    }

    /// Read-modify-write under a single lock, so concurrent updates can't clobber
    /// each other — camera discovery and the settings UI both write here.
    @discardableResult
    public func mutate<T>(_ body: (inout AppConfig) -> T) -> T {
        let result: T = lock.withLock {
            body(&cached)
        }
        save()
        return result
    }

    private static func load(from url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func save() {
        let snapshot = lock.withLock { cached }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            Log.error("config", "could not save \(url.path): \(error.localizedDescription)")
        }
    }

    public var fileURL: URL { url }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

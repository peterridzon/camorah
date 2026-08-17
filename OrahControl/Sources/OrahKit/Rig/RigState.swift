import Foundation

/// What one position on the roster is doing, and what to do about it.
///
/// The states are ordered by how far a camera has got, because the useful thing
/// to show is **the first step that failed**. "Not ready" is not actionable;
/// "on the network but no control" sends someone to the right end of the cable.
public enum RigState: Equatable, Sendable {

    /// Nothing at this number: no Bonjour, nothing with Orah's MAC prefix.
    case absent

    /// Hardware answers, the control port does not. Usually still booting.
    case onNetwork

    /// Losing packets badly enough that nothing above it can be trusted.
    case linkFault(lossPercent: Double)

    /// Control answers, nobody has asked it to stream.
    case idle

    /// Asked to stream, nothing published yet.
    case starting(seconds: Int)

    /// Some lenses arriving, not all four. One SoC did not come up.
    case partial(lenses: Int)

    /// Four of four.
    case ready

    /// Somebody is working on it; nothing is being sent to it.
    case beingFixed(sinceSeconds: Int)

    /// Present and well, but holding a control session for a client that is
    /// gone. Only a power cycle clears it — retrying is futile.
    case lockedOut

    public var isReady: Bool { self == .ready }

    public var isWorking: Bool {
        switch self {
        case .onNetwork, .idle, .starting, .partial: true
        default: false
        }
    }

    public var isFault: Bool {
        switch self {
        case .absent, .linkFault, .lockedOut: true
        default: false
        }
    }

    /// The words that go on the tile.
    public var label: String {
        switch self {
        case .absent:                 "Not on the network"
        case .onNetwork:              "Still booting"
        case .linkFault(let loss):    String(format: "%.0f %% packets lost", loss)
        // Not a description but an instruction. A camera sitting connected and
        // idle is one button away from working, and "not streaming" does not
        // say that — it reads like a fault to be diagnosed rather than a step
        // to be taken.
        case .idle:                   "Ready — press Start"
        case .starting:               "Starting"
        case .partial(let lenses):    "\(lenses) of 4 lenses"
        case .ready:                  "Ready"
        case .beingFixed:             "Being worked on"
        case .lockedOut:              "Locked — power cycle it"
        }
    }

    /// The line under it — the number that decides what to do next.
    public func detail(roundTrip: Double?, lenses: Int) -> String {
        switch self {
        case .absent:
            return "—"
        case .onNetwork:
            return "control port not answering yet"
        case .linkFault:
            return "check its cable and switch port"
        case .idle:
            return roundTrip.map { String(format: "%.1f ms", $0) } ?? "control ok"
        case .starting(let seconds):
            return "\(seconds) s · no picture yet"
        case .partial:
            return "one SoC dark"
        case .ready:
            return roundTrip.map { String(format: "4/4 · %.1f ms", $0) } ?? "4/4"
        case .beingFixed(let seconds):
            return "not contacted · \(seconds / 60) min"
        case .lockedOut:
            return "holding a dead control session"
        }
    }
}

/// One position, evaluated.
public struct RigPosition: Identifiable, Sendable, Equatable {
    public let number: Int
    public let position: String
    public let nodeID: Int?
    public let serial: String?
    public var state: RigState
    public var lensesArriving: Int
    public var roundTripMilliseconds: Double?
    public var host: String?

    public var id: Int { number }

    public init(number: Int, position: String, nodeID: Int?, serial: String?,
                state: RigState, lensesArriving: Int = 0,
                roundTripMilliseconds: Double? = nil, host: String? = nil) {
        self.number = number
        self.position = position
        self.nodeID = nodeID
        self.serial = serial
        self.state = state
        self.lensesArriving = lensesArriving
        self.roundTripMilliseconds = roundTripMilliseconds
        self.host = host
    }
}

/// What the whole rig adds up to.
public struct RigSummary: Sendable, Equatable {
    public var expected = 0
    public var ready = 0
    public var working = 0
    public var absent = 0
    public var beingFixed = 0

    /// Nodes with every camera dark.
    ///
    /// This is the reason the screen groups by node at all. Four failures behind
    /// one node is one fault, and laid out by number they look like four broken
    /// cameras — which is an hour spent at the wrong end of the cable.
    public var darkNodes: [Int] = []

    public var isReady: Bool { expected > 0 && ready == expected }

    public var verdict: String {
        guard expected > 0 else { return "No roster" }
        if ready == expected { return "READY — all \(expected)" }
        return "NOT READY — \(expected - ready) to go"
    }
}

public enum RigEvaluator {

    /// Turns the roster plus what is known about each camera into positions.
    ///
    /// Deliberately takes plain values rather than reaching into the app: the
    /// evaluation is the part worth testing, and it should not need a camera to
    /// be plugged in to do it.
    public struct Observation: Sendable {
        public var serial: String?
        public var host: String?
        public var onNetwork = false
        public var controlConnected = false
        public var startRequestedSecondsAgo: Int?
        public var lensesArriving = 0
        public var packetLossPercent: Double?
        public var roundTripMilliseconds: Double?
        public var beingFixedSecondsAgo: Int?
        public var lockedOut = false

        public init() {}
    }

    public static func evaluate(roster: Roster,
                               observations: [Int: Observation]) -> ([RigPosition], RigSummary) {
        var positions: [RigPosition] = []

        for entry in roster.entries.sorted(by: { $0.number < $1.number }) {
            let seen = observations[entry.number] ?? Observation()
            positions.append(RigPosition(
                number: entry.number,
                position: entry.position,
                nodeID: entry.nodeID,
                serial: entry.serial ?? seen.serial,
                state: state(for: seen),
                lensesArriving: seen.lensesArriving,
                roundTripMilliseconds: seen.roundTripMilliseconds,
                host: seen.host))
        }

        var summary = RigSummary()
        summary.expected = positions.count
        for p in positions {
            switch p.state {
            case .ready:      summary.ready += 1
            case .beingFixed: summary.beingFixed += 1
            case .absent, .linkFault: summary.absent += 1
            default:          summary.working += 1
            }
        }

        // A node counts as dark only if it was expected to carry cameras and
        // every one of them is missing. One camera down is a camera; all of them
        // is the node.
        let grouped = Dictionary(grouping: positions.compactMap { p -> (Int, RigState)? in
            guard let node = p.nodeID else { return nil }
            return (node, p.state)
        }, by: \.0)
        summary.darkNodes = grouped
            .filter { $0.value.count > 1 && $0.value.allSatisfy { $0.1 == .absent } }
            .keys.sorted()

        return (positions, summary)
    }

    private static func state(for seen: Observation) -> RigState {
        if let fixing = seen.beingFixedSecondsAgo { return .beingFixed(sinceSeconds: fixing) }
        if seen.lockedOut { return .lockedOut }
        guard seen.onNetwork else { return .absent }

        // A bad link is reported before anything above it, because everything
        // above it reports nonsense over one.
        if let loss = seen.packetLossPercent, loss >= 5 { return .linkFault(lossPercent: loss) }

        if seen.lensesArriving >= 4 { return .ready }
        if seen.lensesArriving > 0 { return .partial(lenses: seen.lensesArriving) }
        guard seen.controlConnected else { return .onNetwork }
        if let started = seen.startRequestedSecondsAgo { return .starting(seconds: started) }
        return .idle
    }
}

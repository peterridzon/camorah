import Foundation

/// The rules about cameras that are worth being sure of.
///
/// These decisions were spread through the view model as conditions inside
/// loops, where the only way to know what they did was to plug a camera in and
/// watch. Each one has cost a real failure: a knock every ten seconds all
/// evening at a camera that was trying to boot, a tile that said "not on the
/// network" over a live picture, a reader relaunching a process every second.
///
/// They are functions now, with the failures as tests. See
/// `docs/ARCHITECTURE.md`, parts 1 and 3.
public enum FleetPolicy {

    /// How long to leave a camera alone between attempts to open a session.
    ///
    /// Ten seconds is right for a camera that was just plugged in and wrong for
    /// one that has refused twenty times — that is traffic at a unit that may be
    /// mid-boot, and a log nobody can read.
    public static func knockFloor(attempts: Int) -> TimeInterval {
        attempts < 3 ? 10 : attempts < 10 ? 30 : 60
    }

    /// Whether to knock at all.
    ///
    /// `busy` means somebody already holds the camera's one control session.
    /// Knocking cannot help, and knocking in a loop turns a locked-out camera
    /// into a locked-out camera with a flickering status.
    public static func shouldKnock(isBusy: Bool,
                                   isConnectedOrConnecting: Bool,
                                   attemptInFlight: Bool) -> Bool {
        !isBusy && !isConnectedOrConnecting && !attemptInFlight
    }

    /// What a missed ping means.
    public enum Presence: Equatable {
        /// Still here — either it answered, or its pictures are arriving.
        case here
        /// Quiet, but not written off. The desk stops claiming a connection at
        /// two misses.
        case quiet(misses: Int)
        /// Off the list. Its place in the roster is kept; the camera is not.
        case gone
    }

    /// - Parameters:
    ///   - answered: whether the camera replied to this round of pings.
    ///   - lensesReady: how many of its lenses are publishing right now.
    ///   - misses: how many rounds it had already missed.
    ///
    /// A camera whose pictures are arriving is on the network whatever a ping
    /// says. Frames are proof; a dropped packet is an opinion — and the opinion
    /// used to win, which is how the desk drew a live tile with "not on the
    /// network" across it.
    public static func presence(answered: Bool,
                                lensesReady: Int,
                                misses: Int) -> Presence {
        if answered || lensesReady > 0 { return .here }
        let now = misses + 1
        return now >= 5 ? .gone : .quiet(misses: now)
    }

    /// Whether a camera at `misses` should still be shown as connected.
    public static func stillClaimsConnection(misses: Int) -> Bool { misses < 2 }
}

/// How hard to try to read a stream that is not there yet.
public enum ReaderPolicy {

    /// Quick at first — a camera takes about fifteen seconds from Start to its
    /// first packet, and the picture should appear the moment it does. Then
    /// slow, because a retry that never slows down is a spin loop wearing a
    /// costume: a dozen of them flooded MediaMTX and made the desk lag.
    public static func retryDelay(attempt: Int) -> TimeInterval {
        attempt <= 10 ? 1.5 : attempt <= 20 ? 4 : 10
    }

    /// Whether this attempt is worth a line in the log. One a second for the
    /// rest of a show is not.
    public static func shouldLog(attempt: Int) -> Bool {
        attempt == 1 || attempt % 15 == 0
    }
}

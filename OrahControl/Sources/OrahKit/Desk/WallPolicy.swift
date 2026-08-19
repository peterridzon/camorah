import Foundation

/// What belongs on the multiview wall, and what a camera's own key should say.
///
/// The wall is the thing an operator looks at to find a shot. A camera that is
/// half up, refusing to start, or holding a dead session is not a shot — it is
/// a job for the rig check, and putting it among the good ones costs a second
/// of confusion every time the eye passes over it. Worse, it looks exactly like
/// a camera you could cut to.
///
/// See `docs/ARCHITECTURE.md`, part 3.
public enum WallPolicy {

    /// What a camera is doing, as far as the wall is concerned.
    public enum Standing: Equatable {
        /// Up, all four lenses.
        case live
        /// Sending pictures, but not all four. A camera you can cut to — three
        /// lanes of four is a degraded shot, and a degraded shot beats black.
        case partial
        /// Nothing wrong; simply not started. Its key says START.
        case idle
        /// On its way up, inside the window a camera is allowed.
        case starting
        /// No pictures at all: refused to start, off the network, or holding a
        /// dead session. This is the only thing a key must refuse.
        case fault
    }

    /// How long a camera is allowed to take before a partial start is a fault.
    ///
    /// Measured on the bench: about fifteen seconds from the command to the
    /// first packet, twenty until all four streams are up. Thirty is that with
    /// room, and past it a camera that is still short of a lens is not slow,
    /// it is broken.
    public static let startupWindow: TimeInterval = 30

    /// - Parameters:
    ///   - onNetwork: whether the camera answers at all.
    ///   - lockedOut: whether it is holding a control session it will not give up.
    ///   - lensesReady: how many of its four streams are publishing.
    ///   - startRequestedSecondsAgo: how long ago Start was pressed, if it was.
    public static func standing(onNetwork: Bool,
                                lockedOut: Bool,
                                lensesReady: Int,
                                startRequestedSecondsAgo: TimeInterval?) -> Standing {
        // Pictures beat every other opinion, and they are checked first.
        //
        // A camera sending all four streams is a camera you can cut to, whatever
        // the control session thinks. These sessions drop on their own — a
        // reconnect, a reboot of the desk, a socket nobody closed — and the
        // camera goes on publishing throughout. Judging it by the session put
        // two perfectly good cameras in the rig check under "not on the
        // network" with four lit lenses underneath, which is the desk arguing
        // with itself in front of the operator.
        if lensesReady >= 4 { return .live }
        if lensesReady == 0, !onNetwork || lockedOut { return .fault }

        guard let since = startRequestedSecondsAgo else {
            // Never asked to start. Half a camera nobody started is odd, but it
            // is a picture, and a picture is worth having.
            return lensesReady == 0 ? .idle : .partial
        }
        if since <= startupWindow { return lensesReady == 0 ? .starting : .partial }
        return lensesReady == 0 ? .fault : .partial
    }

    /// Every camera is drawn on the multiview. Including the broken ones.
    ///
    /// This was the other way round for an afternoon — a fault was taken off
    /// the wall and left to the rig check — and that is wrong for the screen an
    /// operator actually watches. A camera that drops out mid-show is exactly
    /// what they need to see, and a tile that quietly disappears tells them
    /// nothing: they find out when they reach for it.
    ///
    /// So the wall shows everything and says what is wrong on the tile. What
    /// protects the programme is not hiding the camera, it is the key: a fault
    /// cannot be cut to, and its key on the desk is dark.
    public static func belongsOnWall(_ standing: Standing) -> Bool { true }

    /// Whether this camera may be cut to.
    ///
    /// **The test is whether there is a picture, not whether it is perfect.**
    /// This was `.live` only for an hour, and that hour was one in which a
    /// camera missing a single lens could not be cut to at all — the desk
    /// refusing a shot the operator could plainly see on the wall. Three lanes
    /// of four is a degraded shot; black is not a shot. The key exists to stop
    /// the second one.
    public static func canGoToAir(_ standing: Standing) -> Bool {
        standing == .live || standing == .partial
    }

    /// Every camera gets a key, working or not.
    ///
    /// Keys must not move. A hand that has learnt where camera 12 is must find
    /// it there when camera 10 dies, and find it there again when camera 10
    /// comes back — so a fault keeps its position and goes dark rather than
    /// letting everything after it shuffle up one.
    public static func deservesAKey(_ standing: Standing) -> Bool { true }

    /// What the camera's own key should read.
    public enum Key: Equatable {
        case start
        case starting
        case stop
    }

    public static func key(for standing: Standing) -> Key {
        switch standing {
        case .idle:     .start
        case .starting: .starting
        case .live, .partial: .stop
        // A fault is not on the wall, but the rig check shows the same key and
        // there the answer is to try again.
        case .fault:    .start
        }
    }
}

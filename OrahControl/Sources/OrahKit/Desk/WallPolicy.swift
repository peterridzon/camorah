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
        /// Up, all four lenses, ready to be cut to.
        case live
        /// Nothing wrong; simply not started. Its key says START.
        case idle
        /// On its way up, inside the window a camera is allowed.
        case starting
        /// Something is wrong: refused to start, came up half, locked out, or
        /// off the network. Belongs in the rig check, not on the wall.
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
        if !onNetwork || lockedOut { return .fault }
        if lensesReady >= 4 { return .live }

        guard let since = startRequestedSecondsAgo else {
            // Never asked to start. Half a camera nobody started is still a
            // fault — something is publishing that should not be.
            return lensesReady == 0 ? .idle : .fault
        }
        return since <= startupWindow ? .starting : .fault
    }

    /// Whether this camera is drawn on the multiview.
    ///
    /// A camera that has not been started yet stays: its tile is where Start
    /// is pressed. A camera that is starting stays: watching it come up is the
    /// point of the tile. A fault goes — to the rig check, which says what is
    /// wrong with it and offers to fix it.
    public static func belongsOnWall(_ standing: Standing) -> Bool {
        standing != .fault
    }

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
        case .live:     .stop
        // A fault is not on the wall, but the rig check shows the same key and
        // there the answer is to try again.
        case .fault:    .start
        }
    }
}

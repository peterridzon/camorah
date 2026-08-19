import Foundation

/// What the wall shows, and what a camera's key says, as checks.
public enum WallPolicySelfTest {

    public static func run() -> ProtoSelfTest.Result {
        var r = ProtoSelfTest.Result()

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { r.passed.append(name) }
            else { r.failed.append((name, detail())) }
        }

        func standing(_ onNetwork: Bool, _ locked: Bool, _ lenses: Int,
                      _ since: TimeInterval?) -> WallPolicy.Standing {
            WallPolicy.standing(onNetwork: onNetwork, lockedOut: locked,
                                lensesReady: lenses, startRequestedSecondsAgo: since)
        }

        // The whole camera, up: this is a shot.
        check("four lenses is live", standing(true, false, 4, 12) == .live)

        // Not started is not broken. Its tile is where Start lives.
        check("a camera nobody started is idle", standing(true, false, 0, nil) == .idle)
        check("an idle camera stays on the wall",
              WallPolicy.belongsOnWall(standing(true, false, 0, nil)))
        check("its key says START",
              WallPolicy.key(for: standing(true, false, 0, nil)) == .start)

        // Coming up. Watching it happen is the point of the tile — and the key
        // must say so, because a key that still reads START next to a camera
        // that is plainly starting is a key that lies.
        check("inside the window it is starting", standing(true, false, 2, 8) == .starting)
        check("a starting camera stays on the wall",
              WallPolicy.belongsOnWall(standing(true, false, 2, 8)))
        check("its key says STARTING",
              WallPolicy.key(for: standing(true, false, 2, 8)) == .starting)

        // Past the window and still short: not slow, broken.
        check("half a camera past the window is a fault", standing(true, false, 2, 45) == .fault)
        check("three of four is a fault too", standing(true, false, 3, 45) == .fault)
        // The wall shows it — that is the screen an operator watches, and a
        // camera that vanishes quietly is one they find out about by reaching
        // for it. What protects the programme is the key, not the hiding.
        check("a fault is still on the wall",
              WallPolicy.belongsOnWall(standing(true, false, 3, 45)))
        check("but it cannot be cut to",
              !WallPolicy.canGoToAir(standing(true, false, 3, 45)))
        check("and it keeps its key, dark",
              WallPolicy.deservesAKey(standing(true, false, 3, 45)))
        check("a camera coming up cannot be cut to either",
              !WallPolicy.canGoToAir(standing(true, false, 2, 8)))
        check("a whole camera can",
              WallPolicy.canGoToAir(standing(true, false, 4, 8)))

        // Nothing at all, long after Start was pressed.
        check("a camera that sent nothing is a fault", standing(true, false, 0, 60) == .fault)

        // Held session and off the network are faults whatever else is true.
        // Pictures outrank the control session and the ping alike. Both of
        // these drew a camera as gone with four lit lenses under it.
        check("four streams beat a lost control session",
              standing(false, false, 4, 10) == .live)
        check("four streams beat a locked session too",
              standing(true, true, 4, 10) == .live)
        check("but a locked camera with no pictures is a fault",
              standing(true, true, 0, 10) == .fault)
        check("and so is one that is off the network with none",
              standing(false, false, 0, 10) == .fault)

        // Streams arriving that nobody asked for, and not all of them: that is
        // a camera left half-running by something else, and it is a fault.
        check("half a camera nobody started is a fault", standing(true, false, 2, nil) == .fault)

        // A camera that came up whole on its own — after a power cut, say — is
        // live, not a fault. These cameras resume streaming without being asked.
        check("a camera that came up whole on its own is live",
              standing(true, false, 4, nil) == .live)
        check("its key offers STOP",
              WallPolicy.key(for: standing(true, false, 4, nil)) == .stop)

        // The boundary itself, both sides of it.
        check("at the window it is still starting",
              standing(true, false, 1, WallPolicy.startupWindow) == .starting)
        check("a second past it, it is not",
              standing(true, false, 1, WallPolicy.startupWindow + 1) == .fault)

        return r
    }
}

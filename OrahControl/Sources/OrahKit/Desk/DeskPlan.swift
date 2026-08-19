import Foundation

/// What the desk should be decoding, worked out from what exists.
///
/// This is the part of the desk that broke every other part when it was written
/// inline: it was a hundred lines in the middle of a view model, it read from
/// four places, and every change to a window changed it by accident. It is a
/// pure function now — fleet and streams in, a plan out — so it can be tested
/// against the failures it is there to prevent, and so nothing that draws a
/// picture can quietly alter it.
///
/// See `docs/ARCHITECTURE.md`, part 3.
public struct DeskPlan: Equatable, Sendable {

    /// Camera slot → the lenses to decode for it. A slot that is absent is not
    /// decoded at all.
    public var sources: [Int: [Int]]

    public init(sources: [Int: [Int]] = [:]) {
        self.sources = sources
    }

    public func lenses(for slot: Int) -> [Int] { sources[slot] ?? [] }
}

public enum DeskPlanner {

    /// Every lens a camera has. Four streams, two boards.
    public static let lensesPerCamera = 4

    /// Whether a camera may appear on the buses at all.
    ///
    /// **A camera that has not come up completely is not in the switching feed.**
    /// It belongs in setup, where it can be seen and fixed. Half a camera on a
    /// programme key is a key that gives you half a camera — in front of an
    /// audience, with no warning, because the tile looked like all the others.
    ///
    /// Two SoCs, four streams: three of four is a fault, not a camera.
    public static func isReadyForAir(lenses: Set<Int>) -> Bool {
        lenses.count == lensesPerCamera
    }

    /// - Parameters:
    ///   - ready: which lenses are actually publishing, per camera. Not what a
    ///     camera claims — what MediaMTX has.
    ///   - program: the slot on air, if any.
    ///   - preview: the slot cued next, if any.
    ///   - tileLens: which lens each camera's thumbnail is set to.
    ///   - budget: how many cameras may be decoded at once.
    public static func plan(ready: [Int: Set<Int>],
                            program: Int?,
                            preview: Int?,
                            tileLens: [Int: Int] = [:],
                            budget: Int) -> DeskPlan {

        // Rule: only what is on the wire. A reader attached to a lens nobody is
        // publishing to relaunches a process for ever.
        //
        // Whole or not. A camera with three of its four streams is a shot with
        // a hole in it, and the desk's job is to show it — the operator decides
        // whether to use it. Refusing to decode it meant its tile was black and
        // its key dead, which is the desk hiding a picture that exists.
        let live = ready.filter { !$0.value.isEmpty }
        var sources: [Int: [Int]] = [:]

        // Rule: the desk pair decodes every lens it has, because the mix sends
        // four lanes out. "Every lens it has" and not "all four" — half a camera
        // is a normal state, and the missing half must not be waited on.
        for slot in [program, preview].compactMap({ $0 }) {
            guard let lenses = live[slot] else { continue }
            sources[slot] = lenses.sorted()
        }

        // Rule: everybody else is one decode. The lens its tile is set to, or —
        // if that half of the camera never came up — the first lens that exists,
        // so a tile shows a picture rather than a black rectangle with a number
        // on it.
        for slot in live.keys.sorted() where sources[slot] == nil {
            guard sources.count < budget else { break }
            let lenses = live[slot]!
            let chosen = tileLens[slot] ?? 0
            sources[slot] = [lenses.contains(chosen) ? chosen : lenses.sorted()[0]]
        }

        return DeskPlan(sources: sources)
    }
}

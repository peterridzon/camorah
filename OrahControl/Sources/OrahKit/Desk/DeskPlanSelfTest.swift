import Foundation

/// The rules of `docs/ARCHITECTURE.md` part 3, as checks.
///
/// Every case below is a failure that actually happened on 18 August 2026, and
/// each one took a working part of the desk down with it. This is the way back:
/// change the planner, run `orahctl selftest`, and know within a second whether
/// the evening is about to repeat itself.
///
/// In the library rather than a test target because this machine has only
/// Command Line Tools, where XCTest is unavailable — same reason as
/// `ProtoSelfTest`.
public enum DeskPlanSelfTest {

    public static func run() -> ProtoSelfTest.Result {
        var r = ProtoSelfTest.Result()

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { r.passed.append(name) }
            else { r.failed.append((name, detail())) }
        }

        // A camera that is on the network but publishing nothing must not be
        // decoded. This is the one that spawned an ffmpeg process per second per
        // lens until the buttons lagged.
        do {
            let plan = DeskPlanner.plan(ready: [7: []], program: 7, preview: nil, budget: 12)
            check("silent camera is not decoded", plan.sources.isEmpty,
                  "got \(plan.sources)")
        }

        // Half a camera is still a picture, and a picture belongs on the wall.
        // Refusing to decode it left the operator looking at a black tile for a
        // camera that was plainly sending something.
        do {
            let plan = DeskPlanner.plan(ready: [8: [2, 3]], program: nil, preview: nil,
                                        budget: 12)
            check("half a camera is decoded", plan.lenses(for: 8) == [2],
                  "got \(plan.lenses(for: 8))")
        }

        // And on the desk it gets every lens it has.
        do {
            let plan = DeskPlanner.plan(ready: [8: [0, 1, 2]], program: 8, preview: nil,
                                        budget: 12)
            check("three of four on air decodes three", plan.lenses(for: 8) == [0, 1, 2],
                  "got \(plan.lenses(for: 8))")
        }

        // But a camera already on air is not dropped because it lost a lens.
        // Taking the programme off the air is worse than the fault.
        do {
            let plan = DeskPlanner.plan(ready: [8: [0, 1, 2]], program: 8, preview: nil,
                                        budget: 12)
            check("a camera on air survives losing a lens",
                  plan.lenses(for: 8) == [0, 1, 2], "got \(plan.lenses(for: 8))")
        }

        // Programme and preview cost four decodes; everybody else costs one.
        do {
            let ready: [Int: Set<Int>] = [1: [0, 1, 2, 3], 2: [0, 1, 2, 3], 3: [0, 1, 2, 3]]
            let plan = DeskPlanner.plan(ready: ready, program: 1, preview: 2, budget: 12)
            check("desk pair decodes every lens",
                  plan.lenses(for: 1) == [0, 1, 2, 3] && plan.lenses(for: 2) == [0, 1, 2, 3])
            check("a thumbnail is one decode", plan.lenses(for: 3).count == 1,
                  "got \(plan.lenses(for: 3))")
        }

        // A camera on air whose tile is set to a lens it has lost shows one it
        // still has, rather than a black rectangle with a number on it.
        do {
            let plan = DeskPlanner.plan(ready: [5: [2, 3]], program: 5, preview: nil,
                                        tileLens: [5: 0], budget: 12)
            check("a lost lens falls back to one that exists",
                  plan.lenses(for: 5) == [2, 3], "got \(plan.lenses(for: 5))")
        }

        // And when the chosen lens does exist, it is the one decoded — this is
        // what makes the 1–4 keys on a tile mean anything.
        do {
            let plan = DeskPlanner.plan(ready: [5: [0, 1, 2, 3]], program: nil, preview: nil,
                                        tileLens: [5: 2], budget: 12)
            check("thumbnail decodes the lens it is set to",
                  plan.lenses(for: 5) == [2], "got \(plan.lenses(for: 5))")
        }

        // The budget is a ceiling on cameras, and the desk pair is never
        // squeezed out of it by thumbnails.
        do {
            var ready: [Int: Set<Int>] = [:]
            for slot in 1...24 { ready[slot] = [0, 1, 2, 3] }
            let plan = DeskPlanner.plan(ready: ready, program: 20, preview: 21, budget: 6)
            check("budget is respected", plan.sources.count == 6, "got \(plan.sources.count)")
            check("the desk pair is always in the plan",
                  plan.lenses(for: 20).count == 4 && plan.lenses(for: 21).count == 4)
        }

        // Nothing on air is not nothing to decode: the wall still has to show
        // what is there, or the desk goes black exactly when somebody is trying
        // to find a shot.
        do {
            let plan = DeskPlanner.plan(ready: [4: [0, 1, 2, 3]], program: nil, preview: nil,
                                        budget: 12)
            check("no programme still decodes the wall", plan.lenses(for: 4) == [0],
                  "got \(plan.lenses(for: 4))")
        }

        // What "ready for air" means, on its own.
        do {
            check("four lenses is ready", DeskPlanner.isReadyForAir(lenses: [0, 1, 2, 3]))
            check("three is not", !DeskPlanner.isReadyForAir(lenses: [0, 1, 2]))
            check("none is not", !DeskPlanner.isReadyForAir(lenses: []))
        }

        // The same inputs must give the same plan, or the desk rebuilds sources
        // it already has — which is a black picture for three seconds, every
        // time the planner is asked.
        do {
            let ready: [Int: Set<Int>] = [1: [0, 1, 2, 3], 2: [1], 3: [0, 2]]
            let a = DeskPlanner.plan(ready: ready, program: 1, preview: 2,
                                     tileLens: [3: 2], budget: 12)
            let b = DeskPlanner.plan(ready: ready, program: 1, preview: 2,
                                     tileLens: [3: 2], budget: 12)
            check("the plan is stable", a == b)
        }

        return r
    }
}

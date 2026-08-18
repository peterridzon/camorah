import Foundation

/// The fleet and reader rules, as checks.
public enum FleetPolicySelfTest {

    public static func run() -> ProtoSelfTest.Result {
        var r = ProtoSelfTest.Result()

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { r.passed.append(name) }
            else { r.failed.append((name, detail())) }
        }

        // Knocking

        check("a camera just plugged in is knocked promptly",
              FleetPolicy.knockFloor(attempts: 0) == 10)
        check("the interval grows",
              FleetPolicy.knockFloor(attempts: 5) == 30
              && FleetPolicy.knockFloor(attempts: 20) == 60)
        check("the interval never shrinks with more attempts",
              (0..<40).map(FleetPolicy.knockFloor(attempts:))
                  .adjacentPairs().allSatisfy { $0 <= $1 })

        // A camera holding a dead session refuses every knock, and knocking in a
        // loop is how a locked-out camera gets a flickering status as well.
        check("a busy camera is never knocked",
              !FleetPolicy.shouldKnock(isBusy: true, isConnectedOrConnecting: false,
                                       attemptInFlight: false))
        check("a connected camera is not knocked",
              !FleetPolicy.shouldKnock(isBusy: false, isConnectedOrConnecting: true,
                                       attemptInFlight: false))
        check("one attempt at a time",
              !FleetPolicy.shouldKnock(isBusy: false, isConnectedOrConnecting: false,
                                       attemptInFlight: true))
        check("a stranded camera is knocked",
              FleetPolicy.shouldKnock(isBusy: false, isConnectedOrConnecting: false,
                                      attemptInFlight: false))

        // Presence

        check("an answer is presence",
              FleetPolicy.presence(answered: true, lensesReady: 0, misses: 4) == .here)

        // The one that drew "not on the network" across a live picture.
        check("pictures are presence, whatever the ping says",
              FleetPolicy.presence(answered: false, lensesReady: 1, misses: 4) == .here)

        check("silence counts up",
              FleetPolicy.presence(answered: false, lensesReady: 0, misses: 0)
                  == .quiet(misses: 1))
        check("five misses and it is off the list",
              FleetPolicy.presence(answered: false, lensesReady: 0, misses: 4) == .gone)
        check("one lost packet does not evict a working camera",
              FleetPolicy.presence(answered: false, lensesReady: 0, misses: 0) != .gone)
        check("the desk stops claiming a connection at two misses",
              FleetPolicy.stillClaimsConnection(misses: 1)
              && !FleetPolicy.stillClaimsConnection(misses: 2))

        // Reading

        check("a camera being started is retried quickly",
              ReaderPolicy.retryDelay(attempt: 1) == 1.5)
        check("a stream nobody is publishing backs off",
              ReaderPolicy.retryDelay(attempt: 30) == 10)
        check("the delay never shrinks",
              (1...40).map(ReaderPolicy.retryDelay(attempt:))
                  .adjacentPairs().allSatisfy { $0 <= $1 })

        // Fifteen seconds of retries must not cost fifteen log lines, but the
        // first one has to be there or a silent camera is silent twice.
        check("the first attempt is logged", ReaderPolicy.shouldLog(attempt: 1))
        check("attempts are not logged one a second",
              !ReaderPolicy.shouldLog(attempt: 2) && !ReaderPolicy.shouldLog(attempt: 7))

        // Ten minutes of a camera that never comes up, in log lines. This is the
        // check that would have caught the flood: at one line a second it is 600.
        let tenMinutes = (1...200).filter(ReaderPolicy.shouldLog(attempt:)).count
        check("a camera that never comes up stays quiet in the log", tenMinutes < 20,
              "got \(tenMinutes) lines")

        return r
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count > 1 else { return [] }
        return (0..<(count - 1)).map { (self[$0], self[$0 + 1]) }
    }
}

import Foundation

/// The splitter's rules, as checks — including the one that span a core.
///
/// Every case here is cheap and synthetic: no camera, no process, no network.
/// That is the point. This loop runs over every byte of every lens of every
/// camera, and it must be provable at a desk rather than discovered in a
/// gallery.
public enum AccessUnitSelfTest {

    private static func nal(_ type: UInt8, length: Int = 8, fourByte: Bool = false) -> Data {
        var d = Data(fourByte ? [0, 0, 0, 1] : [0, 0, 1])
        d.append(type & 0x1F)
        d.append(Data(repeating: 0x42, count: length))
        return d
    }

    public static func run() -> ProtoSelfTest.Result {
        var r = ProtoSelfTest.Result()

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { r.passed.append(name) }
            else { r.failed.append((name, detail())) }
        }

        // Two pictures in, one access unit out: the second picture ends the
        // first, and the second is still being assembled.
        do {
            var s = AccessUnitSplitter()
            let units = s.push(nal(5) + nal(1))
            check("a picture ends the one before it", units.count == 1, "got \(units.count)")
        }

        // A four-byte start code at the very front. This is the case that found
        // itself again at offset zero, removed nothing, and span the reader at
        // eight hundred percent of a core with not one frame decoded.
        do {
            var s = AccessUnitSplitter()
            let units = s.push(nal(5, fourByte: true) + nal(1, fourByte: true)
                               + nal(1, fourByte: true))
            check("four-byte start codes terminate", units.count == 2, "got \(units.count)")
        }

        // Parameter sets belong to the picture that follows them.
        do {
            var s = AccessUnitSplitter()
            let units = s.push(nal(7) + nal(8) + nal(5) + nal(1))
            check("SPS and PPS join the next picture", units.count == 1, "got \(units.count)")
            if let first = units.first {
                check("the access unit carries its parameter sets",
                      first.count == nal(7).count + nal(8).count + nal(5).count,
                      "got \(first.count) bytes")
            }
        }

        // The pipe does not deliver whole NALs. It delivers whatever it has.
        do {
            var s = AccessUnitSplitter()
            let stream = nal(5) + nal(1) + nal(1)
            var units: [Data] = []
            for byte in stream { units += s.push(Data([byte])) }
            check("a stream split into single bytes still splits", units.count == 2,
                  "got \(units.count)")
        }

        // Leading rubbish before the first start code is dropped, not decoded.
        do {
            var s = AccessUnitSplitter()
            let units = s.push(Data([0xAA, 0xBB, 0xCC]) + nal(5) + nal(1))
            check("rubbish before the first start code is dropped", units.count == 1,
                  "got \(units.count)")
        }

        // A start code split across two chunks — the three zero bytes arrive in
        // one delivery and the one in the next.
        do {
            var s = AccessUnitSplitter()
            var units = s.push(nal(5))
            units += s.push(Data([0, 0]))
            units += s.push(Data([1, 1]) + Data(repeating: 0x42, count: 8))
            check("a start code split across chunks is still found", units.count == 1,
                  "got \(units.count)")
        }

        // Nothing but zeros is not a start code, and must not accumulate for
        // ever either.
        do {
            var s = AccessUnitSplitter()
            let units = s.push(Data(repeating: 0, count: 4096))
            check("zeros produce nothing", units.isEmpty, "got \(units.count)")
        }

        // Reset means reset: no half an access unit survives a reconnect, or the
        // decoder is handed a picture with somebody else's parameter sets.
        do {
            var s = AccessUnitSplitter()
            _ = s.push(nal(7) + nal(5))
            s.reset()
            let units = s.push(nal(5) + nal(1))
            check("reset drops a half-built unit", units.count == 1, "got \(units.count)")
        }

        return r
    }
}

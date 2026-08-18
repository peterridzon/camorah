import Foundation

/// Cuts a byte stream of Annex-B into access units.
///
/// This is the hottest loop in the whole desk — every lens of every camera runs
/// it over its full bitrate — and it lived inside the stream reader, tangled up
/// with a process, a pipe and a decoder, where it could not be tested. It cost
/// the evening twice: once as a version that copied the entire pending buffer
/// into a Swift array and rescanned it from the start on every chunk from the
/// pipe, and once as a rewrite of that which found its own start code again at
/// offset zero and span at eight hundred percent of a core.
///
/// So it is its own part now, with its own rules and its own way back —
/// `orahctl selftest`. See `docs/ARCHITECTURE.md`, part 3.
///
/// **Rules**
///
/// 1. A byte is searched once. `scanned` remembers how far the search got; a
///    chunk arriving from the pipe searches only what it added.
/// 2. The buffer always begins at a start code once aligned, and the search for
///    the *next* one begins past it — never at zero, which finds the same code
///    for ever.
/// 3. The search is `memchr`, which the machine vectorises, not a Swift loop
///    over one byte at a time.
/// 4. Nothing is copied to find a boundary. The only copy is the access unit
///    handed out, which the decoder needs anyway.
public struct AccessUnitSplitter {

    /// Bytes not yet formed into an access unit.
    private var pending = Data()
    /// True once the front of `pending` is known to be a start code.
    private var aligned = false
    /// How much of `pending` has been searched for the next start code.
    private var scanned = 0

    /// The access unit being assembled, and whether it already holds a picture.
    private var current = Data()
    private var currentHasPicture = false

    public init() {}

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
        aligned = false
        scanned = 0
        currentHasPicture = false
    }

    /// Feeds bytes in, gets whole access units out.
    ///
    /// An access unit is complete when the next picture NAL *begins* — not when
    /// it finishes. That distinction is a frame of delay: waiting for the next
    /// picture to be whole means every picture reaches the decoder one picture
    /// late, all the way down the desk, for nothing. Its type is in the first
    /// byte after the start code, and that is all the question needs.
    ///
    /// Parameter sets and SEI belong to the picture that follows them, not to
    /// the one before.
    public mutating func push(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var finished: [Data] = []

        if !aligned {
            guard let first = startCode(from: 0) else {
                // Keep only what could still be the front of a start code.
                if pending.count > 3 { pending.removeSubrange(0..<(pending.count - 3)) }
                return []
            }
            if first.offset > 0 { pending.removeSubrange(0..<first.offset) }
            aligned = true
            scanned = 4
        }

        while let front = frontNAL() {
            // A new picture closes whatever was being assembled.
            if front.isPicture && currentHasPicture {
                if !current.isEmpty { finished.append(current) }
                current = Data()
                currentHasPicture = false
            }

            // Whole, though? The NAL runs to the next start code.
            guard let next = startCode(from: max(scanned, 4)) else {
                scanned = max(4, pending.count - 3)
                break
            }

            current.append(pending.prefix(next.offset))
            if front.isPicture { currentHasPicture = true }
            pending.removeSubrange(0..<next.offset)
            scanned = 4
        }

        return finished
    }

    /// The type of the NAL at the front, as soon as its header byte has landed.
    private func frontNAL() -> (type: UInt8, isPicture: Bool)? {
        guard pending.count > 3 else { return nil }
        let base = pending.startIndex
        let codeLength = pending[base + 2] == 1 ? 3 : 4
        guard pending.count > codeLength else { return nil }
        let type = pending[base + codeLength] & 0x1F
        return (type, (1...5).contains(type))
    }

    private func startCode(from index: Int) -> (offset: Int, length: Int)? {
        pending.withUnsafeBytes { raw -> (offset: Int, length: Int)? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let count = raw.count
            var i = max(index, 2)
            while i < count {
                guard let hit = memchr(base + i, 0x01, count - i) else { return nil }
                let at = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                if at >= 2, base[at - 1] == 0, base[at - 2] == 0 {
                    let four = at >= 3 && base[at - 3] == 0
                    return (four ? at - 3 : at - 2, four ? 4 : 3)
                }
                i = at + 1
            }
            return nil
        }
    }
}

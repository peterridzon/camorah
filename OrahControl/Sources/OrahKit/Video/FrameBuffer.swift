import Foundation
import CoreMedia
import CoreVideo

/// A short rolling history of decoded frames from one stream.
///
/// Two jobs. First, it decouples input from output: frames arrive whenever the
/// network delivers them, while the output pump runs on a fixed clock, and
/// something has to sit in between. Second, it is where per-camera delay lives —
/// asking for a frame "as of 40 ms ago" is just a lookup into this history,
/// which is why delay costs nothing beyond the memory already being held.
public final class FrameBuffer: @unchecked Sendable {

    public struct Entry {
        public let pixelBuffer: CVPixelBuffer
        public let pts: CMTime
        public let receivedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let clock = ContinuousClock()

    /// How much history to keep. Bounds memory: at 1920×1440 NV12 a frame is
    /// about 4 MB, so a second of history per stream is roughly 125 MB across
    /// eight streams — enough for any plausible delay, not enough to matter.
    public let capacity: Int

    /// Delay applied to this source, in seconds. Positive holds the stream back.
    public var delaySeconds: Double = 0

    public private(set) var framesReceived = 0
    public private(set) var framesDropped = 0

    public init(capacity: Int = 40) {
        self.capacity = capacity
    }

    public func append(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.withLock {
            entries.append(Entry(pixelBuffer: pixelBuffer, pts: pts, receivedAt: clock.now))
            framesReceived += 1
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
                framesDropped += 1
            }
        }
    }

    /// The frame that should be showing right now, accounting for this source's delay.
    ///
    /// Returns the newest frame that is at least `delaySeconds` old. With no delay
    /// that is simply the latest frame. When the history does not reach back far
    /// enough yet — right after a delay increase — the oldest frame is used rather
    /// than showing nothing.
    public func current() -> Entry? {
        lock.withLock {
            guard !entries.isEmpty else { return nil }
            guard delaySeconds > 0.0005 else { return entries.last }

            let target = clock.now - .seconds(delaySeconds)
            var chosen = entries.first
            for entry in entries {
                if entry.receivedAt <= target { chosen = entry } else { break }
            }
            return chosen
        }
    }

    /// Newest frame regardless of delay — for the operator's own monitor, where
    /// seeing the picture sooner beats seeing it aligned.
    public func latest() -> Entry? {
        lock.withLock { entries.last }
    }

    /// How much history is actually available, in seconds.
    public var span: Double {
        lock.withLock {
            guard let first = entries.first, let last = entries.last, entries.count > 1 else {
                return 0
            }
            return Double((last.receivedAt - first.receivedAt).components.seconds)
                 + Double((last.receivedAt - first.receivedAt).components.attoseconds) / 1e18
        }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public func clear() {
        lock.withLock { entries.removeAll(keepingCapacity: true) }
    }
}

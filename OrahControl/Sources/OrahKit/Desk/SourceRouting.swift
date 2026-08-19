import Foundation

/// Where each picture is read from.
///
/// There are two ways to fill a wall of twenty-four cameras and they trade the
/// same work between two machines.
///
/// **On the Mac** every thumbnail is a full 1920×1440 stream decoded here. It is
/// instant, it is exact, and it costs one hardware decode per camera. Nothing
/// has to be running at the other end.
///
/// **On the nodes** each node transcodes its own cameras down to 480×270 at ten
/// frames, and the Mac decodes those instead — a twentieth of the pixels, a
/// third of the frame rate. The node has the picture already; it is reading it
/// off its own disk controller rather than pulling it across the room.
///
/// Neither is right in general. Six cameras on a Mac Studio is nothing; twenty-
/// four is a real load, and that is the point at which the work should move to
/// the machines that are otherwise only writing files. So it is a switch, not a
/// decision taken once in the source code.
///
/// **Programme and preview are never proxied.** Focus cannot be judged on a
/// 480-pixel picture, and those two are what the mix sends out.
public enum SourceRouting {

    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Every picture decoded here, at full size.
        case mac
        /// Thumbnails come from the nodes' proxies; the desk pair still does not.
        case node
    }

    /// What a camera is being read for.
    public enum Role: Equatable {
        /// On air or cued next — full size, every lens.
        case desk
        /// A tile on the wall.
        case thumbnail
    }

    /// One stream to read, and which lens of the camera it is a picture of.
    ///
    /// They are not the same thing, which is why this is a pair. The camera's
    /// own streams are one per lens; a node's proxy is a single path carrying
    /// whichever lens that node has been told to send. The desk still has to
    /// know which lens it is looking at — that decides how far the picture is
    /// turned on screen.
    public struct Stream: Equatable {
        public var lens: Int
        public var path: String
    }

    public struct Source: Equatable {
        /// Base URL, ending in a slash: paths are appended to it.
        public var base: String
        public var streams: [Stream]
        /// Whether this is the node's small picture rather than the camera's own.
        public var isProxy: Bool

        public var paths: [String] { streams.map(\.path) }
    }

    /// - Parameters:
    ///   - slot: the camera.
    ///   - role: what it is being read for.
    ///   - mode: where thumbnails are supposed to come from.
    ///   - lenses: which lenses to read, when reading the camera itself.
    ///   - nodeHost: the node that owns this camera, if there is one.
    ///   - nodeOnline: whether that node is answering.
    ///   - fallbackHost: where the camera publishes when there is no node.
    ///   - port: RTMP port, the same everywhere.
    public static func source(slot: Int,
                              role: Role,
                              mode: Mode,
                              lenses: [Int],
                              tileLens: Int = 0,
                              nodeHost: String?,
                              nodeOnline: Bool,
                              fallbackHost: String,
                              port: Int) -> Source {
        let host = nodeHost ?? fallbackHost
        let camera = String(format: "rtmp://%@:%d/cam%02d/", host, port, slot)

        // A proxy is only ever a thumbnail, only when asked for, and only when
        // there is a node up to make one. Falling back silently to the full
        // stream is right: a picture at full cost beats no picture at all, and
        // the alternative is a wall that empties itself when a node reboots.
        guard role == .thumbnail, mode == .node,
              let nodeHost, nodeOnline else {
            return Source(base: camera,
                          streams: lenses.map { Stream(lens: $0, path: Switcher.lenses[$0]) },
                          isProxy: false)
        }

        return Source(base: String(format: "rtmp://%@:%d/cam%02d/", nodeHost, port, slot),
                      streams: [Stream(lens: tileLens, path: "proxy")],
                      isProxy: true)
    }

    /// Whether the node needs to be told to run its transcodes at all.
    public static func nodeShouldTranscode(mode: Mode) -> Bool { mode == .node }
}

import Foundation

/// Where pictures are read from, as checks.
public enum SourceRoutingSelfTest {

    public static func run() -> ProtoSelfTest.Result {
        var r = ProtoSelfTest.Result()

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { r.passed.append(name) }
            else { r.failed.append((name, detail())) }
        }

        func source(_ role: SourceRouting.Role,
                    _ mode: SourceRouting.Mode,
                    node: String? = "10.0.0.5",
                    online: Bool = true,
                    lenses: [Int] = [0, 1, 2, 3]) -> SourceRouting.Source {
            SourceRouting.source(slot: 7, role: role, mode: mode, lenses: lenses,
                                 tileLens: 2,
                                 nodeHost: node, nodeOnline: online,
                                 fallbackHost: "192.168.0.251", port: 1935)
        }

        // On the Mac, everything is the camera's own stream.
        do {
            let s = source(.thumbnail, .mac)
            check("mac mode reads the camera", !s.isProxy)
            check("and reads it at its own address",
                  s.base == "rtmp://10.0.0.5:1935/cam07/", s.base)
        }

        // In node mode a tile is the node's small picture.
        do {
            let s = source(.thumbnail, .node)
            check("node mode reads the proxy", s.isProxy)
            check("the proxy is one path, not four", s.paths == ["proxy"], "\(s.paths)")
            // The desk still has to know which lens it is looking at: that is
            // what decides how far the picture is turned on screen.
            check("and it stands in for the lens the tile is showing",
                  s.streams.first?.lens == 2, "\(s.streams)")
        }

        // But never what is on air. A 480-pixel picture cannot be focused on,
        // and these two are what the mix sends out.
        do {
            let s = source(.desk, .node)
            check("the desk pair is never proxied", !s.isProxy)
            check("and still gets every lens it asked for",
                  s.paths == ["0_0", "0_1", "1_0", "1_1"], "\(s.paths)")
        }

        // A node that is not answering must not empty the wall. A picture at
        // full cost beats no picture.
        do {
            let s = source(.thumbnail, .node, online: false)
            check("a node that is down falls back to the camera", !s.isProxy)
        }
        do {
            let s = source(.thumbnail, .node, node: nil)
            check("a camera with no node falls back too", !s.isProxy)
            check("to the address it publishes to",
                  s.base == "rtmp://192.168.0.251:1935/cam07/", s.base)
        }

        // Half a camera still reads only the lenses it has.
        do {
            let s = source(.desk, .mac, lenses: [2, 3])
            check("only the lenses asked for", s.paths == ["1_0", "1_1"], "\(s.paths)")
        }

        // The node is only asked to burn power when its pictures are wanted.
        check("nodes transcode only in node mode",
              SourceRouting.nodeShouldTranscode(mode: .node)
              && !SourceRouting.nodeShouldTranscode(mode: .mac))

        return r
    }
}

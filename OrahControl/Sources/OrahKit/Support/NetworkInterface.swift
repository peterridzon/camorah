import Foundation

public enum NetworkInterface {

    /// This Mac's primary LAN IPv4 address.
    ///
    /// Cameras publish RTMP *to us* over the LAN, so the URL we hand them can
    /// never be `127.0.0.1` — a mistake that produces a camera reporting success
    /// while nothing ever arrives.
    public static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        // Prefer Ethernet, then Wi-Fi, then anything else routable.
        var candidates: [(name: String, address: String)] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }   // self-assigned
            candidates.append((name, address))
        }

        func pick(_ prefixes: [String]) -> String? {
            candidates.first { c in prefixes.contains { c.name.hasPrefix($0) } }?.address
        }

        return pick(["en0", "en1", "en2", "en3"])   // built-in Ethernet / Wi-Fi
            ?? pick(["bridge", "ap"])
            ?? candidates.first?.address
    }

    /// All routable IPv4 addresses, for the settings picker.
    public static func allIPv4() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var out: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            out.append((String(cString: ptr.pointee.ifa_name), String(cString: host)))
        }
        return out
    }
}

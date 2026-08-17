import Foundation

/// Is the camera actually reachable, and how well?
///
/// This is the first thing to establish and the easiest to skip. A camera behind
/// a switch that drops a quarter of its packets answers Bonjour, opens a TCP
/// connection, and then fails every single thing after that in ways that look
/// like firmware faults — a WebSocket handshake that never completes, a start
/// that returns nothing, a stream that stops after a second. A day went into
/// chasing that before anyone pinged it (MEASUREMENTS M8).
///
/// So: measure the link first, and say so plainly, before touching the protocol.
public enum NetworkProbe {

    public struct Link: Sendable {
        public var packetLossPercent: Double?
        public var roundTripMilliseconds: Double?

        /// The gateway, measured in the same breath.
        ///
        /// A round trip on its own says nothing: on a Mac joined over Wi-Fi it
        /// swings by a factor of five from one minute to the next, and comparing
        /// cameras measured minutes apart produces confident nonsense about
        /// cables. The only meaningful figure is the camera against the router
        /// **at the same moment**, over the same air.
        public var gatewayRoundTripMilliseconds: Double?
        public var isWireless = false

        public var portOpen = false
        public var handshakeStatus: Int?

        /// A link good enough to trust the results of everything after it.
        public var isSound: Bool {
            guard let loss = packetLossPercent else { return false }
            return loss < 2 && portOpen
        }
    }

    public static func check(host: String, port: Int) async -> Link {
        var link = Link()
        let ping = await self.ping(host: host)
        link.packetLossPercent = ping.loss
        link.roundTripMilliseconds = ping.average
        if let gateway = gateway() {
            link.gatewayRoundTripMilliseconds = await self.ping(host: gateway, count: 10).average
        }
        link.isWireless = isWireless()
        link.portOpen = portOpen(host: host, port: port)
        // The handshake is deliberately NOT probed here. Sending the upgrade
        // request is not a harmless look: the camera has one control session and
        // a probe that reaches it takes it, so the connection made a second
        // later is refused — by a check meant to make that connection safer.
        // The status is only worth asking for once something has already failed,
        // which is where CameraSession asks for it.
        return link
    }

    // MARK: - Ping

    /// Twenty packets is enough to see a fault and quick enough that nobody skips
    /// it. The comparison that matters is against the gateway, not an absolute
    /// number — see `gateway()`.
    public static func ping(host: String, count: Int = 20) async -> (loss: Double?, average: Double?) {
        guard let output = run("/sbin/ping", ["-c", "\(count)", "-i", "0.2", "-t", "2", host])
        else { return (nil, nil) }

        var loss: Double?
        var average: Double?

        for line in output.split(separator: "\n") {
            if line.contains("packet loss"),
               let field = line.split(separator: ",").first(where: { $0.contains("packet loss") }) {
                loss = Double(field.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "% packet loss", with: ""))
            }
            if line.contains("round-trip"),
               let numbers = line.split(separator: "=").last {
                let parts = numbers.split(separator: "/")
                if parts.count > 1 { average = Double(parts[1]) }
            }
        }
        return (loss, average)
    }

    /// Whether this Mac is on Wi-Fi.
    ///
    /// It changes how every timing below should be read, so it is recorded
    /// rather than assumed.
    public static func isWireless() -> Bool {
        guard let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return false }
        var wirelessDevices: Set<String> = []
        var lastPortWasWireless = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") {
                lastPortWasWireless = line.lowercased().contains("wi-fi")
                    || line.lowercased().contains("airport")
            } else if line.hasPrefix("Device:"), lastPortWasWireless {
                wirelessDevices.insert(line.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        guard let route = run("/sbin/route", ["-n", "get", "default"]) else { return false }
        for line in route.split(separator: "\n") where line.contains("interface:") {
            let device = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return wirelessDevices.contains(device)
        }
        return false
    }

    /// The default gateway, as a control: a camera losing packets while the
    /// router does not is the camera's link, not the network in general.
    public static func gateway() -> String? {
        guard let output = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in output.split(separator: "\n") where line.contains("gateway:") {
            return line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Port and handshake

    public static func portOpen(host: String, port: Int, timeout: Int = 3) -> Bool {
        run("/usr/bin/nc", ["-z", "-w", "\(timeout)", host, "\(port)"]) != nil
    }

    /// The status code the camera gives the WebSocket upgrade.
    ///
    /// **Costs a control session.** Only ask after a connection has already
    /// failed, to find out why: `503` means the one session is taken, `406` that
    /// the camera is refusing the upgrade itself. Never as a pre-flight check —
    /// the probe becomes the thing that takes the session.
    public static func handshakeStatus(host: String, port: Int) async -> Int? {
        guard let url = URL(string: "http://\(host):\(port)/control") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue("camctrl-protobuf/1.0", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
                         forHTTPHeaderField: "Sec-WebSocket-Key")

        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    // MARK: - Finding cameras Bonjour will not admit to

    /// Addresses of Orah hardware, taken from the ARP table.
    ///
    /// A camera that took an address but has not finished announcing itself is
    /// invisible to Bonjour and perfectly visible here. The OUI is Orah's own.
    public static func orahAddresses(subnet: String = "192.168.0") async -> [(host: String, mac: String)] {
        await sweep(subnet: subnet)
        return orahAddressesInCache()
    }

    /// The same list, without the sweep — for when something else has just
    /// touched the addresses and the table is already warm.
    public static func orahAddressesInCache() -> [(host: String, mac: String)] {
        arpTable()
            .filter { $0.value.hasPrefix(Self.orahOUI) }
            .map { (host: $0.key, mac: $0.value) }
            .sorted { $0.host < $1.host }
    }

    /// The ARP table exactly as it stands, address → MAC. No network traffic,
    /// one process, a few milliseconds.
    ///
    /// This is the only cheap way to answer "which piece of hardware is at this
    /// address", and that question matters more than it looks: DHCP hands a
    /// released address to the next camera that asks. A port answering at
    /// 192.168.0.143 proves something is alive there — not that it is still the
    /// same camera. The MAC is burned in and never moves.
    public static func arpTable() -> [String: String] {
        guard let output = run("/usr/sbin/arp", ["-an"]) else { return [:] }
        var table: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")") else { continue }
            let host = String(line[line.index(after: open)..<close])
            let fields = line.split(separator: " ")
            guard let at = fields.firstIndex(of: "at"), at + 1 < fields.count else { continue }
            let mac = String(fields[at + 1])
            guard mac.contains(":") else { continue }   // "(incomplete)"
            table[host] = normalise(mac)
        }
        return table
    }

    /// MACs are printed with leading zeroes dropped — `48:65:ee:90:8:ea` — and
    /// compared against forms that keep them. Both sides go through here.
    public static func normalise(_ mac: String) -> String {
        mac.lowercased().split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.count == 1 ? "0" + $0 : String($0) }
            .joined(separator: ":")
    }

    /// Which of these addresses answer a ping, all asked at once.
    ///
    /// A handful of addresses, under a second, no control session touched. This
    /// is what presence is decided on: a camera whose power has been pulled
    /// stops answering on the next packet, while its Bonjour record, its ARP
    /// entry, its half-open control socket and its MediaMTX path all go on
    /// looking healthy for minutes.
    public static func reachable(hosts: [String], timeoutMilliseconds: Int = 700) -> Set<String> {
        guard !hosts.isEmpty else { return [] }

        let lock = NSLock()
        var alive: Set<String> = []
        let limit = DispatchSemaphore(value: 16)
        let group = DispatchGroup()

        for host in hosts {
            limit.wait()
            group.enter()
            sweepQueue.async {
                defer { limit.signal(); group.leave() }
                // `-W` is the per-reply wait in milliseconds, `-t` the overall
                // cap in seconds: without the second one a host that is simply
                // gone can hold the slot far longer than asked.
                let answered = run("/sbin/ping",
                                   ["-c", "1", "-W", "\(timeoutMilliseconds)", "-t", "2", host]) != nil
                if answered {
                    lock.withLock { _ = alive.insert(host) }
                }
            }
        }
        group.wait()
        return alive
    }

    /// Wakes the ARP table by touching every address on the subnet.
    ///
    /// Deliberately not `withTaskGroup`. Each ping is a process, and waiting for
    /// a process blocks the thread it is on — two hundred and fifty-four of those
    /// on Swift's cooperative pool exhausts it, and everything else waiting for a
    /// thread stops, including the main actor. The interface locks up while the
    /// app looks for cameras, which is a poor trade.
    ///
    /// So: a queue of its own, a handful at a time, off the pool entirely.
    private static func sweep(subnet: String) async {
        await withCheckedContinuation { continuation in
            sweepQueue.async {
                let limit = DispatchSemaphore(value: 12)
                let group = DispatchGroup()

                for last in 1...254 {
                    limit.wait()
                    group.enter()
                    sweepQueue.async {
                        defer { limit.signal(); group.leave() }
                        _ = run("/sbin/ping", ["-c", "1", "-t", "1", "\(subnet).\(last)"])
                    }
                }

                group.wait()
                continuation.resume()
            }
        }
    }

    private static let sweepQueue = DispatchQueue(
        label: "orah.network.sweep", qos: .utility, attributes: .concurrent)

    /// Orah's OUI. Both SoCs of one camera sit on consecutive addresses with
    /// consecutive MACs, which is how a pair can be recognised as one camera.
    public static let orahOUI = "48:65:ee"

    // MARK: - Running things

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

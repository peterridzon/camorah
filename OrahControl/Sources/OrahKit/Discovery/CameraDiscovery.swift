import Foundation
import Network

/// A camera seen on the network, before we've talked to it.
public struct DiscoveredCamera: Sendable, Hashable, Identifiable {
    /// Bonjour instance name — unique per camera and stable while it stays on the
    /// network, so it works as an identity fallback when the serial is unavailable.
    public let serviceName: String
    public let host: String
    public let port: Int

    public init(serviceName: String, host: String, port: Int) {
        self.serviceName = serviceName
        self.host = host
        self.port = port
    }

    public var id: String { serviceName }

    public var controlURL: URL? {
        // IPv6 literals must be bracketed in a URL.
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "ws://\(h):\(port)/control")
    }
}

/// Browses for Orah cameras advertising `_vscamera._tcp`.
///
/// Uses the Network framework rather than the deprecated `NetService` API. Bonjour
/// hands us a service endpoint, not an address, so each result is resolved through
/// a short-lived connection to learn the actual host and port.
public final class CameraDiscovery: @unchecked Sendable {

    public enum Event: Sendable {
        case found(DiscoveredCamera)
        case lost(serviceName: String)
        case browserFailed(String)
    }

    private static let serviceType = "_vscamera._tcp"

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "orah.discovery")
    private var known: [String: DiscoveredCamera] = [:]
    private var handler: (@Sendable (Event) -> Void)?

    /// Every service currently being advertised, so a resolve that failed can be
    /// tried again against the same endpoint.
    private var advertised: [String: NWEndpoint] = [:]
    private var attempts: [String: Int] = [:]

    public init() {}

    public func start(onEvent: @escaping @Sendable (Event) -> Void) {
        stop()
        handler = onEvent

        let params = NWParameters()
        params.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: params)
        self.browser = browser

        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("discovery", "browsing for \(Self.serviceType)")
            case .failed(let error):
                Log.error("discovery", "browser failed: \(error.localizedDescription)")
                onEvent(.browserFailed(error.localizedDescription))
            case .cancelled:
                Log.debug("discovery", "browser cancelled")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }

        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        queue.sync {
            known.removeAll()
            advertised.removeAll()
            attempts.removeAll()
        }
    }

    // MARK: - Result handling

    private func handle(results: Set<NWBrowser.Result>) {
        var seen = Set<String>()

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            advertised[name] = result.endpoint
            guard known[name] == nil else { continue }

            // Reserve the name immediately so a second browse callback (they arrive
            // in bursts) doesn't kick off a duplicate resolve for the same camera.
            known[name] = DiscoveredCamera(serviceName: name, host: "", port: 0)
            attemptResolve(name: name, endpoint: result.endpoint)
        }

        for (name, camera) in known where !seen.contains(name) {
            known[name] = nil
            attempts[name] = nil
            if !camera.host.isEmpty {
                Log.info("discovery", "lost \(name)")
                handler?(.lost(serviceName: name))
            }
        }
        for name in advertised.keys where !seen.contains(name) {
            advertised[name] = nil
        }
    }

    /// Resolves, and keeps trying for as long as the camera is still advertising.
    ///
    /// A browse handler only fires when the *set* of results changes. A camera
    /// that is present but momentarily unresolvable therefore gets exactly one
    /// chance under the obvious implementation, and then sits there advertising
    /// itself to an app that has forgotten it — which is what happened: one
    /// failed resolve at startup and the camera was gone for the whole session.
    private func attemptResolve(name: String, endpoint: NWEndpoint) {
        let attempt = (attempts[name] ?? 0) + 1
        attempts[name] = attempt

        resolve(endpoint: endpoint) { [weak self] resolved in
            guard let self else { return }
            self.queue.async {
                guard let (host, port) = resolved else {
                    self.known[name] = nil
                    if attempt == 1 || attempt % 10 == 0 {
                        Log.warn("discovery", "could not resolve \(name), still trying")
                    }
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        guard self.known[name] == nil,
                              let endpoint = self.advertised[name] else { return }
                        self.known[name] = DiscoveredCamera(serviceName: name, host: "", port: 0)
                        self.attemptResolve(name: name, endpoint: endpoint)
                    }
                    return
                }
                self.attempts[name] = nil
                let camera = DiscoveredCamera(serviceName: name, host: host, port: port)
                self.known[name] = camera
                Log.info("discovery", "found \(name) at \(host):\(port)")
                self.handler?(.found(camera))
            }
        }
    }

    /// Resolves a Bonjour endpoint to a concrete host and port.
    ///
    /// Deliberately over UDP. The address is learned from mDNS either way, but a
    /// UDP connection reaches `.ready` without a handshake, so the camera never
    /// sees a packet. Resolving over TCP would open — and immediately drop — a
    /// connection on port 9989, the control port, and repeated connects on that
    /// port are what left four cameras refusing to encode (MEASUREMENTS M5).
    private func resolve(endpoint: NWEndpoint,
                         completion: @escaping @Sendable ((host: String, port: Int)?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .udp)
        let done = OneShot(completion)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let remote = connection.currentPath?.remoteEndpoint,
                      case .hostPort(let host, let port) = remote else {
                    done.fire(nil)
                    connection.cancel()
                    return
                }
                done.fire((Self.describe(host), Int(port.rawValue)))
                connection.cancel()

            case .failed, .cancelled:
                done.fire(nil)

            default:
                break
            }
        }

        connection.start(queue: queue)

        // Don't let an unreachable advertisement hang a slot forever.
        queue.asyncAfter(deadline: .now() + 5) {
            if done.fire(nil) { connection.cancel() }
        }
    }

    /// Strips the scope id (`fe80::1%en0`) that IPv6 link-local addresses carry.
    private static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}

/// Guarantees a completion handler runs exactly once, whichever of the racing
/// paths (ready / failed / timeout) gets there first.
private final class OneShot<T>: @unchecked Sendable {
    private var handler: ((T) -> Void)?
    private let lock = NSLock()

    init(_ handler: @escaping (T) -> Void) { self.handler = handler }

    @discardableResult
    func fire(_ value: T) -> Bool {
        let h: ((T) -> Void)? = lock.withLock {
            defer { handler = nil }
            return handler
        }
        h?(value)
        return h != nil
    }
}

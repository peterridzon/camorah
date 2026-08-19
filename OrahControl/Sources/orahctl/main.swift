import Foundation
import CoreVideo
import CoreMedia
import OrahKit

// Headless companion to the GUI: verifies the camera protocol against real
// hardware from a terminal, and runs codec checks on a machine without Xcode.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    orahctl — 4idesk command line

    USAGE:
      orahctl selftest                    Protocol codec conformance checks
      orahctl discover [seconds]          Browse for Orah cameras (default 10s)
      orahctl probe <host> [port]         Connect and report camera identity
      orahctl calib <host> <dir> [port]   Download calibration files
      orahctl stream <host> <slot> [secs] [port]  Start streaming, hold, stop
      orahctl ifaces                      Show this Mac's network addresses
      orahctl transcode <in> <out> [secs] Decode and re-encode one lane in hardware
      orahctl stop <host> [port]          Stop streaming and report camera mode
      orahctl start <host> <slot> [port]  Start streaming, then let go of control
      orahctl inspect <host> [port]       Read-only survey of what the camera exposes
      orahctl checkout [--stream N] [--number N]
                                          Acceptance-check every camera found and
                                          record it in camera-records/FLEET.md.
                                          --number tags the number written on the
                                          case; --stream also tests streaming.
      orahctl metaltest                   Exercise the GPU dissolve on synthetic frames
      orahctl switch <baseA> <baseB> <out> Run the four-lane switcher and dissolve
      orahctl tag <serial> <number>       Write the number painted on a camera
                                          onto its record, and rebuild FLEET.md
      orahctl restart <host> [port]       Reboot a camera over the protocol
      orahctl tag <serial> <number>       Correct the number on a camera's record
      orahctl fleet                       Rebuild FLEET.md without touching a camera
      orahctl renumber                    Work out new numbers and write RENUMBER.md
      orahctl addresses                   Write the DHCP reservation plan
      orahctl deskcheck <base> [secs]     Does a stream reach the desk monitor?
      orahctl starttest <host> [port]     Try every destination shape in ONE session

    NOTES:
      'stream' publishes to rtmp://<this-mac>:1935/cam<slot>/ and always sends
      STOP before exiting, so it leaves the camera idle.

    """)
    exit(2)
}

guard let command = args.first else { usage() }

/// Browses for the given number of seconds, returning everything found.
func browse(seconds: Double) async -> [DiscoveredCamera] {
    let discovery = CameraDiscovery()
    let collector = Collector()

    discovery.start { event in
        if case .found(let camera) = event {
            Task { await collector.add(camera) }
        }
    }

    try? await Task.sleep(for: .seconds(seconds))
    discovery.stop()
    return await collector.all()
}

actor Collector {
    private var cameras: [DiscoveredCamera] = []
    func add(_ camera: DiscoveredCamera) {
        guard !cameras.contains(where: { $0.serviceName == camera.serviceName }) else { return }
        cameras.append(camera)
    }
    func all() -> [DiscoveredCamera] { cameras }
}

/// Every session this run has opened, so none of them is left behind.
///
/// The camera holds a control session open until it is told otherwise. A command
/// that fails and calls `exit()` — a timeout, a rejected command, Ctrl-C — never
/// closes it, and the camera goes on believing someone is connected. The next
/// run is then refused with "bad response from the server", and a few of those
/// leave the camera refusing everything until it is power cycled. That is the
/// same fault the app had, and it is the same fix: give the session back.
final class OpenSessions: @unchecked Sendable {
    static let shared = OpenSessions()
    private let lock = NSLock()
    private var sessions: [CameraSession] = []

    func add(_ session: CameraSession) {
        lock.withLock { sessions.append(session) }
    }

    func closeAll() {
        let open = lock.withLock { () -> [CameraSession] in
            defer { sessions.removeAll() }
            return sessions
        }
        open.forEach { $0.closeImmediately() }
    }
}

// Covers every ordinary exit, including the `exit(...)` calls scattered through
// the commands below.
//
// The wait is not decoration. `cancel(with: .goingAway)` hands the close frame
// to URLSession to send, and `exit` a microsecond later takes the process down
// before it leaves the machine. The camera then never hears that we are done,
// keeps its one control session reserved, and refuses the next run with 503 —
// which costs a power cycle every time a command fails.
atexit {
    OpenSessions.shared.closeAll()
    usleep(400_000)
}

// And the ones a signal causes, which atexit does not run for.
for sig in [SIGINT, SIGTERM] {
    signal(sig) { _ in
        OpenSessions.shared.closeAll()
        // Long enough for the close frames to leave, short enough to feel instant.
        usleep(300_000)
        _exit(1)
    }
}

func connect(host: String, port: Int) async throws -> CameraSession {
    let camera = DiscoveredCamera(serviceName: host, host: host, port: port)
    let session = CameraSession(discovered: camera)
    OpenSessions.shared.add(session)
    try await session.connect()
    return session
}

switch command {

case "selftest":
    var result = ProtoSelfTest.run()
    // The desk planner's rules run here too: they are the way back from a
    // change to what gets decoded, and that is where the worst breakages live.
    let desk = DeskPlanSelfTest.run()
    result.passed += desk.passed
    result.failed += desk.failed
    // The byte loop every lens of every camera runs through.
    let units = AccessUnitSelfTest.run()
    result.passed += units.passed
    result.failed += units.failed
    // What the desk does about cameras that go quiet, and streams that are not
    // there yet.
    let fleet = FleetPolicySelfTest.run()
    result.passed += fleet.passed
    result.failed += fleet.failed
    // What the wall shows, and what a camera's own key says.
    let wall = WallPolicySelfTest.run()
    result.passed += wall.passed
    result.failed += wall.failed
    for name in result.passed { print("  ok    \(name)") }
    for failure in result.failed { print("  FAIL  \(failure.name): \(failure.detail)") }
    print("\n\(result.passed.count) passed, \(result.failed.count) failed")
    exit(result.ok ? 0 : 1)

case "ifaces":
    print("Primary LAN address: \(NetworkInterface.primaryIPv4() ?? "none found")")
    print("\nAll IPv4 interfaces:")
    for entry in NetworkInterface.allIPv4() {
        print("  \(entry.interface.padding(toLength: 12, withPad: " ", startingAt: 0)) \(entry.address)")
    }
    exit(0)

case "discover":
    let seconds = args.count > 1 ? Double(args[1]) ?? 10 : 10
    print("Browsing for _vscamera._tcp for \(Int(seconds))s...\n")
    let found = await browse(seconds: seconds)
    if found.isEmpty {
        print("No cameras found.")
        print("Check: camera powered over PoE, on the same subnet, and this Mac")
        print("is allowed under System Settings > Privacy & Security > Local Network.")
        exit(1)
    }
    for camera in found {
        print("  \(camera.serviceName)  →  \(camera.host):\(camera.port)")
    }
    exit(0)

case "probe":
    guard args.count > 1 else { usage() }
    let host = args[1]
    let port = args.count > 2 ? Int(args[2]) ?? 9989 : 9989
    do {
        let session = try await connect(host: host, port: port)
        let info = try await session.requestCameraInfo()
        let mode = try await session.requestCameraMode()
        print("""

        Model:      \(info.model)
        Serial:     \(info.serialNumber)
        Name:       \(info.name)
        Hardware:   \(info.hardwareVersion)
        Firmware:   \(info.softwareVersion)
        Sensors:    \(info.sensorCount)
        SoCs:       \(info.socCount)
        Mode:       \(mode)
        """)
        await session.disconnect()
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "calib":
    guard args.count > 2 else { usage() }
    let host = args[1]
    let directory = URL(fileURLWithPath: args[2])
    let port = args.count > 3 ? Int(args[3]) ?? 9989 : 9989
    do {
        let session = try await connect(host: host, port: port)
        await session.fetchCalibration(into: directory)
        await session.disconnect()
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "stream":
    guard args.count > 2, let slot = Int(args[2]) else { usage() }
    let host = args[1]
    let hold = args.count > 3 ? Double(args[3]) ?? 30 : 30
    let controlPort = args.count > 4 ? Int(args[4]) ?? 9989 : 9989

    guard let lan = NetworkInterface.primaryIPv4() else {
        print("Could not determine this Mac's LAN address.")
        exit(1)
    }

    let base = String(format: "rtmp://%@:1935/cam%02d/", lan, slot)
    print("Publishing to \(base)")
    print("Expect these paths in MediaMTX: cam\(String(format: "%02d", slot))/0_0, /0_1, /1_0, /1_1\n")

    do {
        let session = try await connect(host: host, port: controlPort)
        try await session.startStreaming(rtmpBase: base)
        print("Streaming. Holding \(Int(hold))s, then stopping...")
        try? await Task.sleep(for: .seconds(hold))
        try await session.stopStreaming()
        await session.disconnect()
        print("Stopped cleanly.")
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "switch":
    // Four lanes, two cameras, one shared transition.
    guard args.count > 3 else { usage() }
    let baseA = args[1]
    let baseB = args[2]
    let outBase = args[3]

    do {
        let switcher = try Switcher()
        let cameraA = CameraSource(slot: 1)
        let cameraB = CameraSource(slot: 2)

        try cameraA.attach(to: switcher, rtmpBase: baseA)
        try cameraB.attach(to: switcher, rtmpBase: baseB)

        try switcher.startOutputs { lens in
            (outBase.hasSuffix("/") ? outBase : outBase + "/") + lens
        }

        switcher.setProgram(slot: 1)
        switcher.setPreview(slot: 2)

        print("program  cam 1  \(baseA)")
        print("preview  cam 2  \(baseB)")
        print("output   \(outBase)/{0_0,0_1,1_0,1_1}")
        print("")

        print("filling buffers...")
        try? await Task.sleep(for: .seconds(8))
        switcher.start()

        func report(_ label: String) {
            let s = switcher.status
            print(String(format: "  %-22s program %@  preview %@  mix %.2f  out %d  late %d",
                         (label as NSString).utf8String!,
                         s.programSlot.map(String.init) ?? "—",
                         s.previewSlot.map(String.init) ?? "—",
                         s.mix, s.outputFrames, s.lateFrames))
        }

        try? await Task.sleep(for: .seconds(6))
        report("holding on program")

        print("")
        print("dissolve 1 → 2 over 600 ms")
        switcher.take(.dissolve(.milliseconds(600)))
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(150))
            report("  during")
        }

        try? await Task.sleep(for: .seconds(4))
        report("after take")

        print("")
        print("T-bar, driven by hand")
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            switcher.setMix(Float(step))
            try? await Task.sleep(for: .milliseconds(400))
            report(String(format: "  bar %.2f", step))
        }

        try? await Task.sleep(for: .seconds(4))
        print("")
        let final = switcher.status
        print("output frames   \(final.outputFrames)")
        print("late ticks      \(final.lateFrames)")
        let n = Double(max(final.outputFrames, 1))
        print(String(format: "per tick        total %.1f ms  composite %.1f ms  encode %.1f ms",
                     switcher.timeTick / n * 1000,
                     switcher.timeComposite / n * 1000,
                     switcher.timeEncode / n * 1000))
        print("frames in       cam1 \(cameraA.framesIn)  cam2 \(cameraB.framesIn)")

        switcher.stop()
        cameraA.stop()
        cameraB.stop()
        exit(final.outputFrames > 0 ? 0 : 1)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "enctest":
    // How fast is one hardware encoder, and how do several behave together?
    do {
        func makeFrame(_ v: UInt8, width: Int, height: Int) -> CVPixelBuffer {
            var buffer: CVPixelBuffer!
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, Int32(v), bytes)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        // Same frames, same count — only the PTS grid differs, to see whether the
        // encoder is pacing itself to the presentation timeline rather than
        // encoding as fast as the hardware allows.
        for (label, ptsStride) in [("pts advancing 1/30s", Int64(1)), ("pts all zero", Int64(0))] {
            let e = try H264Encoder(settings: .init(width: 1920, height: 1080,
                                                    fps: 30, bitrate: 12_000_000))
            e.onEncoded = { _, _, _ in }
            let f = [makeFrame(60, width: 1920, height: 1080),
                     makeFrame(180, width: 1920, height: 1080)]
            let n = 90
            let t0 = Date()
            for i in 0..<n {
                try e.encode(f[i % 2], pts: CMTime(value: Int64(i) * ptsStride, timescale: 30))
            }
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "  %-22s %6.1f ms per frame  → %5.1f fps",
                         (label as NSString).utf8String!, dt / Double(n) * 1000, Double(n) / dt))
            e.finish()
        }
        print("")

        for laneCount in [1, 2, 4] {
            let width: Int32 = 1920, height: Int32 = 1080
            var encoders: [H264Encoder] = []
            for _ in 0..<laneCount {
                let e = try H264Encoder(settings: .init(width: width, height: height,
                                                        fps: 30, bitrate: 12_000_000))
                e.onEncoded = { _, _, _ in }
                encoders.append(e)
            }
            // Two frames so successive frames differ and the encoder does real work.
            let frames = [makeFrame(60, width: Int(width), height: Int(height)),
                          makeFrame(180, width: Int(width), height: Int(height))]

            let iterations = 90
            let start = Date()
            for i in 0..<iterations {
                for (lane, e) in encoders.enumerated() {
                    try e.encode(frames[(i + lane) % 2],
                                 pts: CMTime(value: Int64(i), timescale: 30))
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            let perTick = elapsed / Double(iterations) * 1000
            print(String(format: "%d lane(s): %6.1f ms per tick  (%5.1f ms per lane)  → %5.1f fps",
                         laneCount, perTick, perTick / Double(laneCount), 1000.0 / perTick))
            encoders.forEach { $0.finish() }
        }
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "metaltest":
    // Proves the dissolve on synthetic NV12 frames: no camera, no network.
    do {
        let compositor = try MetalCompositor()

        func makeFrame(luma: UInt8, chroma: UInt8, width: Int = 1920, height: Int = 1440) -> CVPixelBuffer {
            var buffer: CVPixelBuffer!
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, Int32(plane == 0 ? luma : chroma), bytes)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        func lumaAt(_ buffer: CVPixelBuffer) -> UInt8 {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
                .assumingMemoryBound(to: UInt8.self).pointee
        }

        let black = makeFrame(luma: 16, chroma: 128)    // video-range black
        let white = makeFrame(luma: 235, chroma: 128)   // video-range white

        print("blending a 16-luma frame towards a 235-luma frame\n")
        print("  mix     expected   measured")
        var worstError = 0.0
        for step in 0...10 {
            let t = Float(step) / 10.0
            let result = try compositor.composite(from: black, to: white, mix: t)
            let measured = Double(lumaAt(result))
            let expected = 16.0 + (235.0 - 16.0) * Double(t)
            worstError = max(worstError, abs(measured - expected))
            print(String(format: "  %.1f  %10.1f  %10.0f", t, expected, measured))
        }

        // Timing, at the real camera resolution.
        let start = Date()
        let iterations = 300
        for i in 0..<iterations {
            _ = try compositor.composite(from: black, to: white,
                                         mix: Float(i % 100) / 100.0 * 0.98 + 0.01)
        }
        let elapsed = Date().timeIntervalSince(start)

        print("")
        print(String(format: "worst error        %.1f of 255", worstError))
        print(String(format: "%d blends at 1920×1440", iterations))
        print(String(format: "  total            %.2f s", elapsed))
        print(String(format: "  per frame        %.2f ms", elapsed / Double(iterations) * 1000))
        print(String(format: "  headroom at 30fps %.0f×", (1.0 / 30.0) / (elapsed / Double(iterations))))
        print("")
        print("composited \(compositor.framesComposited), passed through \(compositor.framesPassedThrough)")
        exit(worstError <= 2.0 ? 0 : 1)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "checkout":
    // Plug in one camera, run this, get a verdict. Read-only throughout.
    let waitForever = args.contains("--wait")
    let archive = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("camera-records", isDirectory: true)
    try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

    print("Looking for a camera...")
    var found: [DiscoveredCamera] = []
    repeat {
        found = await browse(seconds: 12)
        if found.isEmpty && waitForever {
            print("  nothing yet — plug a camera in (ctrl-c to stop)")
        }
    } while found.isEmpty && waitForever

    // Bonjour silent does not mean absent. A camera that took an address but has
    // not finished announcing itself is invisible there and plainly visible in
    // the ARP table, so look before giving up.
    if found.isEmpty {
        print("  nothing on Bonjour — looking for Orah hardware on the network")
        let hardware = await NetworkProbe.orahAddresses()
        if hardware.isEmpty {
            print("")
            print("No camera on the network at all: nothing answers Bonjour and no")
            print("interface with Orah's MAC prefix \(NetworkProbe.orahOUI) is in the ARP table.")
            print("")
            print("  · is it powered? PoE, and the injector's data side into the switch")
            print("  · is it on this subnet? Bonjour does not cross subnets")
            print("  · give it a minute — it takes about that long from cold")
            exit(1)
        }
        print("")
        print("Found Orah hardware that is not announcing itself:")
        for (host, mac) in hardware { print("  \(host)   \(mac)") }
        print("")
        print("Two consecutive addresses are the two SoCs of one camera; control is")
        print("on the lower one. Checking it directly.")
        found = hardware.map {
            DiscoveredCamera(serviceName: "unannounced@\($0.host)", host: $0.host, port: 9989)
        }
    }

    // One session per camera, everything inside it.
    var streamSeconds: Double = 0
    if let index = args.firstIndex(of: "--stream"), index + 1 < args.count {
        streamSeconds = Double(args[index + 1]) ?? 0
    }
    let lanHost = NetworkInterface.primaryIPv4()

    // The number painted on the camera, which is what anyone handling them
    // actually goes by.
    var physicalNumber: Int?
    if let index = args.firstIndex(of: "--number"), index + 1 < args.count {
        physicalNumber = Int(args[index + 1])
    }

    @Sendable func livePaths() async -> [String] {
        guard let url = URL(string: "http://127.0.0.1:9997/v3/paths/list"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["name"] as? String }
    }

    var anyFailed = false
    for (index, camera) in found.enumerated() {
        let result = await CameraCheckout.run(
            on: camera, archiveTo: archive,
            slot: index + 1,
            number: physicalNumber,
            streamSeconds: streamSeconds,
            publishTo: lanHost,
            pathsProbe: streamSeconds > 0 ? livePaths : nil)
        print(result.report())
        if result.record.verdict == "FAIL" { anyFailed = true }

        // A camera that was never reached teaches nothing, and writing that
        // over an earlier successful check destroys real data. This happened:
        // a browse picked up the mDNS record of a camera that had just been
        // unplugged, failed to reach it, and overwrote its good record with a
        // failure.
        guard result.reachedCamera else {
            print("  not saved:  nothing was learned about this camera, so its")
            print("              existing record is left alone.")
            continue
        }

        // One JSON record per camera, so a fleet report can be built later.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let name = result.record.serial.isEmpty ? result.record.serviceName : result.record.serial
        if let data = try? encoder.encode(result.record) {
            let file = archive.appendingPathComponent("\(name).json")
            try? data.write(to: file)
            print("  saved:   \(file.lastPathComponent) and its calibration")
        }
    }
    do {
        try CameraCheckout.writeFleetSummary(in: archive)
        print("")
        print("  fleet:   \(archive.appendingPathComponent("FLEET.md").path)")
    } catch {
        print("  could not write the fleet sheet: \(error)")
    }

    print("")
    exit(anyFailed ? 1 : 0)

case "inspect":
    guard args.count > 1 else { usage() }
    let inspectHost = args[1]
    let inspectPort = args.count > 2 ? Int(args[2]) ?? 9989 : 9989

    // Strictly read-only. Nothing below changes a single camera setting.
    do {
        let session = try await connect(host: inspectHost, port: inspectPort)

        print("")
        if let mode = try? await session.requestCameraMode() {
            print("mode            \(mode)")
        }

        if let urls = try? await session.requestStreamURLs() {
            print("stream urls     \(urls.isEmpty ? "none reported" : "")")
            for url in urls { print("                \(url)") }
        }

        if let gains = try? await session.requestAudioGains() {
            print("audio channels  \(gains.count)")
            print("audio gain dB   \(gains.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        }

        if let camTime = try? await session.requestCameraTime() {
            let ours = UInt64(Date().timeIntervalSince1970)
            let drift = Int64(camTime) - Int64(ours)
            print("camera clock    \(Date(timeIntervalSince1970: TimeInterval(camTime)))")
            print("clock offset    \(drift) s vs this Mac")
        }

        // Probe for files by name. A miss returns FILE_NOT_FOUND, which is
        // harmless — nothing is written either way.
        let candidates = [
            "factoryPresetsProject.ptv",
            "rigParameters.json",
            "userPresetsProject.ptv",
            "config.json", "settings.json", "camera.conf",
            "version", "version.txt", "manifest.json",
            "calibration.json", "lensParameters.json",
        ]
        print("")
        print("files")
        for name in candidates {
            if let url = (try? await session.locateFile(name)) ?? nil {
                print("  found         \(name)  →  \(url)")
            } else {
                print("  absent        \(name)")
            }
        }

        await session.disconnect()
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "start":
    guard args.count > 2, let startSlot = Int(args[2]) else { usage() }
    let startHost = args[1]
    let startPort = args.count > 3 ? Int(args[3]) ?? 9989 : 9989

    guard let lan = NetworkInterface.primaryIPv4() else {
        print("Could not determine this Mac's LAN address.")
        exit(1)
    }
    // ORAH_RTMP_BASE overrides the destination, so the exact string the factory
    // tool used ("rtmp://<ip>:1935/inputs/") can be tried against a camera that
    // refuses ours — the one difference between the two that had not been tested.
    let startBase = ProcessInfo.processInfo.environment["ORAH_RTMP_BASE"]
        ?? String(format: "rtmp://%@:1935/cam%02d/", lan, startSlot)

    do {
        let session = try await connect(host: startHost, port: startPort)
        try await session.startStreaming(rtmpBase: startBase)
        // Release control deliberately: the camera keeps streaming without it,
        // and this isolates whether holding the socket destabilises SoC 1.
        await session.disconnect()
        print("started, control released — camera streams to \(startBase)")
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "stop":
    guard args.count > 1 else { usage() }
    let stopHost = args[1]
    let stopPort = args.count > 2 ? Int(args[2]) ?? 9989 : 9989
    do {
        let session = try await connect(host: stopHost, port: stopPort)
        do {
            try await session.stopStreaming()
            print("STOP acknowledged")
        } catch {
            print("STOP problem: \(error)")
        }
        if let mode = try? await session.requestCameraMode() {
            print("camera mode is now \(mode)")
        }
        await session.disconnect()
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "transcode":
    guard args.count > 2 else { usage() }
    let input = args[1]
    let output = args[2]
    let seconds = args.count > 3 ? Double(args[3]) ?? 30 : 30

    print("in   \(input)")
    print("out  \(output)")
    print("     ffmpeg copy → VideoToolbox decode → VideoToolbox encode → ffmpeg copy")
    print("")

    let lane = TranscodeLane(input: input, output: output)
    do {
        try lane.start()
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

    let started = Date()
    var lastReport = Date()
    while Date().timeIntervalSince(started) < seconds {
        try? await Task.sleep(for: .seconds(1))
        if Date().timeIntervalSince(lastReport) >= 5 {
            lastReport = Date()
            let s = lane.currentStats
            print(String(format: "  %5.0fs  in %5d  decoded %5d  encoded %5d  out %6.1f MB",
                         Date().timeIntervalSince(started),
                         s.framesIn, s.framesDecoded, s.framesEncoded,
                         Double(s.bytesOut) / 1e6))
        }
    }

    lane.stop()
    let final = lane.currentStats
    print("")
    print("frames in       \(final.framesIn)")
    print("frames decoded  \(final.framesDecoded)")
    print("frames encoded  \(final.framesEncoded)")
    print(String(format: "bytes out       %.1f MB", Double(final.bytesOut) / 1e6))
    exit(final.framesEncoded > 0 ? 0 : 1)

case "starttest":
    // One session, several destinations.
    //
    // This camera holds its single control session even after the client is
    // gone, so a failed attempt costs a power cycle. Testing one guess per
    // reboot is not a workable way to find out what it wants — so every
    // candidate is tried inside the one session we paid for, with a STOP
    // between them, and the first that is accepted wins.
    guard args.count > 1 else { usage() }
    let testHost = args[1]
    let testPort = args.count > 2 ? Int(args[2]) ?? 9989 : 9989

    guard let testLan = NetworkInterface.primaryIPv4() else {
        print("Could not determine this Mac's LAN address.")
        exit(1)
    }

    let candidates: [(String, String)] = [
        ("factory tool's exact string", "rtmp://\(testLan):1935/inputs/"),
        ("per-camera path we use",      "rtmp://\(testLan):1935/cam01/"),
        ("no trailing slash",           "rtmp://\(testLan):1935/inputs"),
        ("bare host, no app",           "rtmp://\(testLan):1935/"),
    ]

    do {
        let session = try await connect(host: testHost, port: testPort)
        print("")
        var winner: String?

        for (label, base) in candidates {
            print("  trying \(base)   — \(label)")
            do {
                try await session.startStreaming(rtmpBase: base)
                print("  ACCEPTED: \(base)")
                winner = base
                break
            } catch {
                print("  refused: \(error)")
                _ = try? await session.stopStreamingIgnoringErrors()
            }
        }

        if let winner {
            print("")
            print("The camera accepts: \(winner)")
            print("Holding control for 60s so the streams can arrive...")
            try? await Task.sleep(for: .seconds(60))
            await session.disconnect()
            exit(0)
        }

        print("")
        print("Every destination was refused. The problem is not the URL.")
        await session.disconnect()
        exit(1)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

case "tag":
    // The check can run the moment a camera is plugged in; which number is
    // painted on its case can be filled in afterwards, without touching the
    // camera again.
    guard args.count > 2, let tagNumber = Int(args[2]) else { usage() }
    let tagSerial = args[1]
    let tagArchive = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("camera-records", isDirectory: true)
    let tagFile = tagArchive.appendingPathComponent("\(tagSerial).json")

    guard let tagData = try? Data(contentsOf: tagFile) else {
        print("No record for \(tagSerial). Run `orahctl checkout` with it plugged in first.")
        exit(1)
    }

    let tagDecoder = JSONDecoder()
    tagDecoder.dateDecodingStrategy = .iso8601
    guard var tagRecord = try? tagDecoder.decode(CameraCheckout.Record.self, from: tagData) else {
        print("Could not read \(tagFile.lastPathComponent).")
        exit(1)
    }

    tagRecord.number = tagNumber
    let tagEncoder = JSONEncoder()
    tagEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    tagEncoder.dateEncodingStrategy = .iso8601
    try? tagEncoder.encode(tagRecord).write(to: tagFile)
    try? CameraCheckout.writeFleetSummary(in: tagArchive)
    print("\(tagSerial) is camera \(tagNumber).")
    exit(0)

case "restart":
    // For the camera that is holding a session nobody is on the other end of.
    // It refuses new connections with 503, but not always — it lets one through
    // now and then, and that is enough to tell it to reboot. So: keep trying,
    // and send the command the moment one gets in.
    guard args.count > 1 else { usage() }
    let restartHost = args[1]
    let restartPort = args.count > 2 ? Int(args[2]) ?? 9989 : 9989

    print("Waiting for a gap in \(restartHost)'s refusals — it lets one through now and then.")
    for attempt in 1...40 {
        if let session = try? await connect(host: restartHost, port: restartPort) {
            do {
                try await session.restart()
                print("Restart sent. It will be back in about a minute.")
                await session.disconnect()
                exit(0)
            } catch {
                print("  got in but could not send: \(error)")
                await session.disconnect()
            }
        }
        if attempt % 5 == 0 { print("  still refusing (\(attempt) tries)") }
        try? await Task.sleep(for: .seconds(3))
    }
    print("It refused every attempt for two minutes. This one needs its power pulled.")
    exit(1)

case "tag", "fleet", "renumber", "addresses":
    // Two small jobs on the archive, neither of which touches a camera.
    //
    // `fleet` exists because re-running a checkout purely to redraw the sheet
    // tags whatever happens to be plugged in at that moment — which is exactly
    // how a camera ended up recorded under someone else's number.
    let archiveDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("camera-records", isDirectory: true)

    if command == "tag" {
        guard args.count > 2, let newNumber = Int(args[2]) else { usage() }
        let serial = args[1]
        let file = archiveDirectory.appendingPathComponent("\(serial).json")

        guard let data = try? Data(contentsOf: file) else {
            print("No record for \(serial). Run `orahctl checkout` with it plugged in first.")
            exit(1)
        }
        let recordDecoder = JSONDecoder()
        recordDecoder.dateDecodingStrategy = .iso8601
        guard var record = try? recordDecoder.decode(CameraCheckout.Record.self, from: data) else {
            print("Could not read \(file.lastPathComponent).")
            exit(1)
        }

        let was = record.number.map { "was \($0)" } ?? "was unnumbered"
        record.number = newNumber

        let recordEncoder = JSONEncoder()
        recordEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        recordEncoder.dateEncodingStrategy = .iso8601
        try? recordEncoder.encode(record).write(to: file)
        print("\(serial) is camera \(newNumber) (\(was)).")
    }

    do {
        try CameraCheckout.writeFleetSummary(in: archiveDirectory)
        if command == "addresses" {
            try CameraCheckout.writeAddressPlan(in: archiveDirectory)
            print("\(archiveDirectory.appendingPathComponent("ADDRESSES.md").path)")
            exit(0)
        }
        if command == "renumber" {
            try CameraCheckout.writeRenumberPlan(in: archiveDirectory)
            print("\(archiveDirectory.appendingPathComponent("RENUMBER.md").path)")
            exit(0)
        }
        print("\(archiveDirectory.appendingPathComponent("FLEET.md").path)")
        exit(0)
    } catch {
        print("Could not write the fleet sheet: \(error)")
        exit(1)
    }

case "deskcheck":
    // Answers one question: does a picture published to RTMP come back out of
    // the switcher's monitor tap? That is the whole path the desk depends on —
    // read, decode, composite, tap — with the interface left out of it, so a
    // black monitor can be pinned on the pipeline or on the view, not guessed at.
    guard args.count > 1 else { usage() }
    let base = args[1]
    let seconds = args.count > 2 ? Double(args[2]) ?? 20 : 20

    do {
        let switcher = try Switcher()
        let camera = CameraSource(slot: 1)

        let counter = MonitorCounter()
        switcher.onMonitorFrame = { program, _, _, _ in counter.record(program) }

        try camera.attach(to: switcher, rtmpBase: base)
        switcher.setProgram(slot: 1)
        switcher.start()

        print("reading  \(base){0_0,0_1,1_0,1_1}")
        print("")

        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .seconds(2))
            print(String(format: "  %4.0fs  read %5d  monitor frames %5d  %@",
                         Date().timeIntervalSince(started),
                         camera.framesIn,
                         counter.count,
                         counter.description))
        }

        camera.stop()
        switcher.stop()

        print("")
        if counter.count == 0 {
            print("NO PICTURE reached the monitor tap.")
            print(camera.framesIn == 0
                  ? "Nothing was read from RTMP either — the stream is not arriving."
                  : "Frames were read but none came out composited — decode or composite.")
            exit(1)
        }
        print("Picture reaches the monitor tap: \(counter.count) frames, \(counter.description)")
        exit(0)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }

default:
    usage()
}

/// Counts what arrives at the monitor tap, from the switcher's pump thread.
final class MonitorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var width = 0
    private var height = 0

    func record(_ buffer: CVPixelBuffer?) {
        guard let buffer else { return }
        lock.withLock {
            frames += 1
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
        }
    }

    var count: Int { lock.withLock { frames } }

    var description: String {
        lock.withLock { width == 0 ? "no frames" : "\(width)×\(height)" }
    }
}

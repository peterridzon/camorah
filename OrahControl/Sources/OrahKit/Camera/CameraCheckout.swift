import Foundation

/// Acceptance check for one camera.
///
/// Built for the job of going through a shelf of cameras one at a time: plug one
/// in, run one command, get a verdict and an archived calibration. Everything it
/// does is read-only — no camera setting is ever written.
public struct CameraCheckout: Sendable {

    public enum Verdict: String, Sendable {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
    }

    public struct Check: Sendable {
        public let name: String
        public let verdict: Verdict
        public let detail: String
    }

    public struct Record: Sendable, Codable {
        public var serial = ""
        public var model = ""
        public var serviceName = ""
        public var host = ""
        public var port = 0
        public var secondSocHost: String?
        public var firmware: String?
        public var hardware: String?
        public var cameraName: String?
        public var sensors: Int?
        public var socs: Int?
        public var mode: String?

        /// Both SoCs, by address and MAC. A camera is two network interfaces on
        /// consecutive addresses, and a DHCP reservation is needed for each.
        public var interfaces: [String: String] = [:]

        /// When this camera was last seen actually streaming, and how much of
        /// it arrived. Everything else in this record is what the camera says
        /// about itself; this is the only field that is a picture on a screen.
        public var streamTestedAt: Date?
        public var streamLensesSeen: Int?
        public var packetLossPercent: Double?
        public var roundTripMilliseconds: Double?
        public var gatewayRoundTripMilliseconds: Double?
        public var overWiFi: Bool?

        /// The number written on the physical camera. Serial numbers are what
        /// the software matches on, but nobody on a show floor reads serials off
        /// a case — they read the number someone wrote on it.
        public var number: Int?
        public var rememberedStreamURLs: [String] = []
        public var audioChannels: Int?
        public var audioGainsDB: [Float] = []
        public var cameraClockUnix: UInt64?
        public var clockOffsetSeconds: Int64?
        public var calibrationFile: String?
        public var calibrationBytes: Int?
        public var checkedAt = Date()
        public var verdict = "FAIL"
        public var notes: [String] = []
    }

    /// How long a camera needs to be up before its timings mean anything.
    /// Measured across the fleet — see the note where this is used.
    public static let settledAfterSeconds: UInt64 = 120

    /// Whether the camera was actually reached. A check that never got that far
    /// has learned nothing about it, and must not be written over what an
    /// earlier check did learn.
    public private(set) var reachedCamera = false

    public private(set) var checks: [Check] = []
    public private(set) var record = Record()

    public init() {}

    private mutating func add(_ name: String, _ verdict: Verdict, _ detail: String) {
        checks.append(Check(name: name, verdict: verdict, detail: detail))
        if verdict != .pass { record.notes.append("\(name): \(detail)") }
    }

    /// Runs the full survey against an already-discovered camera.
    ///
    /// Everything happens over **one** control connection, on purpose. Opening and
    /// closing a session per command wedged four separate cameras during a day of
    /// debugging — they kept answering ping and Bonjour but refused control until
    /// power-cycled (MEASUREMENTS M5). One connection, one visit.
    ///
    /// `streamSeconds` above zero also exercises streaming inside that same
    /// session: start, watch the paths appear, stop.
    public static func run(on camera: DiscoveredCamera,
                           archiveTo directory: URL,
                           slot: Int = 0,
                           number: Int? = nil,
                           streamSeconds: Double = 0,
                           publishTo publishHost: String? = nil,
                           pathsProbe: (@Sendable () async -> [String])? = nil) async -> CameraCheckout {
        var out = CameraCheckout()
        out.record.number = number
        out.record.serviceName = camera.serviceName
        out.record.host = camera.host
        out.record.port = camera.port

        // Identity comes from the advertised name — no command needed.
        if let parsed = CameraSession.identityFromServiceName(camera.serviceName) {
            out.record.model = parsed.model
            out.record.serial = parsed.serial
            out.add("identity", .pass, "\(parsed.model) \(parsed.serial)")
        } else {
            out.add("identity", .warn, "service name is not Model@SERIAL: \(camera.serviceName)")
            out.record.serial = camera.serviceName
        }

        // Stage one, before a single protocol command: is the link sound?
        //
        // Everything below this line reports nonsense over a bad link — the
        // handshake times out, START answers nothing, the stream stops after a
        // second — and all of it reads as a broken camera. Measure first.
        // Both halves of the camera, from the wire. The MAC is what a DHCP
        // reservation binds to, and it is the one identifier that survives the
        // camera being renamed, renumbered or re-addressed.
        for (host, mac) in await NetworkProbe.orahAddresses() {
            let ours = camera.host.split(separator: ".").prefix(3).joined(separator: ".")
            let theirs = host.split(separator: ".").prefix(3).joined(separator: ".")
            guard ours == theirs else { continue }
            // The second SoC sits on the address immediately above the first.
            let last = Int(camera.host.split(separator: ".").last ?? "") ?? -1
            let other = Int(host.split(separator: ".").last ?? "") ?? -2
            if other == last || other == last + 1 { out.record.interfaces[host] = mac }
        }
        if !out.record.interfaces.isEmpty {
            let list = out.record.interfaces.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            out.add("interfaces", .pass, list)
        }

        let link = await NetworkProbe.check(host: camera.host, port: camera.port)
        out.record.packetLossPercent = link.packetLossPercent
        out.record.roundTripMilliseconds = link.roundTripMilliseconds
        out.record.gatewayRoundTripMilliseconds = link.gatewayRoundTripMilliseconds
        out.record.overWiFi = link.isWireless

        switch link.packetLossPercent {
        case .none:
            out.add("network", .warn, "no answer to ping")
        case .some(let loss) where loss >= 2:
            let rtt = link.roundTripMilliseconds.map { String(format: ", %.1f ms", $0) } ?? ""
            out.add("network", .fail,
                    String(format: "%.1f%% packet loss%@ — fix the cable or the switch before", loss, rtt)
                    + " trusting anything below")
        case .some(let loss):
            // Always against the router, never on its own. Same path, same
            // moment, same air — the difference is the camera's, the absolute
            // number is the network's.
            var detail = String(format: "%.1f%% packet loss", loss)
            if let rtt = link.roundTripMilliseconds {
                detail += String(format: ", %.1f ms", rtt)
                if let gateway = link.gatewayRoundTripMilliseconds {
                    detail += String(format: " (router %.1f ms)", gateway)
                }
            }
            if link.isWireless { detail += " · this Mac is on Wi-Fi" }
            out.add("network", .pass, detail)
        }

        if !link.portOpen {
            out.add("control", .fail, "port \(camera.port) is not answering")
            out.record.verdict = Verdict.fail.rawValue
            return out
        }

        let session = CameraSession(discovered: camera)
        do {
            try await session.connect()
            out.reachedCamera = true
            out.add("control", .pass, "connected on port \(camera.port)")
        } catch {
            out.add("control", .fail, "\(error)")
            out.record.verdict = Verdict.fail.rawValue
            return out
        }

        // GET_CAMERA_INFO. The reference tool has this commented out, which is
        // why it was avoided for a long time — but asked of a camera that is
        // answering normally it works, and it is the only place the firmware
        // version exists. Read-only: it carries no fields to set.
        if let info = try? await session.requestCameraInfo() {
            out.record.firmware = info.softwareVersion
            out.record.hardware = info.hardwareVersion
            out.record.cameraName = info.name
            out.record.sensors = Int(info.sensorCount)
            out.record.socs = Int(info.socCount)
            if !info.model.isEmpty { out.record.model = info.model }
            if !info.serialNumber.isEmpty, info.serialNumber != out.record.serial {
                out.add("identity", .warn,
                        "advertised as `\(out.record.serial)`, reports `\(info.serialNumber)` "
                        + "— the camera's own answer is used")
                out.record.serial = info.serialNumber
            }

            out.add("firmware", .pass,
                    "\(info.softwareVersion) · hw \(info.hardwareVersion) · "
                    + "\(info.sensorCount) sensors, \(info.socCount) SoCs")
        } else {
            out.add("firmware", .warn, "no answer to GET_CAMERA_INFO")
        }

        if let mode = try? await session.requestCameraMode() {
            out.record.mode = "\(mode)"
            // A camera found already streaming is worth flagging: it will have
            // resumed on its own and may be publishing somewhere unexpected.
            out.add("mode", mode == .live ? .warn : .pass, "\(mode)")
        } else {
            out.add("mode", .warn, "no answer")
        }

        if let urls = try? await session.requestStreamURLs() {
            out.record.rememberedStreamURLs = urls
            out.add("remembered target", .pass,
                    urls.isEmpty ? "none" : urls.first!.replacingOccurrences(of: "/0_0", with: "/…"))
        } else {
            out.add("remembered target", .warn, "no answer")
        }

        if let gains = try? await session.requestAudioGains() {
            out.record.audioChannels = gains.count
            out.record.audioGainsDB = gains
            let text = gains.map { String(format: "%.0f", $0) }.joined(separator: "/")
            // Four channels is the ambisonic set; anything else needs a look.
            out.add("audio", gains.count == 4 ? .pass : .warn,
                    "\(gains.count) ch at \(text) dB")
        } else {
            out.add("audio", .warn, "no answer")
        }

        if let clock = try? await session.requestCameraTime() {
            out.record.cameraClockUnix = clock
            let offset = Int64(clock) - Int64(Date().timeIntervalSince1970)
            out.record.clockOffsetSeconds = offset
            // These cameras have no real-time clock; they boot at the epoch.
            out.add("clock", .pass, clock < 1_000_000
                    ? "unset (\(clock)s since boot) — expected"
                    : "offset \(offset)s from this Mac")
        } else {
            out.add("clock", .warn, "no answer")
        }

        // Calibration is the one artefact that cannot be recreated if lost.
        do {
            let saved = try await session.fetchFile(CamAPI.factoryCalibrationFile,
                                                    into: directory)
            let size = (try? Data(contentsOf: saved).count) ?? 0
            out.record.calibrationFile = saved.lastPathComponent
            out.record.calibrationBytes = size

            if let data = try? Data(contentsOf: saved),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pano = json["pano"] as? [String: Any],
               let inputs = pano["inputs"] as? [[String: Any]] {
                out.add("calibration", inputs.count == 4 ? .pass : .warn,
                        "\(size) bytes, \(inputs.count) inputs")
            } else {
                out.add("calibration", .warn, "\(size) bytes but could not be parsed")
            }
        } catch {
            out.add("calibration", .fail, "could not fetch: \(error)")
        }

        // Streaming test, still on the same connection.
        if streamSeconds > 0, let publishHost {
            let base = String(format: "rtmp://%@:1935/cam%02d/", publishHost, slot)
            do {
                try await session.startStreaming(rtmpBase: base)
                out.add("start streaming", .pass, base)

                try? await Task.sleep(for: .seconds(streamSeconds))

                if let probe = pathsProbe {
                    let live = await probe()
                    let mine = live.filter { $0.hasPrefix(String(format: "cam%02d/", slot)) }
                    // All four lenses must arrive; two means one SoC never made it.
                    out.add("streams arriving", mine.count == 4 ? .pass : (mine.isEmpty ? .fail : .warn),
                            "\(mine.count) of 4: \(mine.sorted().joined(separator: " "))")
                }

                do {
                    try await session.stopStreaming()
                    out.add("stop streaming", .pass, "camera returned to idle")
                } catch {
                    out.add("stop streaming", .warn, "\(error)")
                }
            } catch {
                out.add("start streaming", .fail, "\(error)")
            }
        }

        await session.disconnect()

        let worst = out.checks.map(\.verdict)
        out.record.verdict = worst.contains(.fail) ? Verdict.fail.rawValue
                           : worst.contains(.warn) ? Verdict.warn.rawValue
                           : Verdict.pass.rawValue
        return out
    }

    /// Human-readable report.
    public func report() -> String {
        var lines: [String] = []
        let title = record.serial.isEmpty ? record.serviceName : record.serial
        lines.append("")
        lines.append("  \(record.model.isEmpty ? "camera" : record.model)  \(title)  @ \(record.host)")
        lines.append("  " + String(repeating: "─", count: 58))
        for check in checks {
            let mark = check.verdict == .pass ? "ok  " : check.verdict == .warn ? "warn" : "FAIL"
            lines.append("  \(mark)  \(check.name.padding(toLength: 20, withPad: " ", startingAt: 0))\(check.detail)")
        }
        lines.append("  " + String(repeating: "─", count: 58))
        lines.append("  verdict: \(record.verdict)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The fleet sheet

extension CameraCheckout {

    /// Rebuilds `FLEET.md` from every record in the archive.
    ///
    /// Twenty-four cameras get checked one at a time, over days, by whoever has
    /// the PoE injector free. The per-camera JSON is the record; this is the
    /// page someone actually reads before a show — what is on the shelf, what
    /// firmware it runs, and which ones came back with something to look at.
    public static func writeFleetSummary(in directory: URL) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [Record] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Record.self, from: data)
        }
        // Numbered cameras first, in order; then anything unnumbered by serial.
        records.sort {
            switch ($0.number, $1.number) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return $0.serial < $1.serial
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"

        func dash(_ text: String?) -> String {
            guard let text, !text.isEmpty else { return "—" }
            return text
        }

        var out = """
        # Fleet

        Every camera that has been through `orahctl checkout`, newest check per
        serial. Re-run the check on a camera and this page updates.

        """

        // ── identity and firmware ───────────────────────────────────────────
        out += """
        ## Identity

        | # | Serial | Model | Name | Firmware | HW | Sensors | SoCs |
        |---|---|---|---|---|---|---|---|

        """
        for r in records {
            out += "| \(r.number.map(String.init) ?? "—") | `\(r.serial)` | \(dash(r.model)) "
                + "| \(dash(r.cameraName)) | \(dash(r.firmware)) | \(dash(r.hardware)) "
                + "| \(r.sensors.map(String.init) ?? "—") | \(r.socs.map(String.init) ?? "—") |\n"
        }

        // ── network ─────────────────────────────────────────────────────────
        out += """

        ## Network

        | # | Serial | Address | Packet loss | Round trip | Router | Up for | Link |
        |---|---|---|---|---|---|---|---|

        """
        for r in records {
            let loss = r.packetLossPercent.map {
                $0 >= 2 ? String(format: "**%.1f %%**", $0) : String(format: "%.1f %%", $0)
            } ?? "—"
            let rtt = r.roundTripMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—"
            let gateway = r.gatewayRoundTripMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—"
            let over = r.overWiFi.map { $0 ? "Wi-Fi" : "wired" } ?? "—"
            // Timings taken before the camera has settled are shown in
            // parentheses: recorded, but not to be read as the camera's link.
            let settled = (r.cameraClockUnix ?? 0) >= Self.settledAfterSeconds
            let shownTrip = settled ? rtt : "(\(rtt))"
            let uptime = r.cameraClockUnix.map { "\($0)s" } ?? "—"
            out += "| \(r.number.map(String.init) ?? "—") | `\(r.serial)` | \(dash(r.host)) "
                + "| \(loss) | \(shownTrip) | \(gateway) | \(uptime) | \(over) |\n"
        }

        // ── state ───────────────────────────────────────────────────────────
        out += """

        ## State

        | # | Serial | Mode | Remembered stream target | Clock | Checked | Verdict |
        |---|---|---|---|---|---|---|

        """
        for r in records {
            let target = r.rememberedStreamURLs.first.map { url -> String in
                let trimmed = url.replacingOccurrences(of: "/0_0", with: "/…")
                return "`\(trimmed)`"
            } ?? "none"
            let clock = r.cameraClockUnix.map { seconds -> String in
                // A camera with no clock reports seconds since boot, which is a
                // small number. Anything near real Unix time has been set.
                seconds < 1_000_000 ? "unset (\(seconds)s since boot)" : "set"
            } ?? "—"
            let verdict = r.verdict == "PASS" ? "PASS" : "**\(r.verdict)**"
            out += "| \(r.number.map(String.init) ?? "—") | `\(r.serial)` | \(dash(r.mode)) "
                + "| \(target) | \(clock) | \(stamp.string(from: r.checkedAt)) | \(verdict) |\n"
        }

        // ── audio and calibration ───────────────────────────────────────────
        out += """

        ## Audio and calibration

        | # | Serial | Channels | Gain per channel (dB) | Calibration | Streamed | Archived as |
        |---|---|---|---|---|---|---|

        """
        for r in records {
            let gains = r.audioGainsDB.isEmpty
                ? "—"
                : r.audioGainsDB.map { String(format: "%.0f", $0) }.joined(separator: " / ")
            let size = r.calibrationBytes.map { "\($0) B" } ?? "—"
            let streamed = r.streamTestedAt.map { when in
                let lenses = r.streamLensesSeen ?? 0
                return "\(lenses)/4 · \(stamp.string(from: when))"
            } ?? "not yet"
            out += "| \(r.number.map(String.init) ?? "—") | `\(r.serial)` "
                + "| \(r.audioChannels.map(String.init) ?? "—") | \(gains) | \(size) "
                + "| \(streamed) | \(r.calibrationFile.map { "`\($0)`" } ?? "—") |\n"
        }

        // ── what differs ────────────────────────────────────────────────────
        //
        // The point of a fleet sheet is not the rows, it is the odd one out.
        var differences: [String] = []

        let firmwares = Set(records.compactMap(\.firmware))
        if firmwares.count > 1 {
            differences.append("**Firmware is not uniform:** "
                + firmwares.sorted().joined(separator: ", ")
                + ". Worth levelling before an event — these were not all updated together.")
        }

        let hardwares = Set(records.compactMap(\.hardware))
        if hardwares.count > 1 {
            differences.append("**Hardware revisions differ:** "
                + hardwares.sorted().joined(separator: ", ") + ".")
        }

        let gainSets = Set(records.map { $0.audioGainsDB.map { String(format: "%.0f", $0) }.joined(separator: "/") })
            .subtracting([""])
        if gainSets.count > 1 {
            differences.append("**Audio gain is not set the same everywhere:** "
                + gainSets.sorted().joined(separator: ", ")
                + ". Levels will not match between cameras until this is levelled.")
        }

        // A camera slower than the router *in its own measurement* is on a worse
        // link than the network it sits on. Comparing cameras against each other
        // does not work and produced two wrong cable diagnoses before this was
        // fixed: the Mac is joined over Wi-Fi, where the round trip swings by a
        // factor of five between one check and the next.
        for r in records {
            guard let camera = r.roundTripMilliseconds,
                  let gateway = r.gatewayRoundTripMilliseconds,
                  camera > gateway * 3, camera > 15 else { continue }

            // A camera in its first two minutes answers ICMP slowly because it
            // is still booting, and it comes back to normal on its own. Measured
            // across the fleet: under about 110 seconds of uptime every camera
            // reads 23–25 ms, over it every camera reads 5–8 ms, and the same
            // camera re-measured later drops to the same figure as the rest.
            // Two cables were changed for nothing before this was noticed.
            if let uptime = r.cameraClockUnix, uptime < Self.settledAfterSeconds {
                differences.append(String(
                    format: "**Camera %@ was measured %ds after power-up** and read %.1f ms "
                    + "against the router's %.1f ms. That is the camera still booting, not its "
                    + "link — re-check it once it has been up a couple of minutes.",
                    r.number.map(String.init) ?? r.serial, uptime, camera, gateway))
                continue
            }

            let who = r.number.map { "Camera \($0)" } ?? "`\(r.serial)`"
            differences.append(String(
                format: "**%@ answers slower than the router did in the same check:** "
                + "%.1f ms against %.1f ms, and it had been up %@. That difference is the "
                + "camera's own link.",
                who, camera, gateway,
                r.cameraClockUnix.map { "\($0)s" } ?? "long enough"))
        }

        if records.contains(where: { $0.overWiFi == true }) {
            differences.append("**This Mac was on Wi-Fi for some of these checks.** "
                + "Round-trip figures then measure the air as much as the camera, so "
                + "compare each camera with the router reading beside it, never with "
                + "another camera checked at a different time.")
        }

        // Swapping cameras one at a time leaves the departing camera's record in
        // the mDNS cache for a while, and a browse started moments later still
        // returns it. Twice this looked like two cameras sharing a name, and
        // both times the name belonged to the camera unplugged just before.
        //
        // So the advertised name is not evidence of anything here. Identity is
        // the serial the camera reports for itself, which is why the record
        // keeps that one. This only notes the disagreement so it is not
        // mistaken for a finding later.
        let stale = records.filter { record in
            guard let advertised = record.serviceName.split(separator: "@").last else { return false }
            return !advertised.isEmpty && String(advertised) != record.serial
        }
        if !stale.isEmpty {
            let who = stale.map { record in
                record.number.map { "camera \($0)" } ?? "`\(record.serial)`"
            }.joined(separator: ", ")
            differences.append("**Advertised name did not match the reported serial on \(who).** "
                + "Cameras were being swapped one at a time and the previous one's mDNS "
                + "record was still cached. The serial the camera reports for itself is "
                + "the identity used everywhere; the advertised name is not to be trusted "
                + "during a swap.")
        }

        // A camera resumes streaming to whatever it was last told, on its own,
        // as soon as it has power. One still pointed at a previous job's network
        // spends the first minutes of this one publishing into nothing — and the
        // desk shows it as a camera that will not start.
        let elsewhere = records.filter { record in
            guard let target = record.rememberedStreamURLs.first else { return false }
            guard let host = URL(string: target)?.host else { return false }
            // Same first two octets as the cameras themselves is close enough:
            // anything else is a different site.
            let ours = records.compactMap { $0.host.split(separator: ".").prefix(2).joined(separator: ".") }
            return !ours.contains(host.split(separator: ".").prefix(2).joined(separator: "."))
        }
        for r in elsewhere {
            let who = r.number.map { "Camera \($0)" } ?? "`\(r.serial)`"
            let target = r.rememberedStreamURLs.first ?? ""
            differences.append("**\(who) still points at another network:** `\(target)`. "
                + "It will try to publish there on power-up, reach nothing, and look "
                + "like a camera that refuses to start. Starting it here overwrites this.")
        }

        let sizes = Set(records.compactMap(\.calibrationBytes))
        if sizes.count > 1 {
            differences.append("**Calibration files differ in size** ("
                + sizes.sorted().map(String.init).joined(separator: ", ")
                + " bytes), which is expected: calibration is per unit. "
                + "`tools/fleet-report.py` compares them properly.")
        }

        if !differences.isEmpty {
            out += "\n## What differs across the fleet\n\n"
            for line in differences { out += "- \(line)\n" }
        }

        // ── anything that failed ────────────────────────────────────────────
        let flagged = records.filter { $0.verdict != "PASS" || !$0.notes.isEmpty }
        if !flagged.isEmpty {
            out += "\n## Worth looking at\n\n"
            for r in flagged {
                let who = r.number.map { "camera \($0) (`\(r.serial)`)" } ?? "`\(r.serial)`"
                out += "- **\(who)** — \(r.verdict)\n"
                for note in r.notes { out += "  - \(note)\n" }
            }
        }

        let passed = records.filter { $0.verdict == "PASS" }.count
        out += "\n\(records.count) camera\(records.count == 1 ? "" : "s") on record, "
            + "\(passed) passing.\n"

        try out.write(to: directory.appendingPathComponent("FLEET.md"),
                      atomically: true, encoding: .utf8)
    }
}

// MARK: - Renumbering

extension CameraCheckout {

    /// Works out what number each camera should carry, and writes the sheet the
    /// labels get made from.
    ///
    /// The numbers on these cases came from three different jobs and have gaps.
    /// Renumbering closes them, and the order is chosen so the gaps that remain
    /// are meaningful: cameras that are ready first, cameras missing their
    /// calibration last, so "the high numbers are the awkward ones" is true by
    /// construction rather than by memory.
    ///
    /// The serial goes on the label too. It is the only identifier the camera
    /// itself agrees with — the advertised Bonjour name has already been seen to
    /// disagree, and a number painted on a case is only as good as the person
    /// who painted it.
    public static func writeRenumberPlan(in directory: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        var records: [Record] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Record.self, from: data)
        }

        // Ready first, then the ones missing calibration. Within each group keep
        // the old numbering order, so nobody has to relearn which camera is
        // which any more than necessary.
        func rank(_ r: Record) -> (Int, Int) {
            let group = r.calibrationBytes == nil ? 1 : 0
            return (group, r.number ?? 9_999)
        }
        records.sort { rank($0) < rank($1) }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"

        var out = """
        # Renumbering plan

        Generated by `orahctl renumber` on \(stamp.string(from: Date())).

        Cameras with everything in order take the low numbers. Cameras missing
        their calibration take the last ones, so the awkward units are always at
        the end of the range instead of scattered through it.

        The serial belongs on the label as well as the number. It is the only
        identifier the camera itself will confirm: the name it advertises over
        Bonjour has been seen to disagree with it, and a painted number is only
        as reliable as the last person to paint one.

        ## Labels

        | New | Was | Print on the label | Calibration |
        |---|---|---|---|

        """

        var assigned = 0
        for r in records {
            assigned += 1
            let was = r.number.map(String.init) ?? "—"
            let calibration = r.calibrationBytes.map { "\($0) B" } ?? "**none**"
            out += "| **\(assigned)** | \(was) | `\(assigned)  ·  \(r.serial)` | \(calibration) |\n"
        }

        let missing = records.filter { $0.calibrationBytes == nil }
        if !missing.isEmpty {
            out += "\n## The last \(missing.count) in the range have no calibration\n\n"
            for (offset, r) in missing.enumerated() {
                let number = records.count - missing.count + offset + 1
                out += "- **\(number)** — `\(r.serial)`, was camera \(r.number.map(String.init) ?? "—")\n"
            }
            out += "\nThey stream normally and are usable. What they are missing is the\n"
            out += "measurement of their own lenses; see [CALIBRATION.md](../docs/CALIBRATION.md)\n"
            out += "for how to make one, which needs a scene with texture and a rig preset\n"
            out += "from any healthy unit.\n"
        }

        out += """

        ## Then rename them

        Each camera also carries a name it announces over Bonjour, and right now
        they all answer to `My 360 Camera`. Setting it to the new number makes
        the camera agree with its label, which is the whole point of doing this:

            orahctl rename <host> "Orah 07"

        `Cam.SET_CAMERA_NAME` is a write to the camera and it is reversible —
        set it again and it changes again. Nothing else about the camera moves.

        ## Not on this list

        Cameras that never reached the network have no record here, because
        nothing is known about them beyond the number written on the case. They
        cannot be renumbered from software — the serial has to come off the unit
        itself, or from whatever it says once it runs again.

        """

        try out.write(to: directory.appendingPathComponent("RENUMBER.md"),
                      atomically: true, encoding: .utf8)
    }
}

// MARK: - Fixed addresses

extension CameraCheckout {

    /// Writes the DHCP reservations for the whole fleet.
    ///
    /// The camera has no way to be given a static address: its protocol carries
    /// commands for video, audio, files, firmware and its own name, and nothing
    /// at all about the network. So the address has to be fixed from the other
    /// end, by binding each MAC to an address on the router.
    ///
    /// Worth doing rather than relying on discovery. Bonjour is multicast, and
    /// multicast from a wireless client to wired devices is exactly what access
    /// points drop — measured here as three cameras present and one advertised.
    /// With reservations the app does not have to find anything: it reads the
    /// roster and connects.
    public static func writeAddressPlan(in directory: URL, firstAddress: Int = 101) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        var records: [Record] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Record.self, from: data)
        }
        records.sort { ($0.number ?? 9_999) < ($1.number ?? 9_999) }

        var out = """
        # Fixed addresses

        The cameras cannot be given a static address — their protocol has no
        network commands at all. These are **DHCP reservations**: bind each MAC
        to an address on the router and the camera lands there every time,
        without anything changing inside it.

        Two per camera. Each one is two SoCs on consecutive addresses, and the
        control port lives on the lower of the pair.

        | # | Serial | Reserve | For MAC | Role |
        |---|---|---|---|---|

        """

        var next = firstAddress
        var missing: [Record] = []

        for record in records {
            guard !record.interfaces.isEmpty else { missing.append(record); continue }
            let sorted = record.interfaces.sorted { $0.key < $1.key }
            for (offset, pair) in sorted.enumerated() {
                let role = offset == 0 ? "control + video" : "video only"
                out += "| \(record.number.map(String.init) ?? "—") | `\(record.serial)` "
                    + "| `.\(next)` | `\(pair.value)` | \(role) |\n"
                next += 1
            }
            // A gap between cameras leaves room to add the second SoC later for
            // any unit that was only half seen.
            if sorted.count == 1 { next += 1 }
        }

        if !missing.isEmpty {
            out += "\n## No MAC recorded yet\n\n"
            out += "These were checked before addresses were being collected. "
            out += "Run `orahctl checkout` on each once more and they will fill in.\n\n"
            for record in missing {
                out += "- \(record.number.map { "camera \($0)" } ?? "unnumbered") "
                    + "— `\(record.serial)`\n"
            }
        }

        out += """

        ## Then the roster stops guessing

        With reservations in place the app does not need discovery at all: the
        roster carries the address, and a camera that does not answer at its own
        address is missing rather than merely unannounced. That is a much more
        useful thing to be told during a rig.

        """

        try out.write(to: directory.appendingPathComponent("ADDRESSES.md"),
                      atomically: true, encoding: .utf8)
    }
}

// MARK: - Reading older records

extension CameraCheckout.Record {

    /// Decoded field by field, every one of them optional.
    ///
    /// Swift's synthesised decoder requires a key to be present even when the
    /// property has a default value — it does not fall back to it. So adding one
    /// field to this record made every file written before it unreadable, and
    /// the fleet quietly forgot fifteen of sixteen cameras.
    ///
    /// These records are the only memory of which camera is which, collected one
    /// unplugging at a time. They have to survive the software growing around
    /// them, so nothing here is required and a missing key means "not known yet".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        func optional<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        self.init()
        serial = value(.serial, "")
        model = value(.model, "")
        serviceName = value(.serviceName, "")
        host = value(.host, "")
        port = value(.port, 0)
        secondSocHost = optional(.secondSocHost)
        firmware = optional(.firmware)
        hardware = optional(.hardware)
        cameraName = optional(.cameraName)
        sensors = optional(.sensors)
        socs = optional(.socs)
        mode = optional(.mode)
        interfaces = value(.interfaces, [:])
        streamTestedAt = optional(.streamTestedAt)
        streamLensesSeen = optional(.streamLensesSeen)
        packetLossPercent = optional(.packetLossPercent)
        roundTripMilliseconds = optional(.roundTripMilliseconds)
        gatewayRoundTripMilliseconds = optional(.gatewayRoundTripMilliseconds)
        overWiFi = optional(.overWiFi)
        number = optional(.number)
        rememberedStreamURLs = value(.rememberedStreamURLs, [])
        audioChannels = optional(.audioChannels)
        audioGainsDB = value(.audioGainsDB, [])
        cameraClockUnix = optional(.cameraClockUnix)
        clockOffsetSeconds = optional(.clockOffsetSeconds)
        calibrationFile = optional(.calibrationFile)
        calibrationBytes = optional(.calibrationBytes)
        checkedAt = value(.checkedAt, Date(timeIntervalSince1970: 0))
        verdict = value(.verdict, "FAIL")
        notes = value(.notes, [])
    }
}

// MARK: - Recording that a camera really streamed

extension CameraCheckout {

    /// Stamps a camera's record with the fact that its pictures arrived.
    ///
    /// Everything else in a record is the camera describing itself. This is the
    /// only part that cannot be claimed — it is written when the streams are
    /// actually on the wire, so "streamed 4/4" in the fleet sheet means somebody
    /// saw four pictures, not that a command was accepted.
    public static func noteStreamed(serial: String, lenses: Int, in directory: URL) {
        let file = directory.appendingPathComponent("\(serial).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: file),
              var record = try? decoder.decode(Record.self, from: data)
        else { return }

        // Only ever improve it: a camera that once managed four lenses has
        // proved it can, and a later two-lens start does not unprove it.
        if let seen = record.streamLensesSeen, seen >= lenses, record.streamTestedAt != nil {
            return
        }
        record.streamLensesSeen = lenses
        record.streamTestedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(record).write(to: file)
    }
}

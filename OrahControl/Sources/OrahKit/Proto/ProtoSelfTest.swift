import Foundation

/// Byte-level conformance checks for the hand-rolled protobuf codec.
///
/// Every expected value below was produced by the canonical Google protobuf
/// implementation from `proto/CamAPI.proto` (see `orahctl selftest`). If the
/// firmware contract ever comes into question, these vectors are the ground truth.
///
/// This lives in the library rather than a test target because the machine has
/// only Command Line Tools installed, where XCTest is unavailable.
public enum ProtoSelfTest {

    public struct Result {
        public var passed: [String] = []
        public var failed: [(name: String, detail: String)] = []
        public var ok: Bool { failed.isEmpty }
    }

    public static func run() -> Result {
        var r = Result()

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { r.passed.append(name) }
            else { r.failed.append((name, detail())) }
        }

        func checkEncoding(_ name: String, _ produced: Data, _ expectedHex: String) {
            let got = produced.hexString
            check(name, got == expectedHex, "expected \(expectedHex), got \(got)")
        }

        // ── Encoding: must match Google protobuf byte for byte ────────────────
        checkEncoding("startVideo",
                      CamAPI.startVideo(url: "rtmp://192.168.1.10:1935/cam01/"),
                      "3a230801121f72746d703a2f2f3139322e3136382e312e31303a313933352f63616d30312f")

        checkEncoding("stopVideo", CamAPI.stopVideo(), "3a020802")
        checkEncoding("getCameraInfo", CamAPI.getCameraInfo(), "8a01020806")
        checkEncoding("getCameraMode", CamAPI.getCameraMode(), "8a01020801")
        checkEncoding("audioSync", CamAPI.audioSync(), "8a01020815")

        checkEncoding("getFile(factory)",
                      CamAPI.getFile(CamAPI.factoryCalibrationFile),
                      "5a1d08011a19666163746f72795072657365747350726f6a6563742e707476")

        checkEncoding("getFile(rig)",
                      CamAPI.getFile(CamAPI.rigParametersFile),
                      "5a1608011a12726967506172616d65746572732e6a736f6e")

        // Read-only inspection commands. Their whole safety argument is that they
        // carry no payload — an AUDIO_GAIN with values would *set* the gains, and
        // a CAMERA_TIME with a time would move the camera's clock. These vectors
        // are what proves the bytes stay empty.
        checkEncoding("getStreamURL", CamAPI.getStreamURL(), "3a02080a")
        checkEncoding("getAudioGain (read, no values)", CamAPI.getAudioGain(), "8a01020814")
        checkEncoding("getCameraTime (read, no value)", CamAPI.getCameraTime(), "8a01020809")

        // ── Decoding: parse bytes the real camera would send ──────────────────
        func decode(_ hex: String) -> CamAPI.Message? {
            guard let d = Data(hexString: hex) else { return nil }
            return try? CamAPI.decode(d)
        }

        if case .videoReply(let op, let ret, let urls) = decode("420408011001") {
            check("decode videoReply success", op == .start && ret == .success && urls.isEmpty,
                  "got op=\(op) ret=\(ret) urls=\(urls)")
        } else {
            check("decode videoReply success", false, "wrong message case")
        }

        if case .videoReply(_, let ret, let urls) =
            decode("4220080110062a0c72746d703a2f2f612f305f302a0c72746d703a2f2f612f305f31") {
            check("decode videoReply repeated urls",
                  ret == .noVideoRunning && urls == ["rtmp://a/0_0", "rtmp://a/0_1"],
                  "got ret=\(ret) urls=\(urls)")
        } else {
            check("decode videoReply repeated urls", false, "wrong message case")
        }

        if case .camReply(let ret, let info, let mode, _, _) =
            decode("92013210011a2c0a0368773112057377322e331a0a4f7261682d46726f6e74220a534e31323334353637382a023469300438022002") {
            check("decode camReply info",
                  ret == .success
                  && info?.hardwareVersion == "hw1"
                  && info?.softwareVersion == "sw2.3"
                  && info?.name == "Orah-Front"
                  && info?.serialNumber == "SN12345678"
                  && info?.model == "4i"
                  && info?.sensorCount == 4
                  && info?.socCount == 2
                  && mode == .live,
                  "got ret=\(ret) info=\(String(describing: info)) mode=\(String(describing: mode))")
        } else {
            check("decode camReply info", false, "wrong message case")
        }

        if case .camReply(let ret, let info, _, _, _) = decode("9201021000") {
            check("decode camReply error", ret == .unknownError && info == nil, "got ret=\(ret)")
        } else {
            check("decode camReply error", false, "wrong message case")
        }

        if case .fsReply(let ret, let url) =
            decode("62311001422d687474703a2f2f3139322e3136382e312e35352f666163746f72795072657365747350726f6a6563742e707476") {
            check("decode fsReply success",
                  ret == .success && url == "http://192.168.1.55/factoryPresetsProject.ptv",
                  "got ret=\(ret) url=\(String(describing: url))")
        } else {
            check("decode fsReply success", false, "wrong message case")
        }

        if case .fsReply(let ret, _) = decode("62021005") {
            check("decode fsReply not found", ret == .fileNotFound, "got ret=\(ret)")
        } else {
            check("decode fsReply not found", false, "wrong message case")
        }

        if case .camReply(let ret, _, _, let time, let gains) =
            decode("92011c100138f096fdc406450000000045000060c0450000c0404500004441") {
            check("decode camReply time and gains",
                  ret == .success && time == 1_755_270_000
                  && gains.count == 4
                  && gains[0] == 0.0 && gains[1] == -3.5
                  && gains[2] == 6.0 && gains[3] == 12.25,
                  "got time=\(String(describing: time)) gains=\(gains)")
        } else {
            check("decode camReply time and gains", false, "wrong message case")
        }

        if case .event(let id) = decode("22020803") {
            check("decode event videoFail", id == .videoFail, "got \(id)")
        } else {
            check("decode event videoFail", false, "wrong message case")
        }

        // ── Wire-format edge cases ────────────────────────────────────────────
        check("multi-byte varint tag (field 17 → 0x8a01)",
              CamAPI.getCameraInfo().hexString.hasPrefix("8a01"))

        // Truncated input must throw, never crash or silently succeed.
        var threw = false
        do { _ = try CamAPI.decode(Data([0x3a, 0x7f, 0x01])) } catch { threw = true }
        check("truncated message throws", threw)

        // Unknown fields must be tolerated (proto2 forward compatibility).
        var unknownOK = true
        do { _ = try CamAPI.decode(Data([0xf8, 0x7f, 0x01])) } catch { unknownOK = false }
        check("unknown field tolerated", unknownOK)

        // Round-trip a large varint through the writer/reader pair.
        let big = ProtoWriter.build { $0.varint(1, UInt64(UInt32.max)) }
        var roundTripped: UInt64 = 0
        try? ProtoReader.walk(big) { f, v in if f == 1 { roundTripped = v.asUInt64 ?? 0 } }
        check("varint round-trip UInt32.max", roundTripped == UInt64(UInt32.max), "got \(roundTripped)")

        return r
    }
}

// MARK: - Hex helpers

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }
}

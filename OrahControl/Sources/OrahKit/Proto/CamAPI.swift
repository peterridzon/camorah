import Foundation

/// Swift mirror of the subset of `proto/CamAPI.proto` the control app actually uses.
///
/// Field numbers below are transcribed from that file and must not drift — the
/// camera firmware is the other half of this contract and cannot be changed.

public enum CamAPI {

    // MARK: - Enums (values straight from CamAPI.proto)

    public enum VideoOp: Int, Sendable {
        case unknown = 0
        case start = 1
        case stop = 2
        case getStreamURL = 10
    }

    public enum VideoRet: Int, Sendable {
        case unknownError = 0
        case success = 1
        case noVideoRunning = 6
    }

    public enum CamOp: Int, Sendable {
        case unknown = 0
        case getCameraMode = 1
        case restart = 4
        case shutdown = 5
        case getCameraInfo = 6
        case fwUp = 7
        case setCameraName = 8
        case cameraTime = 9
        case setUserInfo = 10
        case fwReset = 11
        case audioGain = 20
        case audioSync = 21
    }

    public enum CamRet: Int, Sendable {
        case unknownError = 0
        case success = 1
        case invalidSyntax = 2
        case invalidInputValue = 3
        case brokenLink = 4
    }

    public enum CameraMode: Int, Sendable {
        case unknown = 0
        case idle = 1
        case live = 2
        case usb = 6
        case fwUpgrade = 12
    }

    public enum FsOp: Int, Sendable {
        case unknown = 0
        case get = 1
        case put = 2
    }

    public enum FsRet: Int, Sendable {
        case unknownError = 0
        case success = 1
        case invalidSyntax = 2
        case unexpectedCommand = 3
        case invalidInputValue = 4
        case fileNotFound = 5
        case noSpace = 6
        case brokenLink = 7
    }

    public enum EventID: Int, Sendable {
        case unknown = 0
        case videoFail = 3
        case fwBrokenLink = 12
        case fwChecksumMismatch = 13
        case fwUpgraded = 14
    }

    // MARK: - Api envelope field numbers

    private enum ApiField {
        static let apiReply = 1
        static let event = 4
        static let video = 7
        static let videoReply = 8
        static let fs = 11
        static let fsReply = 12
        static let cam = 17
        static let camReply = 18
    }

    // MARK: - Well-known calibration files

    public static let factoryCalibrationFile = "factoryPresetsProject.ptv"
    public static let rigParametersFile = "rigParameters.json"

    // MARK: - Requests

    /// `Api{ video: Video{ op: START, url: <rtmp base> } }`
    ///
    /// The camera appends its own `<sensor>_<channel>` suffixes to this base URL,
    /// so passing `rtmp://host:1935/cam01/` yields `cam01/0_0` … `cam01/1_1`.
    public static func startVideo(url: String) -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.video) { v in
                v.varint(1, VideoOp.start.rawValue)
                v.string(2, url)
            }
        }
    }

    /// `Api{ video: Video{ op: STOP } }` — the command the Python tool never sent,
    /// which is why cameras there kept streaming after "stop".
    public static func stopVideo() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.video) { v in
                v.varint(1, VideoOp.stop.rawValue)
            }
        }
    }

    public static func getCameraInfo() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.cam) { c in
                c.varint(1, CamOp.getCameraInfo.rawValue)
            }
        }
    }

    /// Reboot the camera.
    ///
    /// The only way out of the state where it holds a control session for a
    /// client that is gone and refuses every new one with `503`. Until now that
    /// meant walking to the camera and pulling its PoE cable — which on a rig
    /// forty feet up is not a small thing.
    ///
    /// Recoverable by definition: the camera comes back in about a minute, with
    /// its calibration, its name and its remembered destination intact. Only the
    /// session it was stuck on is gone, which is the point.
    public static func restartCamera() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.cam) { c in
                c.varint(1, CamOp.restart.rawValue)
            }
        }
    }

    public static func getCameraMode() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.cam) { c in
                c.varint(1, CamOp.getCameraMode.rawValue)
            }
        }
    }

    /// Audio sync pulses. Firmware accepts this only once, after streaming starts.
    public static func audioSync() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.cam) { c in
                c.varint(1, CamOp.audioSync.rawValue)
            }
        }
    }

    /// `GET_STREAM_URL` — asks the camera where it is currently publishing.
    ///
    /// Read-only, and the direct answer to "this camera came up already streaming,
    /// but to where?". The reference tool never uses it.
    public static func getStreamURL() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.video) { v in
                v.varint(1, VideoOp.getStreamURL.rawValue)
            }
        }
    }

    /// `AUDIO_GAIN` with no values attached.
    ///
    /// The protocol states "current value returned if input is not set", so an
    /// empty request is a **read**, not a write. Returns one gain per channel,
    /// which also reveals how many audio channels the camera really has.
    public static func getAudioGain() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.cam) { c in
                c.varint(1, CamOp.audioGain.rawValue)
                // gain_db deliberately omitted — sending values would set them.
            }
        }
    }

    /// `CAMERA_TIME` with no time attached — same read-only rule as audio gain.
    /// Useful for judging how far the camera's clock has drifted from ours.
    public static func getCameraTime() -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.cam) { c in
                c.varint(1, CamOp.cameraTime.rawValue)
                // time deliberately omitted — sending it would set the clock.
            }
        }
    }

    public static func getFile(_ name: String) -> Data {
        ProtoWriter.build { api in
            api.message(ApiField.fs) { f in
                f.varint(1, FsOp.get.rawValue)
                f.string(3, name)
            }
        }
    }

    // MARK: - Replies

    public struct CameraInfo: Sendable, Equatable {
        public var hardwareVersion = ""
        public var softwareVersion = ""
        public var name = ""
        public var serialNumber = ""
        public var model = ""
        public var sensorCount = 0
        public var socCount = 0
    }

    public enum Message: Sendable {
        case apiReply
        case event(EventID)
        case videoReply(op: VideoOp, ret: VideoRet, urls: [String])
        case camReply(ret: CamRet, info: CameraInfo?, mode: CameraMode?,
                      time: UInt64?, gains: [Float])
        case fsReply(ret: FsRet, url: String?)
        case unknown(field: Int)
    }

    /// Decodes one `Api` envelope received from the camera.
    public static func decode(_ data: Data) throws -> Message {
        var result: Message = .unknown(field: -1)

        try ProtoReader.walk(data) { field, value in
            switch field {
            case ApiField.apiReply:
                result = .apiReply

            case ApiField.event:
                guard let body = value.asData else { return }
                var msg = EventID.unknown
                try ProtoReader.walk(body) { f, v in
                    if f == 1, let raw = v.asInt, let e = EventID(rawValue: raw) { msg = e }
                }
                result = .event(msg)

            case ApiField.videoReply:
                guard let body = value.asData else { return }
                var op = VideoOp.unknown
                var ret = VideoRet.unknownError
                var urls: [String] = []
                try ProtoReader.walk(body) { f, v in
                    switch f {
                    case 1: if let r = v.asInt, let o = VideoOp(rawValue: r) { op = o }
                    case 2: if let r = v.asInt, let x = VideoRet(rawValue: r) { ret = x }
                    case 5: if let s = v.asString { urls.append(s) }
                    default: break
                    }
                }
                result = .videoReply(op: op, ret: ret, urls: urls)

            case ApiField.camReply:
                guard let body = value.asData else { return }
                var ret = CamRet.unknownError
                var info: CameraInfo?
                var mode: CameraMode?
                var time: UInt64?
                var gains: [Float] = []
                try ProtoReader.walk(body) { f, v in
                    switch f {
                    case 2:
                        if let r = v.asInt, let x = CamRet(rawValue: r) { ret = x }
                    case 3:
                        guard let infoBody = v.asData else { return }
                        var ci = CameraInfo()
                        try ProtoReader.walk(infoBody) { g, w in
                            switch g {
                            case 1: ci.hardwareVersion = w.asString ?? ""
                            case 2: ci.softwareVersion = w.asString ?? ""
                            case 3: ci.name = w.asString ?? ""
                            case 4: ci.serialNumber = w.asString ?? ""
                            case 5: ci.model = w.asString ?? ""
                            case 6: ci.sensorCount = w.asInt ?? 0
                            case 7: ci.socCount = w.asInt ?? 0
                            default: break
                            }
                        }
                        info = ci
                    case 4:
                        if let r = v.asInt, let m = CameraMode(rawValue: r) { mode = m }
                    case 7:
                        time = v.asUInt64
                    case 8:
                        // proto2 leaves `repeated float` unpacked by default, one
                        // fixed32 per value, but packs it when the encoder chooses
                        // to. Accept both rather than guess which this firmware does.
                        switch v {
                        case .fixed32(let bits):
                            gains.append(Float(bitPattern: bits))
                        case .bytes(let packed):
                            var index = packed.startIndex
                            while index + 4 <= packed.endIndex {
                                var bits: UInt32 = 0
                                for shift in stride(from: 0, to: 32, by: 8) {
                                    bits |= UInt32(packed[index]) << UInt32(shift)
                                    index = packed.index(after: index)
                                }
                                gains.append(Float(bitPattern: bits))
                            }
                        default:
                            break
                        }
                    default:
                        break
                    }
                }
                result = .camReply(ret: ret, info: info, mode: mode,
                                   time: time, gains: gains)

            case ApiField.fsReply:
                guard let body = value.asData else { return }
                var ret = FsRet.unknownError
                var url: String?
                try ProtoReader.walk(body) { f, v in
                    switch f {
                    case 2: if let r = v.asInt, let x = FsRet(rawValue: r) { ret = x }
                    case 8: url = v.asString          // `bytes` on the wire, ASCII URL in practice
                    default: break
                    }
                }
                result = .fsReply(ret: ret, url: url)

            default:
                result = .unknown(field: field)
            }
        }

        return result
    }
}

import Foundation
import CoreMedia
import VideoToolbox

/// Hardware H.264 encoder for one output lane.
///
/// Configured for the one thing Vahana insists on: a **constant frame rate**.
/// Its RTMP reader states plainly that variable frame rate is unsupported, so
/// timing here is driven by a fixed grid rather than by whatever the input did.
/// Frame reordering is off as well — B-frames would buy a little bitrate and
/// cost latency the switcher cannot spare.
public final class H264Encoder {

    public enum EncoderError: Error, CustomStringConvertible {
        case sessionCreationFailed(OSStatus)
        case encodeFailed(OSStatus)

        public var description: String {
            switch self {
            case .sessionCreationFailed(let s): return "could not create compression session (OSStatus \(s))"
            case .encodeFailed(let s): return "encode failed (OSStatus \(s))"
            }
        }
    }

    public struct Settings {
        public var width: Int32
        public var height: Int32
        public var fps: Int32
        public var bitrate: Int
        public var keyframeIntervalSeconds: Double

        public init(width: Int32, height: Int32, fps: Int32 = 30,
                    bitrate: Int = 8_000_000, keyframeIntervalSeconds: Double = 1.0) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
            self.keyframeIntervalSeconds = keyframeIntervalSeconds
        }
    }

    /// Called for every encoded frame with Annex B bytes and whether it is a keyframe.
    public var onEncoded: ((Data, Bool, CMTime) -> Void)?

    public let settings: Settings
    private var session: VTCompressionSession?
    public private(set) var framesEncoded = 0

    public init(settings: Settings) throws {
        self.settings = settings
        try createSession()
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    private func createSession() throws {
        var created: VTCompressionSession?

        // Ask for a hardware encoder and refuse a software one. On this path a
        // software fallback would silently cost an order of magnitude more CPU.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: settings.width,
            height: settings.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created)

        guard status == noErr, let created else {
            throw EncoderError.sessionCreationFailed(status)
        }
        session = created

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(created, key: key, value: value)
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: settings.bitrate))

        // ExpectedFrameRate plus a fixed presentation grid is what produces CFR.
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.fps))

        let keyframeInterval = Int32(Double(settings.fps) * settings.keyframeIntervalSeconds)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            NSNumber(value: settings.keyframeIntervalSeconds))

        // DataRateLimits is deliberately NOT set. It imposes a hard cap that the
        // encoder honours by stalling `VTCompressionSessionEncodeFrame` — with
        // four lanes that measured 62 ms per tick and dragged a 30 fps pump down
        // to 7 fps. AverageBitRate already governs the rate; the hard cap only
        // adds a way to block the pump.

        VTCompressionSessionPrepareToEncodeFrames(created)

        // Asking for hardware is not the same as getting it, and the difference
        // is an order of magnitude of CPU.
        var hardware: CFTypeRef?
        VTSessionCopyProperty(created,
                              key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: kCFAllocatorDefault,
                              valueOut: &hardware)
        let isHardware = (hardware as? Bool) ?? false

        Log.info("encode", "session ready \(settings.width)×\(settings.height) "
                 + "@\(settings.fps) CFR, \(settings.bitrate / 1_000_000) Mb/s, "
                 + (isHardware ? "hardware" : "SOFTWARE — expect trouble"))
    }

    /// Encodes one frame. `pts` must sit on a fixed grid — Vahana rejects VFR.
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime,
                       forceKeyframe: Bool = false) throws {
        guard let session else { return }

        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let duration = CMTime(value: 1, timescale: settings.fps)
        var flagsOut = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flagsOut)

        if status != noErr {
            throw EncoderError.encodeFailed(status)
        }
    }

    public func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    fileprivate func emit(_ sampleBuffer: CMSampleBuffer) {
        let keyframe = isKeyframe(sampleBuffer)

        // Parameter sets ride with every keyframe so a decoder joining late,
        // or Vahana reconnecting mid-show, can start without waiting.
        guard let data = AnnexB.annexBData(from: sampleBuffer,
                                           includeParameterSets: keyframe) else { return }
        framesEncoded += 1
        onEncoded?(data, keyframe, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true    // no attachments at all means "not a dependent frame"
        }
        // Present and true means this frame depends on others, so it is not a keyframe.
        if let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
            return !dependsOnOthers
        }
        return true
    }
}

private let compressionCallback: VTCompressionOutputCallback = {
    refcon, _, status, _, sampleBuffer in
    guard let refcon, status == noErr, let sampleBuffer else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.emit(sampleBuffer)
}

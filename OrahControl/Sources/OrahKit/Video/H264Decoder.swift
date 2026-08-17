import Foundation
import CoreMedia
import VideoToolbox

/// Hardware H.264 decoder.
///
/// Frames come out as `CVPixelBuffer` backed by an IOSurface, which is what makes
/// the rest of the design possible: the same buffer can be turned into a Metal
/// texture without a copy, composited, and handed straight to the encoder. A
/// frame never travels through CPU memory — the rule the whole video path is
/// built on (see docs/SPECIFICATION.md §5.4).
public final class H264Decoder {

    public enum DecoderError: Error, CustomStringConvertible {
        case sessionCreationFailed(OSStatus)
        case noParameterSets

        public var description: String {
            switch self {
            case .sessionCreationFailed(let status):
                return "could not create decompression session (OSStatus \(status))"
            case .noParameterSets:
                return "stream carried no SPS/PPS"
            }
        }
    }

    /// Called for every decoded frame, on VideoToolbox's own queue.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    public private(set) var framesDecoded = 0
    public private(set) var framesDropped = 0

    public init() {}

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    public var isReady: Bool { session != nil }

    /// Dimensions once the parameter sets have been seen.
    public var dimensions: CMVideoDimensions? {
        format.map { CMVideoFormatDescriptionGetDimensions($0) }
    }

    // MARK: - Feeding

    /// Submits one access unit in Annex B form.
    public func decode(annexB: Data, pts: CMTime, duration: CMTime = .invalid) throws {
        let nals = AnnexB.split(annexB)
        guard !nals.isEmpty else { return }

        // Parameter sets can appear at any point; a stream may also change them
        // mid-flight, so always take the newest.
        var parameterSetsChanged = false
        for nal in nals {
            switch nal.type {
            case AnnexB.NALType.sps.rawValue:
                if sps != nal.payload { sps = nal.payload; parameterSetsChanged = true }
            case AnnexB.NALType.pps.rawValue:
                if pps != nal.payload { pps = nal.payload; parameterSetsChanged = true }
            default:
                break
            }
        }

        if parameterSetsChanged || session == nil {
            try rebuildSession()
        }

        guard let session, let format else {
            // Nothing decodable yet — normal while waiting for the first keyframe.
            return
        }

        let payload = AnnexB.avccData(from: nals)
        guard !payload.isEmpty else { return }

        guard let sampleBuffer = makeSampleBuffer(payload: payload, format: format,
                                                  pts: pts, duration: duration) else {
            return
        }

        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut)

        if status != noErr {
            framesDropped += 1
        }
    }

    public func flush() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    // MARK: - Session

    private func rebuildSession() throws {
        guard let sps, let pps else { return }   // wait for both
        guard let format = AnnexB.formatDescription(sps: sps, pps: pps) else {
            throw DecoderError.noParameterSets
        }
        self.format = format

        if let existing = session {
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
            session = nil
        }

        // IOSurface-backed output is what lets Metal wrap these with no copy.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created)

        guard status == noErr, let created else {
            throw DecoderError.sessionCreationFailed(status)
        }

        VTSessionSetProperty(created,
                             key: kVTDecompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)

        session = created

        let size = CMVideoFormatDescriptionGetDimensions(format)
        Log.info("decode", "session ready \(size.width)×\(size.height)")
    }

    private func makeSampleBuffer(payload: Data,
                                  format: CMVideoFormatDescription,
                                  pts: CMTime,
                                  duration: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: payload.count,
                                                     alignment: 1)
        payload.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self),
                          count: payload.count)

        // kCFAllocatorMalloc as the data deallocator hands ownership to CoreMedia,
        // so the block buffer frees this when the sample buffer dies.
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer)

        guard status == noErr, let blockBuffer else {
            bytes.deallocate()
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleSize = payload.count

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)

        return status == noErr ? sampleBuffer : nil
    }

    fileprivate func emit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        framesDecoded += 1
        onFrame?(pixelBuffer, pts)
    }

    fileprivate func noteDropped() {
        framesDropped += 1
    }
}

// VideoToolbox calls back through a C function pointer, so the instance travels
// in the refcon rather than being captured.
private let decompressionCallback: VTDecompressionOutputCallback = {
    refcon, _, status, _, imageBuffer, pts, _ in
    guard let refcon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()

    guard status == noErr, let imageBuffer else {
        decoder.noteDropped()
        return
    }
    decoder.emit(imageBuffer, pts: pts)
}

import Foundation
import CoreMedia

/// H.264 Annex B byte-stream handling.
///
/// FFmpeg hands us an elementary stream: NAL units separated by `00 00 01` or
/// `00 00 00 01` start codes. VideoToolbox wants something else entirely — a
/// `CMVideoFormatDescription` built from the parameter sets, and sample data
/// where each NAL carries a 4-byte big-endian length instead of a start code.
/// This translates between the two.
public enum AnnexB {

    /// H.264 NAL unit types we care about.
    public enum NALType: UInt8 {
        case slice = 1          // non-IDR picture
        case idr = 5            // IDR picture — a keyframe
        case sei = 6
        case sps = 7            // sequence parameter set
        case pps = 8            // picture parameter set
        case accessUnitDelimiter = 9
    }

    public struct NAL {
        public let type: UInt8
        public let payload: Data      // without start code, including the header byte

        public var isKeyframe: Bool { type == NALType.idr.rawValue }
        public var isParameterSet: Bool {
            type == NALType.sps.rawValue || type == NALType.pps.rawValue
        }
        /// A NAL that carries picture data, as opposed to metadata.
        public var isVCL: Bool { type >= 1 && type <= 5 }
    }

    /// Splits an Annex B buffer into NAL units.
    ///
    /// Handles both 3- and 4-byte start codes, which FFmpeg mixes freely — 4 bytes
    /// before parameter sets and access unit delimiters, 3 elsewhere.
    public static func split(_ data: Data) -> [NAL] {
        var nals: [NAL] = []
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count > 4 else { return nals }

        // Offsets where a NAL's payload begins, paired with the start code length.
        var starts: [Int] = []
        var i = 0
        while i + 3 <= count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                }
                if i + 4 <= count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }

        for (index, begin) in starts.enumerated() {
            // A NAL runs until the next start code, minus that code's leading zeros.
            var end = index + 1 < starts.count ? starts[index + 1] : count
            if index + 1 < starts.count {
                end -= 3
                if end > begin, end - 1 >= 0, bytes[end - 1] == 0 { end -= 1 }
            }
            guard end > begin else { continue }
            let payload = Data(bytes[begin..<end])
            guard let first = payload.first else { continue }
            nals.append(NAL(type: first & 0x1F, payload: payload))
        }

        return nals
    }

    /// Builds a format description from the parameter sets. VideoToolbox cannot
    /// decode a single byte until it has this.
    public static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?

        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]

                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description)
                    }
                }
            }
        }

        return status == noErr ? description : nil
    }

    /// Rewrites NALs into the length-prefixed layout VideoToolbox expects.
    /// Parameter sets are dropped: they live in the format description instead.
    public static func avccData(from nals: [NAL]) -> Data {
        var out = Data()
        for nal in nals where !nal.isParameterSet {
            var length = UInt32(nal.payload.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(nal.payload)
        }
        return out
    }

    /// The reverse, for handing encoded frames back to FFmpeg.
    public static func annexBData(from sampleBuffer: CMSampleBuffer,
                                  includeParameterSets: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var out = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])

        // A keyframe must be preceded by its parameter sets or no decoder
        // joining mid-stream will ever recover.
        if includeParameterSets,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var headerLength: Int32 = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
                if status == noErr, let pointer {
                    out.append(startCode)
                    out.append(pointer, count: size)
                }
            }
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == noErr,
              let base = dataPointer else { return nil }

        // Walk the length-prefixed NALs, swapping each length for a start code.
        var offset = 0
        base.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
            while offset + 4 <= totalLength {
                var length: UInt32 = 0
                memcpy(&length, bytes + offset, 4)
                length = UInt32(bigEndian: length)
                offset += 4
                guard length > 0, offset + Int(length) <= totalLength else { break }
                out.append(startCode)
                out.append(bytes + offset, count: Int(length))
                offset += Int(length)
            }
        }

        return out
    }
}

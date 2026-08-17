import Foundation
import Metal
import CoreVideo

/// Per-camera colour correction on the GPU, applied before the dissolve.
///
/// The dissolve blends two pictures; this changes one. Keeping them apart means
/// a grade is a property of a camera rather than of a transition, and a camera
/// that is neither on air nor in preview costs nothing at all.
///
/// **NV12 is the awkward part.** The decoder hands over luma at full size and
/// interleaved chroma at half, and almost nothing a shading panel does can be
/// expressed in that space honestly: lift, gamma and gain are per-channel in
/// RGB, and saturation and hue need all three channels at once. Working in Y'
/// alone would look approximately right and be wrong in exactly the cases that
/// matter — skin, saturated stage lighting, anything near clipping.
///
/// So the kernel does the conversion itself. One thread per chroma pixel reads
/// the 2×2 luma block that shares it, builds four RGB pixels, grades each, and
/// converts back — writing four luma samples and one averaged chroma. That is
/// the same subsampling the format already assumes, done once rather than
/// twice, and it stays entirely on the GPU.
public final class MetalGrader {

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Rec. 709, video range. The decoder gives 16–235 luma and 16–240 chroma;
    // grading full-range values as if they were 0–1 would crush the ends.
    inline float3 ycbcr_to_rgb(float y, float2 cbcr) {
        float  yy = (y - 16.0/255.0) * (255.0/219.0);
        float2 c  = (cbcr - 128.0/255.0) * (255.0/224.0);
        return float3(yy + 1.5748 * c.y,
                      yy - 0.1873 * c.x - 0.4681 * c.y,
                      yy + 1.8556 * c.x);
    }

    inline float3 rgb_to_ycbcr(float3 rgb) {
        float y  = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float cb = (rgb.b - y) / 1.8556;
        float cr = (rgb.r - y) / 1.5748;
        return float3(y * (219.0/255.0) + 16.0/255.0,
                      cb * (224.0/255.0) + 128.0/255.0,
                      cr * (224.0/255.0) + 128.0/255.0);
    }

    // g: exposure, gamma, black, lift.rgb, gamma.rgb, gain.rgb,
    //    contrast, pivot, saturation, hue
    inline float3 grade_pixel(float3 c, constant float *g) {
        // The lever first: it is the coarse control and everything after it is
        // trim on the result, which is the order a shading panel works in.
        c *= exp2(g[0] * 1.2);

        // Master black lifts or drops the floor without moving white.
        c = c * (1.0 - g[2]) + g[2];

        // Lift, gamma, gain — the order every grading system uses.
        c += float3(g[3], g[4], g[5]);
        c  = max(c, 0.0);
        float3 gm = 1.0 / max(float3(1.0) + float3(g[6], g[7], g[8]) + g[1], 0.05);
        c  = pow(c, gm);
        c *= float3(g[9], g[10], g[11]);

        // Contrast about a pivot, so raising it does not also raise exposure.
        c = (c - g[13]) * (1.0 + g[12]) + g[13];

        // Saturation against luma, then hue as a rotation of the chroma pair.
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(luma), c, g[14]);

        float a = g[15] * 3.14159265;
        if (abs(a) > 0.0001) {
            float cb = (c.b - luma) / 1.8556;
            float cr = (c.r - luma) / 1.5748;
            float s = sin(a), k = cos(a);
            float cb2 = cb * k - cr * s;
            float cr2 = cb * s + cr * k;
            c = float3(luma + 1.5748 * cr2,
                       luma - 0.1873 * cb2 - 0.4681 * cr2,
                       luma + 1.8556 * cb2);
        }
        return clamp(c, 0.0, 1.0);
    }

    kernel void grade_nv12(texture2d<float, access::read>  srcY  [[texture(0)]],
                           texture2d<float, access::read>  srcC  [[texture(1)]],
                           texture2d<float, access::write> dstY  [[texture(2)]],
                           texture2d<float, access::write> dstC  [[texture(3)]],
                           constant float                 *g     [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dstC.get_width() || gid.y >= dstC.get_height()) { return; }

        float2 cbcr = srcC.read(gid).rg;
        uint2 base = gid * 2;

        float3 sum = 0.0;
        float ys[4];
        for (uint i = 0; i < 4; ++i) {
            uint2 p = base + uint2(i & 1, i >> 1);
            float y = srcY.read(min(p, uint2(srcY.get_width() - 1,
                                             srcY.get_height() - 1))).r;
            float3 out = rgb_to_ycbcr(grade_pixel(ycbcr_to_rgb(y, cbcr), g));
            ys[i] = out.x;
            sum += out;
        }
        for (uint i = 0; i < 4; ++i) {
            uint2 p = base + uint2(i & 1, i >> 1);
            if (p.x < dstY.get_width() && p.y < dstY.get_height()) {
                dstY.write(float4(ys[i]), p);
            }
        }
        // One chroma sample for the block, averaged — the same subsampling the
        // format already carries, so nothing is invented and nothing is lost
        // twice.
        dstC.write(float4(sum.y * 0.25, sum.z * 0.25, 0, 1), gid);
    }
    """

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    public private(set) var framesGraded = 0
    public private(set) var framesPassedThrough = 0

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw MetalCompositor.CompositorError.pipelineCreationFailed("no command queue")
        }
        self.queue = queue

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch { throw MetalCompositor.CompositorError.shaderCompilationFailed("\(error)") }

        guard let function = library.makeFunction(name: "grade_nv12") else {
            throw MetalCompositor.CompositorError.shaderCompilationFailed("grade_nv12 not found")
        }
        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw MetalCompositor.CompositorError.pipelineCreationFailed("\(error)") }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw MetalCompositor.CompositorError.textureCacheFailed
        }
        textureCache = cache
    }

    /// Returns a graded copy, or the original when there is nothing to do.
    ///
    /// A neutral grade is the common case — most cameras on most shows — and it
    /// costs one comparison rather than a GPU pass and a buffer.
    public func grade(_ source: CVPixelBuffer, with grade: ColourGrade) throws -> CVPixelBuffer {
        guard !grade.isNeutral else {
            framesPassedThrough += 1
            return source
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let output = try makeOutputBuffer(width: width, height: height)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let srcY = texture(source, plane: 0, format: .r8Unorm),
              let srcC = texture(source, plane: 1, format: .rg8Unorm),
              let dstY = texture(output, plane: 0, format: .r8Unorm),
              let dstC = texture(output, plane: 1, format: .rg8Unorm) else {
            framesPassedThrough += 1
            return source
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(srcY, index: 0)
        encoder.setTexture(srcC, index: 1)
        encoder.setTexture(dstY, index: 2)
        encoder.setTexture(dstC, index: 3)

        var packed = grade.packed
        encoder.setBytes(&packed, length: MemoryLayout<Float>.size * packed.count, index: 0)

        let chromaWidth = CVPixelBufferGetWidthOfPlane(source, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(source, 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (chromaWidth + 15) / 16, height: (chromaHeight + 15) / 16, depth: 1),
            threadsPerThreadgroup: group)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        framesGraded += 1
        return output
    }

    // MARK: - Resources

    private func texture(_ buffer: CVPixelBuffer, plane: Int,
                         format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil,
                format, width, height, plane, &wrapped) == kCVReturnSuccess,
              let wrapped else { return nil }
        return CVMetalTextureGetTexture(wrapped)
    }

    private func makeOutputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else {
                throw MetalCompositor.CompositorError.pixelBufferPoolFailed(status)
            }
            pool = created; poolWidth = width; poolHeight = height
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw MetalCompositor.CompositorError.pixelBufferPoolFailed(status)
        }
        return buffer
    }
}

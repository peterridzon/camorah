import Foundation
import Metal
import CoreVideo

/// GPU cross-dissolve between two camera feeds.
///
/// This is where the transition actually happens. Frames arrive from the hardware
/// decoder as IOSurface-backed `CVPixelBuffer`s, get wrapped as Metal textures
/// without a copy, are blended on the GPU, and go straight to the hardware encoder
/// — the frame never touches the CPU, which is the rule the whole video path is
/// built on (specification §5.4).
///
/// The decoded format is NV12: a full-resolution luma plane and a half-resolution
/// interleaved chroma plane. Both must be blended, so each dispatch runs twice.
public final class MetalCompositor {

    public enum CompositorError: Error, CustomStringConvertible {
        case noDevice
        case shaderCompilationFailed(String)
        case pipelineCreationFailed(String)
        case textureCacheFailed
        case pixelBufferPoolFailed(OSStatus)
        case textureCreationFailed

        public var description: String {
            switch self {
            case .noDevice: return "no Metal device"
            case .shaderCompilationFailed(let m): return "shader would not compile: \(m)"
            case .pipelineCreationFailed(let m): return "pipeline failed: \(m)"
            case .textureCacheFailed: return "could not create Metal texture cache"
            case .pixelBufferPoolFailed(let s): return "pixel buffer pool failed (\(s))"
            case .textureCreationFailed: return "could not wrap pixel buffer as texture"
            }
        }
    }

    /// Blending happens in the stored video signal, not in linear light.
    ///
    /// Physically, a dissolve should mix light, which would mean converting to
    /// linear, blending, and converting back. Every hardware vision mixer blends
    /// in the signal domain instead, and a transition that behaves differently
    /// from the rest of the gallery's equipment looks wrong even when it is more
    /// "correct". So: signal domain, deliberately.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dissolve_plane(texture2d<float, access::read>  from  [[texture(0)]],
                               texture2d<float, access::read>  to    [[texture(1)]],
                               texture2d<float, access::write> dest  [[texture(2)]],
                               constant float&                 mix_t [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }
        float4 a = from.read(gid);
        float4 b = to.read(gid);
        dest.write(mix(a, b, mix_t), gid);
    }
    """

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    public private(set) var framesComposited = 0
    public private(set) var framesPassedThrough = 0

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw CompositorError.noDevice
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw CompositorError.pipelineCreationFailed("no command queue")
        }
        self.queue = queue

        // Compiled at runtime: without Xcode there is no build step that would
        // turn a .metal file into a default library.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw CompositorError.shaderCompilationFailed("\(error)")
        }

        guard let function = library.makeFunction(name: "dissolve_plane") else {
            throw CompositorError.shaderCompilationFailed("dissolve_plane not found")
        }

        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw CompositorError.pipelineCreationFailed("\(error)")
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw CompositorError.textureCacheFailed
        }
        textureCache = cache

        Log.info("metal", "compositor ready on \(device.name)")
    }

    // MARK: - Compositing

    /// Blends `from` towards `to` by `mix` (0 = entirely `from`, 1 = entirely `to`).
    ///
    /// At the extremes the corresponding input is returned untouched — outside a
    /// transition there is nothing to blend, and doing no GPU work at all is the
    /// cheapest possible path for the case that runs 99% of the time.
    public func composite(from: CVPixelBuffer,
                          to: CVPixelBuffer?,
                          mix: Float) throws -> CVPixelBuffer {
        guard let to, mix > 0.0001 else {
            framesPassedThrough += 1
            return from
        }
        if mix > 0.9999 {
            framesPassedThrough += 1
            return to
        }

        let width = CVPixelBufferGetWidth(from)
        let height = CVPixelBufferGetHeight(from)

        // Mixing two different geometries would produce nonsense; refuse rather
        // than silently stretch one of them.
        guard CVPixelBufferGetWidth(to) == width,
              CVPixelBufferGetHeight(to) == height else {
            framesPassedThrough += 1
            return from
        }

        let output = try makeOutputBuffer(width: width, height: height)

        guard let commandBuffer = queue.makeCommandBuffer() else {
            return from
        }

        // Plane 0 is luma at full size, plane 1 interleaved chroma at half.
        for plane in 0..<2 {
            let format: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
            let planeWidth = CVPixelBufferGetWidthOfPlane(from, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(from, plane)

            guard let fromTexture = texture(from, plane: plane, format: format),
                  let toTexture = texture(to, plane: plane, format: format),
                  let destTexture = texture(output, plane: plane, format: format) else {
                throw CompositorError.textureCreationFailed
            }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(fromTexture, index: 0)
            encoder.setTexture(toTexture, index: 1)
            encoder.setTexture(destTexture, index: 2)
            var t = mix
            encoder.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)

            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (planeWidth + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (planeHeight + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        // The encoder needs finished pixels, and a dropped transition frame is
        // worse than a fraction of a millisecond of waiting.
        commandBuffer.waitUntilCompleted()

        framesComposited += 1
        return output
    }

    // MARK: - Resources

    private func texture(_ buffer: CVPixelBuffer, plane: Int,
                         format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            format, width, height, plane, &wrapped)

        guard status == kCVReturnSuccess, let wrapped else { return nil }
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
            // A small pool: transitions are short, and holding many 4K-ish
            // buffers costs memory for nothing.
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                 poolAttributes as CFDictionary,
                                                 attributes as CFDictionary,
                                                 &created)
            guard status == kCVReturnSuccess, let created else {
                throw CompositorError.pixelBufferPoolFailed(status)
            }
            pool = created
            poolWidth = width
            poolHeight = height
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw CompositorError.pixelBufferPoolFailed(status)
        }
        return buffer
    }

    /// Releases textures the cache is holding. Worth calling between shows.
    public func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

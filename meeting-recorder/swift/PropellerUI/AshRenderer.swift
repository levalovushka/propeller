import AppKit
import Metal
import MetalKit
import SwiftUI

/// Ручки пепла живут в `Tokens.Motion.Ash` — здесь только их чтение.
private typealias Tune = Tokens.Motion.Ash

// MARK: - Параметры, разделяемые с шейдером
//
// Раскладка обязана совпадать с одноимёнными структурами в `Disintegrate.metal`
// байт в байт. Padding проставлен руками с обеих сторон, чтобы совпадение было
// видно глазом, а не выведено из правил выравнивания Metal.

private struct AshInitParams {
    var speedMin: Float
    var speedMax: Float
    var lifeMin: Float
    var lifeMax: Float
    var seed: UInt32
}

private struct AshUpdateParams {
    var grid: SIMD2<UInt32>
    var phase: Float
    var timeStep: Float
    var waveWindow: Float
    var waveDuration: Float
    var gravity: Float
    var pad: Float = 0
}

private struct AshDrawParams {
    var size: SIMD2<Float>
    var canvas: SIMD2<Float>
    var margin: SIMD2<Float>
    var grid: SIMD2<UInt32>
    var fadeTail: Float
    var pad: Float = 0
}

private struct AshParticleSlot {
    var offset: SIMD2<Float>
    var velocity: SIMD2<Float>
    var lifetime: Float
    var pad: Float
}

// MARK: - Движок

/// Устройство и пайплайны — один раз на процесс.
///
/// Собирать их на каждое удаление значит компилировать шейдеры в тот самый кадр,
/// в котором должна начаться анимация. Абсент означает «Metal здесь нет» —
/// вызывающая сторона просто заканчивает эффект мгновенно, как при Reduce Motion.
final class AshEngine {
    static let shared = AshEngine()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let initPipeline: MTLComputePipelineState
    let updatePipeline: MTLComputePipelineState
    let drawPipeline: MTLRenderPipelineState

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            AshLog.log.error("engine: no Metal device"); return nil
        }
        guard let queue = device.makeCommandQueue() else {
            AshLog.log.error("engine: no command queue"); return nil
        }
        guard let url = Bundle.main.url(forResource: "PropellerShaders", withExtension: "metallib") else {
            AshLog.log.error("engine: metallib not in bundle"); return nil
        }
        guard let library = try? device.makeLibrary(URL: url) else {
            AshLog.log.error("engine: metallib failed to load"); return nil
        }
        guard let initFn = library.makeFunction(name: "ashInit"),
              let updateFn = library.makeFunction(name: "ashUpdate"),
              let vertexFn = library.makeFunction(name: "ashVertex"),
              let fragmentFn = library.makeFunction(name: "ashFragment") else {
            AshLog.log.error("engine: missing functions, have \(library.functionNames)"); return nil
        }
        guard let initPipeline = try? device.makeComputePipelineState(function: initFn),
              let updatePipeline = try? device.makeComputePipelineState(function: updateFn) else {
            AshLog.log.error("engine: compute pipelines failed"); return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = Self.pixelFormat
        // Premultiplied source-over: растр строки уже premultiplied, и фрагмент
        // множит цвет целиком, так что таким и остаётся.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let drawPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            AshLog.log.error("engine: render pipeline failed"); return nil
        }
        AshLog.log.info("engine: ready on \(device.name)")

        self.device = device
        self.queue = queue
        self.initPipeline = initPipeline
        self.updatePipeline = updatePipeline
        self.drawPipeline = drawPipeline
    }

    /// Растр строки → текстура. Байты те же, что читал старый CPU-путь:
    /// RGBA8 premultiplied, строка 0 — верх.
    func texture(from image: CGImage) -> MTLTexture? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = ctx.data
        else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width * 4
        )
        return texture
    }
}

// MARK: - Слой

/// `MTKView`, который проигрывает пепел один раз и останавливается.
///
/// Такт свой, по `CACurrentMediaTime`, но той же длины, что и схлопывание слота
/// в рельсе — обе анимации заводятся в одном кадре и заканчиваются в одном.
final class AshMetalView: MTKView, MTKViewDelegate {
    private let engine: AshEngine
    private let source: MTLTexture
    private let rowSize: CGSize
    private let margin: CGFloat
    private let duration: Double
    private let onFinished: () -> Void

    private var particles: MTLBuffer?
    private var grid = SIMD2<UInt32>(0, 0)
    private var particleCount = 0
    private var startedAt: CFTimeInterval?
    private var lastFrameAt: CFTimeInterval?
    private var reported = false

    init?(
        image: CGImage,
        rowSize: CGSize,
        margin: CGFloat,
        duration: Double,
        onFinished: @escaping () -> Void
    ) {
        guard let engine = AshEngine.shared else {
            AshLog.log.error("view: engine unavailable"); return nil
        }
        guard let source = engine.texture(from: image) else {
            AshLog.log.error("view: texture failed \(image.width)x\(image.height)"); return nil
        }
        guard rowSize.width > 1, rowSize.height > 1 else {
            AshLog.log.error("view: bad rowSize \(rowSize.debugDescription)"); return nil
        }

        self.engine = engine
        self.source = source
        self.rowSize = rowSize
        self.margin = margin
        self.duration = duration
        self.onFinished = onFinished

        super.init(frame: .zero, device: engine.device)

        colorPixelFormat = AshEngine.pixelFormat
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = false
        enableSetNeedsDisplay = false
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        delegate = self

        makeParticles()
        AshLog.log.info("view: made, row \(rowSize.debugDescription) particles \(self.particleCount)")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func makeParticles() {
        let cell = max(0.5, Tune.cellSize)
        let columns = max(1, Int((rowSize.width / cell).rounded()))
        let rows = max(1, Int((rowSize.height / cell).rounded()))
        grid = SIMD2<UInt32>(UInt32(columns), UInt32(rows))
        particleCount = columns * rows

        let length = MemoryLayout<AshParticleSlot>.stride * particleCount
        guard let buffer = engine.device.makeBuffer(length: length, options: .storageModePrivate),
              let command = engine.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { return }

        var params = AshInitParams(
            speedMin: Float(Tune.speedMin),
            speedMax: Float(Tune.speedMax),
            lifeMin: Float(Tune.lifetimeMin * duration),
            lifeMax: Float(Tune.lifetimeMax * duration),
            seed: UInt32.random(in: 0...UInt32.max)
        )

        encoder.setComputePipelineState(engine.initPipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<AshInitParams>.stride, index: 1)
        dispatch(encoder, pipeline: engine.initPipeline)
        encoder.endEncoding()
        command.commit()

        particles = buffer
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, particleCount)
        encoder.dispatchThreadgroups(
            MTLSize(width: (particleCount + width - 1) / max(1, width), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: max(1, width), height: 1, depth: 1)
        )
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let particles,
              let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let command = engine.queue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        if startedAt == nil {
            startedAt = now
            lastFrameAt = now
            AshLog.log.info("view: first draw, bounds \(self.bounds.debugDescription) drawable \(self.drawableSize.debugDescription)")
        }
        let phase = now - (startedAt ?? now)
        // Δt настоящий, а не 1/60: кадр, съеденный чем-то другим, не должен
        // растягивать анимацию — он должен быть просто длиннее.
        let step = min(0.05, max(0, now - (lastFrameAt ?? now)))
        lastFrameAt = now

        var update = AshUpdateParams(
            grid: grid,
            phase: Float(phase),
            timeStep: Float(step),
            waveWindow: Float(Tune.waveWindow),
            waveDuration: Float(Tune.waveDuration * duration),
            gravity: Float(Tune.gravity)
        )

        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(engine.updatePipeline)
            encoder.setBuffer(particles, offset: 0, index: 0)
            encoder.setBytes(&update, length: MemoryLayout<AshUpdateParams>.stride, index: 1)
            dispatch(encoder, pipeline: engine.updatePipeline)
            encoder.endEncoding()
        }

        let canvas = CGSize(
            width: rowSize.width + margin * 2,
            height: rowSize.height + margin * 2
        )
        var draw = AshDrawParams(
            size: SIMD2<Float>(Float(rowSize.width), Float(rowSize.height)),
            canvas: SIMD2<Float>(Float(canvas.width), Float(canvas.height)),
            margin: SIMD2<Float>(Float(margin), Float(margin)),
            grid: grid,
            fadeTail: Float(Tune.fadeTail * duration)
        )

        if let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(engine.drawPipeline)
            encoder.setVertexBytes(&draw, length: MemoryLayout<AshDrawParams>.stride, index: 0)
            encoder.setVertexBuffer(particles, offset: 0, index: 1)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: particleCount
            )
            encoder.endEncoding()
        }

        command.present(drawable)
        command.commit()

        if phase >= duration { finish() }
    }

    private func finish() {
        guard !reported else { return }
        reported = true
        isPaused = true
        AshLog.log.info("view: finished")
        onFinished()
    }
}

// MARK: - Мост в SwiftUI

struct AshMetalCanvas: NSViewRepresentable {
    let image: CGImage
    let rowSize: CGSize
    let margin: CGFloat
    let duration: Double
    var onFinished: () -> Void
    /// Metal здесь нет (нет устройства, нет metallib) — эффекта не будет, и
    /// строку надо снять сразу, а не держать пустой холст такт.
    var onUnavailable: () -> Void

    func makeNSView(context: Context) -> NSView {
        guard let view = AshMetalView(
            image: image,
            rowSize: rowSize,
            margin: margin,
            duration: duration,
            onFinished: onFinished
        ) else {
            DispatchQueue.main.async { onUnavailable() }
            return NSView()
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

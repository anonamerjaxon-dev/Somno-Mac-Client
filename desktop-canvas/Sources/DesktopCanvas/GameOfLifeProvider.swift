import AppKit
import Metal
import MetalKit

/// Internal, not private, so the orientation regression test can compile the
/// exact same source it is guarding.
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GridParams {
    uint width;
    uint height;
    uint birthMask;
    uint survivalMask;
};

kernel void gameOfLifeStep(
    device const uint8_t* inputGrid  [[buffer(0)]],
    device uint8_t*       outputGrid [[buffer(1)]],
    constant GridParams&  params     [[buffer(2)]],
    uint2                 gid        [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;
    uint idx = gid.y * params.width + gid.x;

    int aliveNeighbors = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(gid.x) + dx;
            int ny = int(gid.y) + dy;
            if (nx < 0) nx = int(params.width) - 1;
            if (ny < 0) ny = int(params.height) - 1;
            if (nx >= int(params.width)) nx = 0;
            if (ny >= int(params.height)) ny = 0;
            uint nidx = uint(ny) * params.width + uint(nx);
            if (inputGrid[nidx] != 0) aliveNeighbors++;
        }
    }

    uint8_t cell = inputGrid[idx];
    if (cell != 0) {
        outputGrid[idx] = ((params.survivalMask >> aliveNeighbors) & 1);
    } else {
        outputGrid[idx] = ((params.birthMask >> aliveNeighbors) & 1);
    }
}

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}

struct FragmentParams {
    uint gridWidth;
    uint gridHeight;
    float cellSize;
    float viewWidth;
    float4 aliveColor;
    float4 deadColor;
    float4 marginColor;
};

fragment float4 gameOfLifeFragment(
    VertexOut               in       [[stage_in]],
    constant FragmentParams& params   [[buffer(0)]],
    device const uint8_t*   grid     [[buffer(1)]]
) {
    // Metal's fragment `[[position]]` already has its origin at the TOP-LEFT of
    // the drawable, and the grid editor draws row 0 at the top (it overrides
    // `isFlipped` to true), so row 0 must land at the top here too. Do NOT flip
    // y here: doing so rendered the grid vertically mirrored against the editor.
    // `GameOfLifeOrientationTests` pins this with a real render + readback.
    float2 fragPos = in.position.xy;

    uint col = uint(floor(fragPos.x / params.cellSize));
    uint row = uint(floor(fragPos.y / params.cellSize));

    if (col >= params.gridWidth || row >= params.gridHeight) {
        return params.marginColor;
    }

    uint idx = row * params.gridWidth + col;
    return grid[idx] ? params.aliveColor : params.deadColor;
}
"""

public final class GameOfLifeProvider: MTKView, CanvasProvider {

    var canvas: CanvasModel

    private static let maxTextureSize: CGFloat = 16384

    private var commandQueue: MTLCommandQueue!
    private var computePipeline: MTLComputePipelineState!
    private var renderPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var bufferA: MTLBuffer!
    private var bufferB: MTLBuffer!
    private var useBufferA = true
    private var needsCompute = true
    private var setupError: Error?

    public private(set) var gridWidth: Int = 0
    public private(set) var gridHeight: Int = 0

    private var timer: DispatchSourceTimer?
    private var isTimerRunning = false
    private var lastGenerationsPerSecond: Double?
    private let timerQueue: DispatchQueue
    private var powerStateObserver: NSObjectProtocol?

    /// The reason Metal setup failed, if it did; `nil` after a successful init.
    ///
    /// Surfaced instead of trapping, so a machine without a usable Metal
    /// pipeline degrades to a blank canvas rather than taking down the host app.
    public private(set) var initializationError: Error?

    init(canvas: CanvasModel) {
        self.canvas = canvas
        self.timerQueue = DispatchQueue(label: "com.desktopcanvas.gol.\(canvas.id)")
        let safeFrame = Self.clampedFrame(canvas.frame)
        super.init(frame: safeFrame, device: MTLCreateSystemDefaultDevice())
        setupMetal()
        setupGrid()
        observePowerState()
    }

    static func clampedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: 0, y: 0,
            width: min(frame.width, maxTextureSize),
            height: min(frame.height, maxTextureSize)
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let timer = timer {
            if !isTimerRunning {
                timer.resume()
            }
            timer.cancel()
        }
    }

    // MARK: - Metal Setup

    private func setupMetal() {
        framebufferOnly = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = preferredFPS()

        guard let device else {
            record(SetupFailure.noDevice)
            return
        }

        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)

            guard let computeFn = library.makeFunction(name: "gameOfLifeStep"),
                  let vertexFn = library.makeFunction(name: "fullscreenVertex"),
                  let fragmentFn = library.makeFunction(name: "gameOfLifeFragment") else {
                record(SetupFailure.missingShaderFunction)
                return
            }

            let computePipelineState = try device.makeComputePipelineState(function: computeFn)

            let rpDesc = MTLRenderPipelineDescriptor()
            rpDesc.vertexFunction = vertexFn
            rpDesc.fragmentFunction = fragmentFn
            rpDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let renderPipelineState = try device.makeRenderPipelineState(descriptor: rpDesc)

            guard let queue = device.makeCommandQueue() else {
                record(SetupFailure.noCommandQueue)
                return
            }

            let depthDesc = MTLDepthStencilDescriptor()
            depthDesc.isDepthWriteEnabled = false
            depthDesc.depthCompareFunction = .always

            computePipeline = computePipelineState
            renderPipeline = renderPipelineState
            depthState = device.makeDepthStencilState(descriptor: depthDesc)
            commandQueue = queue
        } catch {
            record(error)
        }
    }

    private func record(_ error: Error) {
        setupError = error
        initializationError = error
    }

    private enum SetupFailure: LocalizedError {
        case noDevice
        case noCommandQueue
        case missingShaderFunction
        case bufferAllocationFailed(component: String)

        var errorDescription: String? {
            switch self {
            case .noDevice:
                return "Metal is not available on this system."
            case .noCommandQueue:
                return "Metal could not create a command queue for this device."
            case .missingShaderFunction:
                return "The built-in Game of Life shader is missing a required function."
            case .bufferAllocationFailed(let component):
                return "Metal could not allocate the Game of Life \(component) buffer."
            }
        }
    }

    private func preferredFPS() -> Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
    }

    private func observePowerState() {
        removePowerStateObserver()
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.preferredFramesPerSecond = self?.preferredFPS() ?? 60
        }
    }

    private func removePowerStateObserver() {
        if let observer = powerStateObserver {
            NotificationCenter.default.removeObserver(observer)
            powerStateObserver = nil
        }
    }

    // MARK: - Grid Setup

    private func setupGrid() {
        guard let device else { return }
        guard let config = canvas.gameOfLifeConfig else { return }

        let (cols, rows) = GameOfLifeConfig.gridDimensions(
            for: canvas.frame,
            cellSize: config.cellSize
        )
        gridWidth = cols
        gridHeight = rows

        let totalCells = gridWidth * gridHeight
        guard totalCells > 0,
              let newBufferA = device.makeBuffer(length: totalCells, options: .storageModeShared),
              let newBufferB = device.makeBuffer(length: totalCells, options: .storageModeShared) else {
            record(SetupFailure.bufferAllocationFailed(component: "grid"))
            return
        }
        bufferA = newBufferA
        bufferB = newBufferB

        seedGrid()
    }

    private func seedGrid() {
        guard let config = canvas.gameOfLifeConfig else { return }
        let totalCells = gridWidth * gridHeight

        let bufAPtr = bufferA.contents().assumingMemoryBound(to: UInt8.self)

        if let gridState = config.gridState,
           gridState.count == gridHeight,
           gridState.first?.count == gridWidth {
            for row in 0..<gridHeight {
                let stateRow = gridState[row]
                for col in 0..<gridWidth {
                    let idx = row * gridWidth + col
                    bufAPtr[idx] = stateRow[col] ? 1 : 0
                }
            }
        } else {
            arc4random_buf(bufAPtr, totalCells)
            for i in 0..<totalCells {
                bufAPtr[i] &= 1
            }
        }

        let bufBPtr = bufferB.contents().assumingMemoryBound(to: UInt8.self)
        memcpy(bufBPtr, bufAPtr, totalCells)
    }

    // MARK: - Timer

    private func scheduleTimer() {
        guard let config = canvas.gameOfLifeConfig else { return }

        let newGSP = max(config.generationsPerSecond, 0.1)

        if lastGenerationsPerSecond == newGSP && timer != nil {
            if !config.paused && !isTimerRunning {
                timer?.resume()
                isTimerRunning = true
            }
            return
        }

        lastGenerationsPerSecond = newGSP

        if isTimerRunning {
            timer?.cancel()
            isTimerRunning = false
        } else {
            timer?.resume()
            timer?.cancel()
        }
        timer = nil

        let interval = 1.0 / newGSP
        let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        newTimer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        newTimer.setEventHandler { [weak self] in
            // `needsCompute` is read by `draw(_:)` and written by every grid
            // mutation, all of which happen on the main thread. Hop back to the
            // main queue before touching it so the timer never mutates it from
            // `timerQueue` (a data race under Swift's memory model).
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsCompute = true
                self.setNeedsDisplay(self.bounds)
            }
        }
        self.timer = newTimer

        if !config.paused {
            newTimer.resume()
            isTimerRunning = true
        }
    }

    // MARK: - CanvasProvider

    func attach(to superview: NSView, frame: NSRect) {
        self.frame = superview.bounds
        superview.addSubview(self)
        scheduleTimer()
    }

    func detach() {
        removePowerStateObserver()
        if isTimerRunning {
            timer?.cancel()
            isTimerRunning = false
        } else {
            timer?.resume()
            timer?.cancel()
        }
        timer = nil
        removeFromSuperview()
    }

    func update() {
        guard let config = canvas.gameOfLifeConfig else { return }

        let (newGridWidth, newGridHeight) = GameOfLifeConfig.gridDimensions(
            for: canvas.frame,
            cellSize: config.cellSize
        )

        self.frame = Self.clampedFrame(canvas.frame)

        let dimensionsChanged = newGridWidth != gridWidth || newGridHeight != gridHeight
        if dimensionsChanged {
            reallocateGrid(width: newGridWidth, height: newGridHeight)
        }

        scheduleTimer()
        needsCompute = true
    }

    public func pause() {
        needsCompute = false
        if isTimerRunning {
            timer?.suspend()
            isTimerRunning = false
        }
    }

    /// Restarts the simulation timer unless the user paused it in the editor.
    ///
    /// `config.paused` is the authoritative flag: without this check a
    /// sleep/wake cycle (or any other `resume()` caller) would silently un-pause
    /// a frozen canvas.
    public func resume() {
        guard canvas.gameOfLifeConfig?.paused != true else { return }
        if !isTimerRunning {
            timer?.resume()
            isTimerRunning = true
        }
    }

    // MARK: - Grid Reallocation

    private func reallocateGrid(width: Int, height: Int) {
        guard let device = device, let oldBufferA = bufferA else { return }

        let oldWidth = gridWidth
        let oldHeight = gridHeight
        let oldBufA = oldBufferA

        let newTotal = width * height
        guard newTotal > 0,
              let newBufferA = device.makeBuffer(length: newTotal, options: .storageModeShared),
              let newBufferB = device.makeBuffer(length: newTotal, options: .storageModeShared) else {
            record(SetupFailure.bufferAllocationFailed(component: "resize"))
            return
        }

        gridWidth = width
        gridHeight = height

        let newPtrA = newBufferA.contents().assumingMemoryBound(to: UInt8.self)
        let oldPtrA = oldBufA.contents().assumingMemoryBound(to: UInt8.self)

        let copyRowCount = min(height, oldHeight)
        let copyColCount = min(width, oldWidth)

        for row in 0..<copyRowCount {
            let newRowPtr = newPtrA.advanced(by: row * width)
            let oldRowPtr = oldPtrA.advanced(by: row * oldWidth)
            memcpy(newRowPtr, oldRowPtr, copyColCount)

            if width > oldWidth {
                let extraStart = newRowPtr.advanced(by: oldWidth)
                let extraCount = width - oldWidth
                arc4random_buf(extraStart, extraCount)
                for i in 0..<extraCount {
                    extraStart[i] &= 1
                }
            }
        }

        if height > oldHeight {
            let remainingStart = newPtrA.advanced(by: oldHeight * width)
            let remainingCount = (height - oldHeight) * width
            arc4random_buf(remainingStart, remainingCount)
            for i in 0..<remainingCount {
                remainingStart[i] &= 1
            }
        }

        let newPtrB = newBufferB.contents().assumingMemoryBound(to: UInt8.self)
        memcpy(newPtrB, newPtrA, newTotal)

        bufferA = newBufferA
        bufferB = newBufferB
        useBufferA = true
        needsCompute = true
    }

    // MARK: - Grid Mutation API

    private func currentBuffer() -> MTLBuffer? {
        useBufferA ? bufferA : bufferB
    }

    private func withCurrentBuffer<T>(_ body: (UnsafeMutablePointer<UInt8>) -> T, default fallback: T) -> T {
        guard let buffer = currentBuffer() else { return fallback }
        return body(buffer.contents().assumingMemoryBound(to: UInt8.self))
    }

    private func markDirty() {
        if canvas.gameOfLifeConfig?.paused == true {
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsDisplay(self?.bounds ?? .zero)
            }
        } else {
            needsCompute = true
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsDisplay(self?.bounds ?? .zero)
            }
        }
    }

    public func cellState(row: Int, col: Int) -> Bool {
        guard row >= 0, row < gridHeight, col >= 0, col < gridWidth else { return false }
        return withCurrentBuffer({ $0[row * gridWidth + col] != 0 }, default: false)
    }

    public func setCell(row: Int, col: Int, alive: Bool) {
        guard row >= 0, row < gridHeight, col >= 0, col < gridWidth else { return }
        withCurrentBuffer({
            BrushTool.setCell($0, width: gridWidth, height: gridHeight,
                              row: row, col: col, alive: alive)
        }, default: ())
        markDirty()
    }

    public func toggleCell(row: Int, col: Int) {
        setCell(row: row, col: col, alive: !cellState(row: row, col: col))
    }

    public func fillRect(minRow: Int, minCol: Int, maxRow: Int, maxCol: Int, alive: Bool) {
        withCurrentBuffer({
            BrushTool.fillRect($0, width: gridWidth, height: gridHeight,
                               minRow: minRow, minCol: minCol,
                               maxRow: maxRow, maxCol: maxCol, alive: alive)
        }, default: ())
        markDirty()
    }

    public func drawLine(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int, alive: Bool) {
        withCurrentBuffer({
            BrushTool.drawLine($0, width: gridWidth, height: gridHeight,
                               fromRow: fromRow, fromCol: fromCol,
                               toRow: toRow, toCol: toCol, alive: alive)
        }, default: ())
        markDirty()
    }

    public func clearAll() {
        let total = gridWidth * gridHeight
        withCurrentBuffer({ memset($0, 0, total) }, default: ())
        markDirty()
    }

    public func randomSeed(density: Double = 0.5) {
        let count = gridWidth * gridHeight
        var generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
        withCurrentBuffer({
            BrushTool.seedGrid($0, count: count, density: density, using: &generator)
        }, default: ())
        markDirty()
    }

    public func writeFullGrid(_ data: [UInt8]) {
        let total = gridWidth * gridHeight
        guard data.count == total else { return }
        data.withUnsafeBytes { buf in
            withCurrentBuffer({ memcpy($0, buf.baseAddress!, total) }, default: ())
        }
        markDirty()
    }

    public func gridSnapshot() -> [UInt8] {
        let total = gridWidth * gridHeight
        return withCurrentBuffer({ Array(UnsafeBufferPointer(start: $0, count: total)) }, default: [])
    }

    // MARK: - Drawing

    // Override NSView.draw(_:) directly rather than conforming to MTKViewDelegate.
    // Setting self.delegate = self causes MTKView to route rendering through
    // delegate.draw(in:) which bypasses draw(_:) and can silently fail to fire
    // the CVDisplayLink-driven render loop.

    public override func draw(_ rect: CGRect) {
        // A failed Metal setup is reported through `initializationError`; the
        // canvas stays blank instead of trapping on a force-unwrapped pipeline.
        guard setupError == nil,
              let config = canvas.gameOfLifeConfig,
              let drawable = currentDrawable,
              let rpDesc = currentRenderPassDescriptor,
              bufferA != nil,
              bufferB != nil else {
            return
        }

        // Step the simulation in its own command buffer. The previous version
        // encoded the step into the render command buffer and only then created
        // the render encoder, so a nil render pipeline/encoder returned without
        // committing — after `useBufferA` had flipped and `needsCompute` had
        // been cleared, silently discarding the generation that was just computed.
        if needsCompute,
           let inputBuffer = useBufferA ? bufferA : bufferB,
           let outputBuffer = useBufferA ? bufferB : bufferA,
           let computePipeline,
           let computeCmdBuf = commandQueue.makeCommandBuffer(),
           let computeEncoder = computeCmdBuf.makeComputeCommandEncoder() {
            var gridParams = GridParams(
                width: UInt32(gridWidth),
                height: UInt32(gridHeight),
                birthMask: ruleMask(from: config.ruleSet.birth),
                survivalMask: ruleMask(from: config.ruleSet.survival)
            )

            computeEncoder.setComputePipelineState(computePipeline)
            computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
            computeEncoder.setBytes(&gridParams, length: MemoryLayout<GridParams>.size, index: 2)

            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: gridWidth, height: gridHeight, depth: 1)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            computeEncoder.endEncoding()
            computeCmdBuf.commit()

            useBufferA = !useBufferA
            needsCompute = false
        }

        // Resolved *after* the step above so the render samples the generation
        // that was just computed rather than the previous frame's buffer.
        guard let renderPipeline,
              let currentGrid = useBufferA ? bufferA : bufferB,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let renderEncoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc) else {
            return
        }
        renderEncoder.setRenderPipelineState(renderPipeline)
        renderEncoder.setDepthStencilState(depthState)

        // A zero-width drawable (window off-screen or mid-resize) would make
        // this division produce ±inf / NaN and poison every fragment parameter.
        let scale: Float = bounds.width > 0 ? Float(drawableSize.width / bounds.width) : 1

        var fragParams = FragmentParams(
            gridWidth: UInt32(gridWidth),
            gridHeight: UInt32(gridHeight),
            cellSize: Float(config.cellSize) * scale,
            viewWidth: Float(drawableSize.width),
            aliveColor: colorToFloat4(config.aliveColor),
            deadColor: colorToFloat4(config.deadColor),
            marginColor: colorToFloat4(config.marginColor)
        )

        renderEncoder.setFragmentBytes(&fragParams, length: MemoryLayout<FragmentParams>.size, index: 0)
        renderEncoder.setFragmentBuffer(currentGrid, offset: 0, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Helpers

    private func ruleMask(from set: Set<Int>) -> UInt32 {
        set.reduce(0) { $0 | (1 << $1) }
    }

    private func colorToFloat4(_ color: CodableColor) -> SIMD4<Float> {
        SIMD4<Float>(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha))
    }
}

private struct GridParams {
    var width: UInt32
    var height: UInt32
    var birthMask: UInt32
    var survivalMask: UInt32
}

/// Internal, not private, so the orientation regression test can render through
/// the exact same pipeline and read the result back.
struct FragmentParams {
    var gridWidth: UInt32
    var gridHeight: UInt32
    var cellSize: Float
    var viewWidth: Float
    var aliveColor: SIMD4<Float>
    var deadColor: SIMD4<Float>
    var marginColor: SIMD4<Float>
}
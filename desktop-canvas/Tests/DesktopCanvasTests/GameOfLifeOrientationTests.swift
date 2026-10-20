import XCTest
import Metal
@testable import DesktopCanvas

/// Pins the vertical orientation of the Game-of-Life grid as the desktop renders
/// it against the orientation the grid editor draws.
///
/// `GridCanvasNSView` is a flipped `NSView`, so it draws grid row 0 at the top.
/// Metal's fragment `[[position]]` is also top-left origin, so the fragment
/// shader must not flip y. This test renders one alive row through the *real*
/// pipeline and reads the drawable back, so a re-introduced flip fails loudly
/// here instead of silently mirroring every pattern between the editor and the
/// desktop.
final class GameOfLifeOrientationTests: XCTestCase {

    private let drawableWidth = 8
    private let drawableHeight = 8
    private let gridWidth = 4
    private let gridHeight = 4

    /// Every pixel of the rendered drawable, indexed `[rowFromTop][column]`,
    /// where `true` means the alive colour was drawn.
    private struct Render {
        let alive: [[Bool]]
        let margin: [[Bool]]

        func row(_ index: Int) -> [Bool] { alive[index] }
    }

    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine.")
        }
        return device
    }

    /// Renders `grid` and reads the drawable back. `grid` is `gridWidth` ×
    /// `gridHeight` bytes in the same row-major order `CanvasLayout` stores.
    private func render(_ grid: [UInt8]) throws -> Render {
        let device = try makeDevice()
        let library = try device.makeLibrary(source: metalShaderSource, options: nil)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "gameOfLifeFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: drawableWidth,
            height: drawableHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .managed
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))

        let gridBuffer = try XCTUnwrap(
            device.makeBuffer(bytes: grid, length: grid.count, options: .storageModeManaged)
        )

        var params = FragmentParams(
            gridWidth: UInt32(gridWidth),
            gridHeight: UInt32(gridHeight),
            cellSize: Float(drawableWidth) / Float(gridWidth),
            viewWidth: Float(drawableWidth),
            aliveColor: SIMD4<Float>(1, 0, 0, 1),
            deadColor: SIMD4<Float>(0, 0, 1, 1),
            marginColor: SIMD4<Float>(0, 1, 0, 1)
        )

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FragmentParams>.size, index: 0)
        encoder.setFragmentBuffer(gridBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: drawableWidth * drawableHeight * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: drawableWidth * 4,
                from: MTLRegionMake2D(0, 0, drawableWidth, drawableHeight),
                mipmapLevel: 0
            )
        }

        // Metal texture row 0 is the TOP of the drawable.
        var alive: [[Bool]] = []
        var margin: [[Bool]] = []
        for y in 0..<drawableHeight {
            var aliveRow: [Bool] = []
            var marginRow: [Bool] = []
            for x in 0..<drawableWidth {
                let offset = (y * drawableWidth + x) * 4
                let r = pixels[offset]
                let g = pixels[offset + 1]
                let b = pixels[offset + 2]
                aliveRow.append(r > 200 && g < 60 && b < 60)
                marginRow.append(g > 200 && r < 60 && b < 60)
            }
            alive.append(aliveRow)
            margin.append(marginRow)
        }
        return Render(alive: alive, margin: margin)
    }

    private func grid(aliveRow: Int) -> [UInt8] {
        var cells = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for col in 0..<gridWidth { cells[aliveRow * gridWidth + col] = 1 }
        return cells
    }

    func testGridRowZeroRendersAtTheTopOfTheDrawable() throws {
        let result = try render(grid(aliveRow: 0))
        XCTAssertEqual(result.row(0), [true, true, true, true, true, true, true, true])
        XCTAssertEqual(result.row(1), [true, true, true, true, true, true, true, true])
        XCTAssertEqual(result.row(7), [false, false, false, false, false, false, false, false])
    }

    func testLastGridRowRendersAtTheBottomOfTheDrawable() throws {
        let result = try render(grid(aliveRow: gridHeight - 1))
        XCTAssertEqual(result.row(0), [false, false, false, false, false, false, false, false])
        XCTAssertEqual(result.row(6), [true, true, true, true, true, true, true, true])
        XCTAssertEqual(result.row(7), [true, true, true, true, true, true, true, true])
    }

    func testGridColumnZeroRendersAtTheLeftOfTheDrawable() throws {
        var cells = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for row in 0..<gridHeight { cells[row * gridWidth] = 1 }
        let result = try render(cells)

        // Left two pixel columns alive on every row; right side dead.
        for y in 0..<drawableHeight {
            XCTAssertEqual(result.row(y), [true, true, false, false, false, false, false, false])
        }
    }
}

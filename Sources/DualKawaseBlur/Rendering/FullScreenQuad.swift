import Metal
import Foundation

/// Manages vertex buffer for full-screen quad rendering
/// Immutable vertex data shared by stateless render encoders.
final class FullScreenQuad: Sendable {
    private let vertexBuffer: MetalBufferReference

    /// Quad vertices in NDC coordinates (-1 to +1)
    /// Correct order for triangle strip: TL → BL → TR → BR
    private static let vertices: [Vertex] = [
        Vertex(-1.0,  1.0, 1.0),  // Top-left
        Vertex(-1.0, -1.0, 1.0),  // Bottom-left
        Vertex( 1.0,  1.0, 1.0),  // Top-right
        Vertex( 1.0, -1.0, 1.0)   // Bottom-right
    ]

    enum QuadError: Error {
        case bufferCreationFailed
    }

    init(device: MTLDevice) throws {
        let vertexData = FullScreenQuad.vertices
        let dataSize = vertexData.count * MemoryLayout<Vertex>.stride

        guard let buffer = device.makeBuffer(
            bytes: vertexData,
            length: dataSize,
            options: [.cpuCacheModeWriteCombined]
        ) else {
            throw QuadError.bufferCreationFailed
        }

        vertexBuffer = MetalBufferReference(buffer)
    }

    /// Bind vertex buffer and draw quad
    func draw(encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(vertexBuffer.value, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

/// `MTLBuffer` is an imported immutable resource handle here and Metal permits
/// concurrent encoding with it. This wrapper is the sole audited unchecked edge.
private struct MetalBufferReference: @unchecked Sendable {
    let value: MTLBuffer

    init(_ value: MTLBuffer) {
        self.value = value
    }
}

import CryptoKit
import Foundation
import Metal

/// The qualified 2026-10-10 corpus: bundled Sphere/diagnostic inputs, optional staged photos
/// and the six generated edge-phase fixtures. Every input is verified by SHA-256 before use.
struct CPUEncodeCorpus {
    enum Failure: Error { case missingResource, provenance }
    struct Manifest: Decodable {
        struct Record: Decodable {
            let file: String
            let kind: String
            let bytes: Int
            let sha256: String
            let bundled: Bool
            let resource: String?
            let resourceSHA256: String?
        }
        let protocolID: String
        let sourceManifestSHA256: String
        let width: Int
        let height: Int
        let rowBytes: Int
        let pixelFormat: String
        let primarySequence: [String]
        let compression: String
        let records: [Record]
    }
    struct Fixture {
        let name: String
        let pixels: Data
    }

    static let width = 1179, height = 2556
    /// Photos are staged here by `run_cpu_encode.py stage-photos`; never bundled.
    static let stagedDirectory = "CPUEncodeInputs"

    let manifest: Manifest
    let manifestSHA256: String

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "cpu-encode-corpus", withExtension: "json") else { throw Failure.missingResource }
        let data = try Data(contentsOf: url)
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
        manifestSHA256 = Self.hash(data)
        guard manifest.protocolID == "cpu-encode-corpus-v1", manifest.compression == "raw-deflate",
              manifest.width == Self.width, manifest.height == Self.height, manifest.rowBytes == Self.width * 4,
              manifest.pixelFormat == "bgra8Unorm", manifest.primarySequence.count == 8, manifest.records.count == 16,
              Set(manifest.primarySequence).isSubset(of: Set(manifest.records.filter(\.bundled).map(\.file))) else {
            throw Failure.provenance
        }
    }

    /// The eight changing Sphere inputs, in the frozen `index % 8` order.
    func sphereSequence(bundle: Bundle = .main) throws -> [Fixture] {
        try manifest.primarySequence.map { name in
            guard let record = manifest.records.first(where: { $0.file == name }) else { throw Failure.provenance }
            return try Fixture(name: name, pixels: bundled(record, bundle: bundle))
        }
    }

    /// Bundled records, staged photos when present, then the six edge-phase fixtures.
    func qualificationFixtures(bundle: Bundle = .main) throws -> (fixtures: [Fixture], photosIncluded: Bool) {
        var fixtures: [Fixture] = []
        var photos = 0
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        for record in manifest.records {
            if record.bundled {
                fixtures.append(try Fixture(name: record.file, pixels: bundled(record, bundle: bundle)))
                continue
            }
            let url = documents.appendingPathComponent(Self.stagedDirectory).appendingPathComponent(record.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            // A staged file that does not match is a provenance failure, never a silent skip.
            guard data.count == record.bytes, Self.hash(data) == record.sha256 else { throw Failure.provenance }
            fixtures.append(Fixture(name: record.file, pixels: data))
            photos += 1
        }
        let staged = manifest.records.filter { !$0.bundled }.count
        guard photos == 0 || photos == staged else { throw Failure.provenance }
        for edge in 0..<6 {
            fixtures.append(Fixture(name: "calibration-\(edge)", pixels: Self.edgeFixture(edge)))
        }
        return (fixtures, photos == staged)
    }

    private func bundled(_ record: Manifest.Record, bundle: Bundle) throws -> Data {
        guard let resource = record.resource, let expected = record.resourceSHA256,
              let url = bundle.url(forResource: resource, withExtension: nil) else { throw Failure.missingResource }
        let packed = try Data(contentsOf: url)
        guard Self.hash(packed) == expected else { throw Failure.provenance }
        let raw = try (packed as NSData).decompressed(using: .zlib) as Data
        guard raw.count == record.bytes, Self.hash(raw) == record.sha256 else { throw Failure.provenance }
        return raw
    }

    /// Hard black/white edge at the centre ±10 px; 0–2 vertical, 3–5 horizontal (2026-10-10 calibration set).
    static func edgeFixture(_ index: Int) -> Data {
        var result = Data(count: width * height * 4)
        let horizontal = index >= 3, phase = [-10, 0, 10][index % 3]
        result.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let value: UInt8 = (horizontal ? y : x) >= (horizontal ? height : width) / 2 + phase ? 255 : 0
                    p[i] = value; p[i + 1] = value; p[i + 2] = value; p[i + 3] = 255
                }
            }
        }
        return result
    }

    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

/// Texture plumbing shared by the qualification and timing routes.
enum CPUEncodeTextures {
    enum Failure: Error { case allocation, gpu }

    static func texture(_ device: MTLDevice, _ storage: MTLStorageMode, _ usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: CPUEncodeCorpus.width, height: CPUEncodeCorpus.height, mipmapped: false)
        descriptor.storageMode = storage
        descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        return texture
    }

    static func replace(_ data: Data, into texture: MTLTexture) {
        data.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: texture.width * 4) }
    }

    static func copy(_ source: MTLTexture, to destination: MTLTexture, using encoder: MTLBlitCommandEncoder) {
        encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
            sourceSize: .init(width: source.width, height: source.height, depth: 1), to: destination,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
    }

    static func bytes(_ texture: MTLTexture) -> Data {
        var result = Data(count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        return result
    }

    /// Commits and drains exactly once.
    static func finish(_ buffer: MTLCommandBuffer) async throws {
        let status = await withCheckedContinuation { continuation in
            buffer.addCompletedHandler { continuation.resume(returning: $0.status) }
            buffer.commit()
        }
        guard status == .completed else { throw Failure.gpu }
    }

    /// Uploads `pixels` into a new private shader-read texture through a shared staging texture.
    static func privateSource(_ pixels: Data, device: MTLDevice, queue: MTLCommandQueue,
                              staging: MTLTexture) async throws -> MTLTexture {
        replace(pixels, into: staging)
        let source = try texture(device, .private, .shaderRead)
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { throw Failure.allocation }
        copy(staging, to: source, using: blit)
        blit.endEncoding()
        try await finish(buffer)
        return source
    }

    /// Max absolute per-channel difference, alpha included; 256 for mismatched sizes.
    static func maxDifference(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return 256 }
        return a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                let pa = ra.bindMemory(to: UInt8.self), pb = rb.bindMemory(to: UInt8.self)
                var worst = 0
                for i in 0..<pa.count where pa[i] != pb[i] {
                    worst = max(worst, abs(Int(pa[i]) - Int(pb[i])))
                }
                return worst
            }
        }
    }
}

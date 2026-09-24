import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit

@MainActor @Observable
final class ComparisonViewModel {
    var iterations = 3
    var offset: Float = 2
    var sigma: Float = 12
    var material = ComparisonMaterial.ultraThin
    var showOriginal = false
    private(set) var sourceRevision: UInt64 = 0
    private(set) var output: ComparisonRenderer.Output?
    private(set) var renderedRequest: ComparisonRequest?
    private(set) var isLoading = false
    private(set) var error: String?
    private var source = ComparisonSample.makeImage()
    private var renderer: ComparisonRenderer?
    private var loadGeneration: UInt64 = 0
    private var renderGeneration: UInt64 = 0

    func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        invalidatePreview()
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ComparisonRenderer.RenderError.imageConversion
            }
            try Task.checkCancellation()
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ComparisonRenderer.RenderError.imageConversion }
            guard generation == loadGeneration else { return }
            source = UIImage(cgImage: thumbnail)
            sourceRevision &+= 1
        } catch {
            if generation == loadGeneration, !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    func useSample() {
        loadGeneration &+= 1
        isLoading = false
        invalidatePreview()
        source = ComparisonSample.makeImage()
        sourceRevision &+= 1
    }

    func render(_ request: ComparisonRequest) async {
        guard !isLoading, renderedRequest != request else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        output = nil
        renderedRequest = nil
        error = nil
        do {
            // Coalesce slider changes; cancellation also prevents stale results after navigation.
            try await Task.sleep(for: .milliseconds(120))
            if renderer == nil { renderer = try ComparisonRenderer() }
            guard let renderer else { return }
            let result = try await renderer.render(image: source, request: request)
            try Task.checkCancellation()
            guard generation == renderGeneration, request.revision == sourceRevision else { return }
            output = result
            renderedRequest = request
        } catch {
            if generation == renderGeneration, !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func invalidatePreview() {
        renderGeneration &+= 1
        output = nil
        renderedRequest = nil
        error = nil
    }
}

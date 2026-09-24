# DualKawaseBlur

Metal-backed Dual Kawase blur primitives for Swift and SwiftUI. The package exposes
three integration levels: asynchronous `UIImage` processing, GPU-to-GPU frame blur,
and a SwiftUI capture surface for content that does not already have a Metal frame.

The package is intentionally a general frame consumer. It does not depend on
`SphereAnimation` or on any particular animation/renderer package.

## Features

- Async `UIImage` blur with cancellation and typed errors.
- Low-level encoding into a caller-owned Metal command buffer.
- `MetalBlurFrameSource` for latest-frame delivery with GPU readiness and exactly-once
  producer cleanup.
- `MetalBlurView` for zero-copy GPU-to-GPU SwiftUI integration.
- `CapturedBlurView` for SwiftUI content that must first be rasterized into an IOSurface.
- A device benchmark/export protocol under [`Benchmarks/`](Benchmarks/README.md).

## Requirements

- iOS 18.0+
- Xcode 16.0+
- Swift 6.0+

## Installation

For the current package, add the repository's `main` branch while the next release is
being prepared:

```swift
dependencies: [
    .package(url: "https://github.com/smkhlv/DualKawaseBlur.git", branch: "main")
]
```

In Xcode, choose **File → Add Package Dependencies** and enter the same URL. Pin a
version tag for production once it has been published.

## UIImage blur

`blur(_:configuration:)` is asynchronous and runs the Metal work away from the caller's
main-thread UI code. Cancellation is checked before encoding, after GPU completion, and
before image conversion.

```swift
import DualKawaseBlur

Task { @MainActor in
    do {
        let engine = try DualKawaseBlurEngine()
        let configuration = BlurConfiguration(iterations: 3, offset: 2)
        let blurred = try await engine.blur(image, configuration: configuration)
        imageView.image = blurred
    } catch is CancellationError {
        // The task was cancelled; no result is delivered.
    } catch let error as DualKawaseBlurError {
        print(error.localizedDescription)
    }
}
```

`BlurConfiguration` requires a positive finite `offset`, positive `iterations`, and an
image large enough for the requested downsample pyramid. Invalid input is reported as
`DualKawaseBlurError.invalidConfiguration`.

## Low-level Metal encoding

Use this path when a renderer already owns the source/destination textures and command
buffer. The source and destination must belong to the same `MTLDevice` as the engine.
`encode` records work only; the caller owns synchronization, commit, and texture
lifetime.

```swift
let engine = try DualKawaseBlurEngine(device: device)
let configuration = BlurConfiguration(iterations: 3, offset: 2)
try engine.encode(
    source: sourceTexture,
    destination: destinationTexture,
    configuration: configuration,
    into: commandBuffer
)
commandBuffer.commit()
```

The engine retains its temporary pyramid until the command buffer completes. The caller
must keep `sourceTexture` and `destinationTexture` valid until the GPU has finished.

## Animated Metal frames

`MetalBlurFrameSource` is a latest-frame mailbox. A producer publishes a texture together
with either `.ready` or a `MTLSharedEvent` readiness value. The consumer encodes the wait,
samples the texture, and the package invokes `onConsumed` after the frame is consumed or
dropped. This makes a producer independent of the blur implementation and of
`SphereAnimation`.

```swift
let source = MetalBlurFrameSource()

MetalBlurView(
    source: source,
    configuration: BlurConfiguration(iterations: 3, offset: 2)
) {
    Text("Overlay")
}

source.publish(MetalBlurFrame(
    texture: renderedTexture,
    readiness: .sharedEvent(readinessEvent, value: readinessValue),
    onConsumed: { textureLease.release() }
))
```

The producer should call `finish()` during teardown. `publish` may be called from a
rendering callback; it does not wait for the consumer. A slow consumer receives the
newest available frame and stale pending frames are released.

The demo contains a dependency-free procedural producer in
`Examples/DualKawaseBlurDemo/.../DemoMetalFrameProducer.swift`. It renders a triangle into
a private texture pool, signals a shared event, and publishes `MetalBlurFrame`; it is a
reference for integrating any other Metal renderer.

## Capturing SwiftUI content

`CapturedBlurView` hosts a source view, rasterizes it with `CALayer.render(in:)`, applies
the blur, and places an optional overlay above the result:

```swift
CapturedBlurView(configuration: .init(iterations: 3, offset: 2)) {
    AnimatedContent()
} overlay: {
    Controls()
}
```

This path has a CPU rasterization and IOSurface handoff. Compositor-backed video,
protected content, and Metal-backed subviews are not guaranteed to appear in the capture;
use `MetalBlurFrameSource` for a renderer that can provide its own texture. Errors are
delivered through the `onError` closure.

## Lifetime and concurrency rules

- Keep all Metal textures and producer-owned leases alive until their command buffers
  complete.
- Encode a shared-event wait before sampling a frame that is not already `.ready`.
- Treat `onConsumed` as exactly-once cleanup; it may run because a frame was displaced,
  discarded, or consumed by the blur view.
- `MetalBlurFrameSource` is safe to publish from concurrent producer callbacks, but it has
  one consumer and intentionally retains only the newest pending frame.
- Keep critical sections around the source mailbox synchronous and small. Do not call
  producer code or block on a GPU wait while holding its mutex.

## Benchmarking

Use the demo's **Compare** tab to select the resolution and configuration, then export
the raw JSON. Follow [`Benchmarks/README.md`](Benchmarks/README.md) exactly, including
warm-up/sample counts, thermal notes, and device metadata. Simulator timings are useful
for smoke tests but are not publishable device evidence. Performance depends on the
device, resolution, configuration, and competing GPU work; this README intentionally
makes no universal speed claim relative to Apple's blur implementations.

## Example app

Open `Examples/DualKawaseBlurDemo/DualKawaseBlurDemo.xcodeproj` to try:

- **Image** — choose an image and compare async UIImage processing.
- **Captured** — blur SwiftUI content captured through an IOSurface.
- **Metal** — blur a procedural Metal producer through the frame contract.
- **Compare** — view the package, MPS Gaussian, and system material side by side and
  export a benchmark.

## Provenance and changes

Algorithm references, license boundaries, and original Suretare contributions are listed
in [`PROVENANCE.md`](PROVENANCE.md). Public API changes are recorded in
[`CHANGELOG.md`](CHANGELOG.md). See [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a
change or submitting measurements.

## License

DualKawaseBlur is released under the MIT License; see [`LICENSE`](LICENSE).

# ``DualKawaseBlur``

Blur still images, captured SwiftUI content, or animated Metal frames with a
Metal-backed Dual Kawase pipeline.

## Choose an integration level

### Still images

Create a ``DualKawaseBlurEngine`` and call its asynchronous `blur` method with a
``BlurConfiguration``. The operation reports ``DualKawaseBlurError`` values and honors
task cancellation.

### Existing Metal renderers

Call `DualKawaseBlurEngine.encode(source:destination:configuration:into:)` from a
caller-owned command buffer. Keep the textures alive until completion and commit the
buffer yourself.

For animated content, publish each rendered texture as a ``MetalBlurFrame`` through a
``MetalBlurFrameSource`` and display it with ``MetalBlurView``. Use
``MetalFrameReadiness/sharedEvent(_:value:)`` when the producer and consumer command
buffers are separate. The consumer performs the GPU-side wait; the producer's
`onConsumed` callback owns exactly-once lease cleanup.

```swift
let source = MetalBlurFrameSource()

MetalBlurView(source: source, configuration: .init(iterations: 3, offset: 2))

source.publish(MetalBlurFrame(
    texture: texture,
    readiness: .sharedEvent(event, value: signalValue),
    onConsumed: { lease.release() }
))
```

### SwiftUI content without a Metal texture

``CapturedBlurView`` rasterizes its source with `CALayer.render(in:)`, blurs the resulting
IOSurface, and displays an optional overlay. Compositor-backed video, protected content,
and Metal-backed subviews are not guaranteed to be captured; use the Metal frame contract
when the producer can provide a texture directly.

## Ownership and cancellation

`MetalBlurFrameSource` keeps only the newest pending frame. A displaced or discarded
frame invokes its `onConsumed` callback, and a consumed frame invokes it after the final
GPU consumer has completed. Do not block or call arbitrary producer code while holding a
mailbox mutex. Finish a source during producer teardown with ``MetalBlurFrameSource/finish()``.

The demo's procedural producer shows a complete private-texture pool and shared-event
setup without depending on another package.

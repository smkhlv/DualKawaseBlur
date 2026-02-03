# Dual Kawase Blur

High-performance Dual Kawase Blur implementation for iOS using Metal.

## Features

- Fast GPU-accelerated blur using Metal
- Real-time 60fps blur for animated content (`BlurContainer`)
- Static image blur (`DualKawaseBlurEngine`)
- High-quality Dual Kawase algorithm
- SwiftUI and UIKit support
- Configurable blur strength (iterations) and radius (offset)

## Requirements

- iOS 15.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/DualKawaseBlur.git", from: "1.0.0")
]
```

Or in Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/yourusername/DualKawaseBlur.git`
3. Select version and add to target

## Usage

### Real-time Blur (SwiftUI)

Use `BlurContainer` to blur dynamic or animated content at 60fps:

```swift
import DualKawaseBlur

BlurContainer(iterations: 3, offset: 2.0) {
    // Content to blur
    AnimatedGradientView()
} overlay: {
    // Content displayed on top of blur
    Text("Hello, Blur!")
        .foregroundColor(.white)
}
```

### Real-time Blur (UIKit)

```swift
import DualKawaseBlur

let container = BlurContainerView()
container.iterations = 3
container.offset = 2.0
container.sourceView = animatedBackgroundView
container.overlayView = labelView
```

### Static Image Blur

Use `DualKawaseBlurEngine` for one-time image processing:

```swift
import DualKawaseBlur

let engine = try DualKawaseBlurEngine()

let blurred = engine.blur(
    image: myImage,
    iterations: 3,  // 1-5: blur strength (higher = stronger)
    offset: 2.0     // 1.0-5.0: blur radius (higher = wider)
)
```

### Parameters

- **iterations** (1-5): Number of downsample/upsample passes
  - `1`: Light blur
  - `3`: Medium blur (default, similar to Gaussian σ≈10)
  - `5`: Strong blur

- **offset** (1.0-5.0): Blur radius multiplier
  - `1.0`: Tight blur
  - `2.0`: Standard blur (default)
  - `5.0`: Wide blur

### Performance

For 1024×1024 image on iPhone 12+:
- 3 iterations: ~5-10ms
- Texture pyramid cached - changing only offset is very fast

### Animating Content Inside BlurContainer

When using `BlurContainer` with animations, use `TimelineView` to provide real interpolated values:

```swift
TimelineView(.animation) { timeline in
    let phase = sin(timeline.date.timeIntervalSinceReferenceDate) * 0.5 + 0.5

    BlurContainer(iterations: 3, offset: 2.0) {
        MyAnimatedView(phase: phase)
    } overlay: {
        Text("Blurred!")
    }
}
```

> **Note:** Standard SwiftUI `withAnimation` won't work inside `BlurContainer` because the content is captured via `drawHierarchy`. Use `TimelineView` with computed values instead.

### Memory Management

```swift
// Clear cached textures when needed
engine.clearCache()        // DualKawaseBlurEngine
container.clearCache()     // BlurContainerView

// Call on memory warning
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { _ in
    engine.clearCache()
}
```

## Example App

See `Examples/DualKawaseBlurDemo` for interactive demo with:
- **Image tab**: Static image blur with picker
- **Live tab**: Real-time animated blur demo
- Real-time parameter sliders

Run the demo:
```bash
cd Examples/DualKawaseBlurDemo
open DualKawaseBlurDemo.xcodeproj
```

## Algorithm Details

Dual Kawase Blur uses a two-pass approach:

1. **Downsample**: Progressively reduce image resolution with 5-tap filter
2. **Upsample**: Progressively increase resolution with 8-tap filter

Result: High-quality blur with better performance than standard Gaussian blur.

## Credits

Based on the Dual Kawase Blur algorithm.

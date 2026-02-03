# Dual Kawase Blur

High-performance Dual Kawase Blur implementation for iOS using Metal.

## Features

- Fast GPU-accelerated blur using Metal
- High-quality Dual Kawase algorithm
- Simple one-line API
- Configurable blur strength (iterations) and radius (offset)
- Minimal dependencies (UIKit, Metal, MetalKit)

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

```swift
import DualKawaseBlur

// Initialize engine once
let engine = try DualKawaseBlurEngine()

// Apply blur
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

### Memory Management

```swift
// Clear cached textures when needed
engine.clearCache()

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
- Image picker integration
- Real-time parameter sliders
- Live blur preview

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

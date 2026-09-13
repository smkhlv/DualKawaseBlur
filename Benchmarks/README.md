# Benchmark protocol

The demo benchmark compares Dual Kawase blur with `MPSImageGaussianBlur` using the same pre-created BGRA8 source texture and equivalent destinations.

1. Build and run the demo in Release on a physical iPhone or iPad.
2. Disconnect the debugger, close other applications, disable Low Power Mode, and keep the device unplugged at a stable brightness.
3. Wait until the reported thermal state is `nominal`.
4. Select the resolution and Dual Kawase configuration, then run the benchmark without interacting with the device.
5. Each run first matches Gaussian sigma by impulse-response second moment and checks normalized RMSE on deterministic fixtures.
6. The timed phase performs 30 warm-up and 300 measured iterations per algorithm, alternating algorithm order between trials.
7. Export the JSON file and retain it unchanged with the device model, GPU, OS build, thermal state, refresh range, raw samples, and matching residuals.
8. Repeat each configuration at least three times and investigate outliers or thermal-state changes before aggregating results.

Core timings exclude image loading, SwiftUI capture, presentation, and result readback. CPU encode and command-buffer GPU duration are reported separately. Simulator exports are marked `environment: simulator`; they are harness smoke tests and are not publishable performance evidence.

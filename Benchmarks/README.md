# Benchmark protocol

The demo benchmark is available in **Compare → Benchmark & Export**. It measures six paths using the exact opaque sRGB/BGRA8 pixels and independently selected parameters from the visual preview: baseline render-pass Dual Kawase; the accepted compute baseline with 5-tap downsample, 8-tap intermediate restores and a 3-tap final restore; the all-level Moment-matched path with 5/4/3 taps and the pipeline-default threadgroup; that same 5/4/3 path with a preflight-selected threadgroup; a candidate with 4/4/3 taps using the same selected threadgroup; and full-resolution `MPSImageGaussianBlur`. System Material remains a visual reference and is not timed. Historical compute experiments that did not provide a useful quality/performance tradeoff are no longer part of the active comparison.

1. Build and run the demo in Release on a physical iPhone or iPad.
2. Disconnect the debugger, close other applications, disable Low Power Mode, and keep the device unplugged at a stable brightness.
3. Wait until the reported thermal state is `nominal`.
4. Open Compare, choose a photo (or Sample), and set Dual iterations/offset, MPS sigma and Material in Settings. All panels use the same center crop. Processing dimensions follow the preview size and display scale; the benchmark sheet shows their exact pixel dimensions. Keep orientation and layout fixed across runs.
5. Open Benchmark & Export to freeze those pixels and parameters, then Run Benchmark. There is no automatic sigma matching and no claim of equivalent perceptual strength. Photo decoding, source preparation and hashing are outside the timed loop.
6. Before the main timed phase, the harness tests a bounded set of valid two-dimensional threadgroup shapes against the unchanged 5/4/3 all-level kernel. It performs 10 warm-up and 50 measured iterations per shape, rotates their order, and chooses the lowest GPU p50. The preflight is outside the reported 30 warm-up and 300 measured samples. The main phase compares both the pipeline-default and selected shapes directly, so a noisy preflight winner remains visible rather than being presented as an automatic improvement.
7. The timed phase performs 30 warm-up and 300 measured iterations per variant, rotating the first-encoded variant every iteration. The 4-tap downsample replaces the 5-tap center-plus-diagonals filter with four equal diagonal samples at a moment-matched distance; pyramid depth, intermediate/final kernels, offset and selected threadgroup stay unchanged. This isolates sampling-cost changes from scheduling changes.
8. Export JSON from the same sheet. Schema v9 retains hardware metadata, raw samples and percentiles, reduction depth, downsample/intermediate/final tap counts, threadgroup dimensions and selection method, `parameterSelection: manual`, and a SHA-256 of the source BGRA8 pixels. `threadgroupTuning` records every preflight candidate, its GPU p50, the pipeline default and the selected winner. Compute paths include normalized luma RMSE against full-resolution MPS and render-pass Dual; each optimization also records direct luma RMSE against the immediately preceding baseline. Quality readback occurs only after timed samples. These metrics are regression signals, not perceptual equivalence claims. `systemMaterial` records the selected style and `timingIncluded: false`. The image itself is not included; keep the source separately if reproducibility is needed.
9. Repeat each configuration at least three times and investigate outliers or thermal-state changes before aggregating results.

Core timings exclude image loading, SwiftUI capture, presentation, and result readback. CPU encode and command-buffer GPU duration are reported separately. Simulator exports are marked `environment: simulator`; they are harness smoke tests and are not publishable performance evidence.

The old separate Benchmark tab has been removed. Schema-v1 through schema-v8 exports remain historical data; validate them against the schema at their originating revision. Memory fields are optional because unavailable measurements are omitted by Codable, not reported as zero. The resident-memory before/after values describe the entire six-variant run, not per-algorithm allocation costs.

Export validation checks (from the package root; no simulator required):

```sh
swiftc -swift-version 6 \
  Examples/DualKawaseBlurDemo/DualKawaseBlurDemo/Sources/Benchmark/BenchmarkRecord.swift \
  Examples/DualKawaseBlurDemo/DualKawaseBlurDemo/Sources/Benchmark/BenchmarkExport.swift \
  Benchmarks/Tests/ExportValidation.swift -o /tmp/blur-export-validation
/tmp/blur-export-validation
# Optionally pass an exported JSON path to also validate a real run.
```

# Contributing to DualKawaseBlur

Thanks for helping improve the package. Changes should preserve the public frame
contract, GPU ownership rules, and the reproducibility of the benchmark protocol.

## Development requirements

- macOS with Xcode 16 or newer
- An iOS 18 SDK
- A Metal-capable device for performance measurements

Clone the repository, open the package or demo project, and run the narrowest relevant
test first. Typical package checks are:

```bash
swift test --package-path .
xcodebuild -scheme DualKawaseBlur \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
xcodebuild -scheme DualKawaseBlur \
  -destination 'generic/platform=iOS' \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
```

The demo is an Xcode project under `Examples/DualKawaseBlurDemo`. Use its **Compare** tab
to export measurements. Follow [`Benchmarks/README.md`](Benchmarks/README.md); include
the raw JSON, device/OS metadata, thermal state, configuration, and whether the run was
on a simulator. Do not report simulator timings as device evidence and do not replace a
raw export with a hand-edited table.

## API and implementation guidance

- Keep public examples compiling against the current API.
- Keep `MetalBlurFrameSource` latest-frame semantics and exactly-once `onConsumed`
  cleanup intact.
- A frame readiness wait belongs in the GPU command stream, not in a CPU blocking call.
- Mutex sections must remain synchronous and small. Never invoke producer callbacks or
  wait for a command buffer while holding a `Mutex`.
- Keep texture leases alive until the final command buffer that samples them completes.
- Add tests for lifecycle, cancellation, invalid configurations, and error propagation
  when changing those paths.

## Pull requests

Describe the user-visible behavior, affected public APIs, verification commands, and any
device measurements. Keep unrelated formatting or generated-file changes out of the
patch. New performance claims require reproducible raw exports and a clear comparison
protocol.

Before requesting review, run `git diff --check`, the package tests, and the applicable
Xcode build. CI runs the standalone package tests and an unsigned Release iOS build.

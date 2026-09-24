# Provenance

DualKawaseBlur is an independent Swift/Metal implementation released under the MIT
License in [`LICENSE`](LICENSE). The following works informed the algorithm and the
documentation:

- **Masaki Kawase** — the Kawase blur technique and its multi-resolution sampling idea.
- **Marius Bjørge / ARM, SIGGRAPH 2015** — *Efficient Gaussian Blur with Linear Sampling*,
  which explains reducing blur cost through linear filtering and a smaller sample set.
- **Frost Kiwi** — practical explanations and visualizations of the Dual Kawase pattern.
- **Adrian Nemeth / KDE D9848** — an implementation discussion used as a conceptual
  reference for pass structure and trade-offs.

The KDE material is GPL-licensed. No KDE source code, shader text, or GPL implementation
was copied into this package; only publicly described concepts were consulted. The
package's shaders, Swift API, and integration code were written for Suretare.

## Original Suretare contributions

- A Swift 6 public API for async `UIImage` processing and caller-owned Metal encoding.
- The `MetalBlurFrame` / `MetalBlurFrameSource` contract for readiness events, latest-frame
  delivery, and exactly-once producer lease cleanup.
- SwiftUI `MetalBlurView` and `CapturedBlurView` integration with typed errors and
  cancellation-aware scheduling.
- The dependency-free procedural Metal producer used by the demo.
- Reproducible benchmark export, schema validation, and comparison guidance for real
  devices.

Attribution does not imply that the referenced projects endorse this package. See
[`LICENSE`](LICENSE) for the complete license text.

# Changelog

All notable changes to DualKawaseBlur are documented here. The current `main` branch
contains the next release work; release tags are created only after the verification
checklist is complete.

## Unreleased

- Document the public `UIImage`, low-level Metal, animated-frame, and captured-SwiftUI
  integration paths.
- Keep the frame contract independent of any animation producer, including
  `SphereAnimation`.
- Add typed configuration/errors, cancellation notes, lifetime rules, and DocC examples.
- Add reproducible device benchmark/export documentation and standalone package CI.
- Record algorithm provenance and the boundary between conceptual references and original
  implementation.

## 1.0.0

- Initial modernized Swift 6 / iOS 18 package release.
- Metal Dual Kawase renderer with SwiftUI and UIKit integration.

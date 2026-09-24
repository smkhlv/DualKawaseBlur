import SwiftUI

struct ComparisonSettingsView: View {
    @Bindable var model: ComparisonViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Dual Kawase") {
                    Stepper("Iterations: \(model.iterations)", value: $model.iterations, in: 1...5)
                    LabeledContent("Offset", value: model.offset.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.offset, in: 0.5...5, step: 0.1)
                        .accessibilityLabel("Dual Kawase offset")
                }
                Section("MPS Gaussian") {
                    LabeledContent("Sigma (preview pixels)", value: model.sigma.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.sigma, in: 0.5...96, step: 0.5)
                        .accessibilityLabel("MPS Gaussian sigma")
                }
                Section("System Material") {
                    Picker("Style", selection: $model.material) {
                        ForEach(ComparisonMaterial.allCases) { material in
                            Text(material.rawValue).tag(material)
                        }
                    }
                }
                Section {
                    Text("Parameters are independent; equal blur strength is not assumed. Material includes system tint and blending and follows the current appearance and accessibility settings.")
                    Text("Both texture filters use the same opaque sRGB image, BGRA8 values, and clamp-to-edge sampling. The photo is center-cropped to the preview, and sigma is measured in preview pixels. This screen does not measure performance.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Comparison settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

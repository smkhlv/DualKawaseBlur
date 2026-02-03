import SwiftUI

struct ControlPanel: View {
    @Binding var iterations: Int
    @Binding var offset: Float
    @Binding var isProcessing: Bool

    let onSelectImage: () -> Void
    let onApplyBlur: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Image selection button
            Button(action: onSelectImage) {
                Label("Select Image", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(isProcessing)

            Divider()

            // Iterations slider
            VStack(alignment: .leading, spacing: 8) {
                Text("Iterations: \(iterations)")
                    .font(.headline)

                Slider(value: Binding(
                    get: { Double(iterations) },
                    set: { iterations = Int($0.rounded()) }
                ), in: 1...5, step: 1)
                    .disabled(isProcessing)

                Text("1 = minimal blur, 5 = strong blur")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Offset slider
            VStack(alignment: .leading, spacing: 8) {
                Text("Offset: \(String(format: "%.1f", offset))")
                    .font(.headline)

                Slider(value: $offset, in: 1.0...5.0, step: 0.1)
                    .disabled(isProcessing)

                Text("Blur radius multiplier (1.0 - 5.0)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Apply button
            Button(action: onApplyBlur) {
                if isProcessing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Apply Blur")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .disabled(isProcessing)
        }
        .padding()
    }
}

#Preview {
    ControlPanel(
        iterations: .constant(3),
        offset: .constant(2.0),
        isProcessing: .constant(false),
        onSelectImage: {},
        onApplyBlur: {}
    )
}

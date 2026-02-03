import SwiftUI

struct BlurDemoView: View {
    @State private var selectedImage: UIImage?
    @State private var blurredImage: UIImage?
    @State private var iterations: Int = 3
    @State private var offset: Float = 2.0
    @State private var isProcessing: Bool = false
    @State private var showImagePicker: Bool = false

    private let blurEngine = try? DualKawaseBlurEngine()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Image display area
                GeometryReader { geometry in
                    ZStack {
                        Color.black.ignoresSafeArea()

                        if let image = blurredImage ?? selectedImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 64))
                                    .foregroundColor(.gray)

                                Text("Select an image to begin")
                                    .font(.headline)
                                    .foregroundColor(.gray)
                            }
                        }

                        if isProcessing {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                    }
                }

                // Control panel
                ControlPanel(
                    iterations: $iterations,
                    offset: $offset,
                    isProcessing: $isProcessing,
                    onSelectImage: {
                        showImagePicker = true
                    },
                    onApplyBlur: {
                        processBlur()
                    }
                )
            }
            .navigationTitle("Dual Kawase Blur")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView(selectedImage: $selectedImage)
            }
            .onChange(of: selectedImage) { _ in
                // Reset blurred image when new image selected
                blurredImage = nil
            }
        }
    }

    private func processBlur() {
        guard let image = selectedImage else {
            return
        }

        isProcessing = true

        // Process blur in background
        DispatchQueue.global(qos: .userInitiated).async {
            let result = blurEngine?.blur(
                image: image,
                iterations: iterations,
                offset: offset
            )

            DispatchQueue.main.async {
                self.blurredImage = result
                self.isProcessing = false
            }
        }
    }
}

#Preview {
    BlurDemoView()
}

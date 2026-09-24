import SwiftUI
import PhotosUI
import DualKawaseBlur

struct BlurDemoView: View {
    @State private var selectedTab = DemoTab.image

    var body: some View {
        TabView(selection: $selectedTab) {
            ImageBlurDemoView()
                .tabItem {
                    Label("Image", systemImage: "photo")
                }
                .tag(DemoTab.image)

            CapturedBlurDemoView()
                .tabItem {
                    Label("Captured", systemImage: "waveform")
                }
                .tag(DemoTab.captured)

            MetalBlurDemoView()
                .tabItem {
                    Label("Metal", systemImage: "circle.hexagongrid")
                }
                .tag(DemoTab.metal)

            BlurComparisonView()
                .tabItem {
                    Label("Compare", systemImage: "rectangle.split.3x1")
                }
                .tag(DemoTab.compare)
        }
    }
}

// MARK: - Image Blur Demo

struct ImageBlurDemoView: View {
    @State private var selectedImage: UIImage?
    @State private var blurredImage: UIImage?
    @State private var iterations: Int = 3
    @State private var offset: Float = 2.0
    @State private var isProcessing: Bool = false
    @State private var showImagePicker: Bool = false
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var processingTask: Task<Void, Never>?
    @State private var processingGeneration: UInt64 = 0
    @State private var presentedError: String?

    private let blurEngine = try? DualKawaseBlurEngine()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
            .navigationTitle("Image Blur")
            .navigationBarTitleDisplayMode(.inline)
            .photosPicker(
                isPresented: $showImagePicker,
                selection: $selectedPickerItem,
                matching: .images
            )
            .task(id: selectedPickerItem) {
                await loadSelectedImage()
            }
            .onChange(of: selectedImage) {
                blurredImage = nil
            }
            .alert(
                "Unable to Process Image",
                isPresented: Binding(
                    get: { presentedError != nil },
                    set: { if $0 == false { presentedError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { presentedError = nil }
            } message: {
                Text(presentedError ?? "Unknown error")
            }
            .onDisappear {
                processingTask?.cancel()
            }
        }
    }

    @MainActor
    private func processBlur() {
        processingTask?.cancel()
        guard let image = selectedImage, let blurEngine else { return }
        processingGeneration &+= 1
        let generation = processingGeneration
        let configuration = BlurConfiguration(iterations: iterations, offset: offset)
        isProcessing = true
        processingTask = Task {
            defer {
                if processingGeneration == generation {
                    isProcessing = false
                    processingTask = nil
                }
            }
            do {
                let result = try await blurEngine.blur(image, configuration: configuration)
                try Task.checkCancellation()
                guard processingGeneration == generation else { return }
                blurredImage = result
            } catch is CancellationError {
                // A newer request or view teardown superseded this work.
            } catch {
                if processingGeneration == generation, !Task.isCancelled {
                    presentedError = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func loadSelectedImage() async {
        guard let selectedPickerItem else { return }
        processingTask?.cancel()
        processingGeneration &+= 1
        processingTask = nil
        isProcessing = false
        do {
            guard let data = try await selectedPickerItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                presentedError = "The selected item is not a supported image."
                return
            }
            try Task.checkCancellation()
            selectedImage = image
        } catch is CancellationError {
            // `.task(id:)` cancels the previous selection load automatically.
        } catch {
            presentedError = error.localizedDescription
        }
    }
}

// MARK: - Captured Blur Demo

struct CapturedBlurDemoView: View {
    @State private var iterations: Int = 3
    @State private var offset: Float = 2.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // TimelineView provides real animation values for UIKit capture
                TimelineView(.animation) { timeline in
                    let phase = computePhase(from: timeline.date)

                    CapturedBlurView(
                        configuration: .init(iterations: iterations, offset: offset)
                    ) {
                        AnimatedGradientBackground(phase: phase)
                    } overlay: {
                        VStack(spacing: 8) {
                            Text("CPU-captured SwiftUI")
                                .font(.title2.weight(.semibold))
                                .foregroundColor(.white)

                            Text("iterations: \(iterations), offset: \(String(format: "%.1f", offset))")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            
                        }
                    }
                }

                // Controls
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Iterations: \(iterations)")
                            .font(.subheadline)
                        Slider(value: Binding(
                            get: { Double(iterations) },
                            set: { iterations = Int($0) }
                        ), in: 1...5, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Offset: \(String(format: "%.1f", offset))")
                            .font(.subheadline)
                        Slider(value: Binding(
                            get: { Double(offset) },
                            set: { offset = Float($0) }
                        ), in: 1...5, step: 0.1)
                    }
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .navigationTitle("Captured Blur")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func computePhase(from date: Date) -> CGFloat {
        let seconds = date.timeIntervalSinceReferenceDate
        let cycleLength: Double = 2.0 // 2 seconds per cycle
        let progress = seconds.truncatingRemainder(dividingBy: cycleLength * 2) / cycleLength
        // Create smooth back-and-forth motion (0 -> 1 -> 0)
        if progress <= 1 {
            return easeInOut(progress)
        } else {
            return easeInOut(2 - progress)
        }
    }

    private func easeInOut(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

// MARK: - Metal Blur Demo

struct MetalBlurDemoView: View {
    @State private var frames = MetalBlurFrameSource()
    @State private var iterations: Int = 3
    @State private var offset: Float = 2

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    DemoMetalFrameProducer(source: frames)

                    MetalBlurView(
                        source: frames,
                        configuration: .init(iterations: iterations, offset: offset)
                    ) {
                        VStack(spacing: 8) {
                            Text("GPU-to-GPU Metal")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)

                            Text("iterations: \(iterations), offset: \(String(format: "%.1f", offset))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                BlurControls(iterations: $iterations, offset: $offset)
            }
            .navigationTitle("Metal Blur")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BlurControls: View {
    @Binding var iterations: Int
    @Binding var offset: Float

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Iterations: \(iterations)")
                    .font(.subheadline)
                Slider(value: iterationsBinding, in: 1...5, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Offset: \(String(format: "%.1f", offset))")
                    .font(.subheadline)
                Slider(value: $offset, in: 1...5, step: 0.1)
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }

    private var iterationsBinding: Binding<Double> {
        Binding(
            get: { Double(iterations) },
            set: { iterations = Int($0.rounded()) }
        )
    }
}

// MARK: - Animated Background

struct AnimatedGradientBackground: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [.blue, .purple, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.orange)
                    .frame(width: 100, height: 100)
                    .offset(x: (phase * 2 - 1) * geometry.size.width * 0.3)
            }
        }
    }
}

#Preview {
    BlurDemoView()
}

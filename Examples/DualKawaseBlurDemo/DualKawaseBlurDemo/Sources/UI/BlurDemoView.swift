import SwiftUI
import DualKawaseBlur

struct BlurDemoView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ImageBlurDemoView()
                .tabItem {
                    Label("Image", systemImage: "photo")
                }
                .tag(0)

            LiveBlurDemoView()
                .tabItem {
                    Label("Live", systemImage: "waveform")
                }
                .tag(1)
        }
    }
}

// MARK: - Image Blur Demo (Original)

struct ImageBlurDemoView: View {
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
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView(selectedImage: $selectedImage)
            }
            .onChange(of: selectedImage) { _ in
                blurredImage = nil
            }
        }
    }

    private func processBlur() {
        guard let image = selectedImage else {
            return
        }

        isProcessing = true

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

// MARK: - Live Blur Demo

struct LiveBlurDemoView: View {
    @State private var iterations: Int = 3
    @State private var offset: Float = 2.0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // TimelineView provides real animation values for UIKit capture
                TimelineView(.animation) { timeline in
                    let phase = computePhase(from: timeline.date)

                    BlurContainer(iterations: iterations, offset: offset) {
                        AnimatedGradientBackground(phase: phase)
                    } overlay: {
                        VStack(spacing: 8) {
                            Text("Real-time Blur")
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
            .navigationTitle("Live Blur")
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

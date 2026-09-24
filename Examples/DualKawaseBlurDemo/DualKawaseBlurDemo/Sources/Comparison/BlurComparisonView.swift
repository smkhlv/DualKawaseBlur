import PhotosUI
import SwiftUI

struct BlurComparisonView: View {
    @State private var model = ComparisonViewModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingSettings = false
    @State private var benchmarkInput: ComparisonBenchmarkInput?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let size = CGSize(width: max(32, geometry.size.width),
                                      height: max(90, (geometry.size.height - 144) / 5))
                    let request = ComparisonRequest(
                        revision: model.sourceRevision,
                        width: max(32, Int(size.width * displayScale)),
                        height: max(32, Int(size.height * displayScale)),
                        iterations: model.iterations, offset: model.offset, sigma: model.sigma
                    )
                    let output = model.renderedRequest == request ? model.output : nil
                    VStack(spacing: 8) {
                      ScrollView {
                        VStack(spacing: 12) {
                            ComparisonPanel(
                                title: "Dual Kawase",
                                detail: "Full pyramid · \(model.iterations) reductions · offset \(model.offset.formatted(.number.precision(.fractionLength(1))))",
                                image: model.showOriginal ? output?.original : output?.dual,
                                material: nil, size: size
                            )
                            ComparisonPanel(
                                title: "3-tap moment-matched Dual",
                                detail: "5-tap down · 8-tap intermediate · 3-tap final",
                                image: model.showOriginal ? output?.original : output?.triangularMomentMatchedDual,
                                material: nil, size: size
                            )
                            ComparisonPanel(
                                title: "All-level moment-matched Dual",
                                detail: "Same \(model.iterations) reductions · 4-tap intermediate · 3-tap final",
                                image: model.showOriginal ? output?.original : output?.allLevelMomentMatchedDual,
                                material: nil, size: size
                            )
                            ComparisonPanel(
                                title: "4-tap downsample Dual",
                                detail: "Same \(model.iterations) reductions · 4-tap down/intermediate · 3-tap final",
                                image: model.showOriginal ? output?.original : output?.fourTapDownsampleDual,
                                material: nil, size: size
                            )
                            ComparisonPanel(
                                title: "MPS Gaussian",
                                detail: "σ \(model.sigma.formatted(.number.precision(.fractionLength(1)))) px",
                                image: model.showOriginal ? output?.original : output?.gaussian,
                                material: nil, size: size
                            )
                            ComparisonPanel(
                                title: "System Material", detail: model.material.rawValue,
                                image: output?.original,
                                material: model.showOriginal ? nil : model.material, size: size
                            )
                        }
                      }
                      Button("Benchmark & Export") {
                          guard let output else { return }
                          benchmarkInput = .init(pixels: output.sourcePixels, request: request,
                                                 materialStyle: model.material.rawValue)
                      }
                      .buttonStyle(.bordered)
                      .disabled(output == nil || model.isLoading)
                    }
                    .task(id: request) { await model.render(request) }
                }

                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.primary)
                        .accessibilityLabel("Comparison error: \(error)")
                }
                Toggle("Show original in all panels", isOn: $model.showOriginal)
                    .font(.subheadline)
                Text(reduceTransparency
                     ? "Reduce Transparency is enabled; it changes the system Material."
                     : "Same crop · independent settings · Material is visual only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("Compare blur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Text("Photo")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Sample", systemImage: "photo.on.rectangle") {
                        selectedPhoto = nil
                        model.useSample()
                    }
                    .labelStyle(.iconOnly)
                    Button("Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
                        .labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showingSettings) {
                ComparisonSettingsView(model: model)
            }
            .sheet(item: $benchmarkInput) { input in
                BenchmarkView(input: input)
            }
            .task(id: selectedPhoto) { await model.load(selectedPhoto) }
        }
    }
}

#Preview {
    BlurComparisonView()
}

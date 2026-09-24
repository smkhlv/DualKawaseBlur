import SwiftUI

struct BenchmarkView: View {
    let input: ComparisonBenchmarkInput
    @State private var model = BenchmarkViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("From Compare") {
                    LabeledContent("Preview pixels", value: "\(input.request.width) × \(input.request.height)")
                    LabeledContent("Dual iterations", value: "\(input.request.iterations)")
                    LabeledContent("Dual offset", value: input.request.offset.formatted())
                    LabeledContent("MPS sigma", value: input.request.sigma.formatted())
                    Text("Uses the exact image crop and settings shown in Compare. Parameters are manual; equivalent blur strength is not assumed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Protocol") {
                    LabeledContent("Variants", value: "6 isolated paths")
                    LabeledContent("Threadgroup preflight", value: "10 + 50 per shape")
                    LabeledContent("Warm-up", value: "30 per variant")
                    LabeledContent("Measured", value: "300 per variant")
                    Text("The preflight rotates valid threadgroup shapes for the current All-level kernel and selects GPU p50. Timed paths then compare default All-level, tuned All-level, and a four-tap downsample candidate using the same selected shape. Render Dual, the accepted three-tap profile, and full-resolution MPS remain controls. Quality readback is outside timing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Simulator output verifies the harness only and must not be used for published performance claims.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Text(model.status)
                    if !model.summary.isEmpty { Text(model.summary).font(.footnote) }
                    if model.isRunning { ProgressView(value: model.progress) }
                    if ProcessInfo.processInfo.thermalState != .nominal {
                        Label("Thermal state is not nominal", systemImage: "thermometer.high")
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if model.isRunning {
                        Button("Cancel", role: .destructive, action: model.cancel)
                    } else {
                        Button("Run Benchmark", systemImage: "gauge.with.dots.needle.67percent") {
                            model.start(input: input)
                        }
                    }
                    if let exportURL = model.exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export JSON", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.background)
            }
            .navigationTitle("Compare benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.cancel(); dismiss() }
                }
            }
            .onDisappear(perform: model.cancel)
            .alert("Benchmark Failed", isPresented: $model.isShowingError) {
                Button("OK", role: .cancel) { model.isShowingError = false }
            } message: { Text(model.errorMessage) }
        }
    }
}

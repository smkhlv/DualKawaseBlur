import SwiftUI

struct BenchmarkView: View {
    @State private var model = BenchmarkViewModel()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Workload") {
                    Picker("Resolution", selection: $model.resolutionIndex) {
                        ForEach(model.resolutions.indices, id: \.self) { index in
                            Text(model.resolutions[index].name).tag(index)
                        }
                    }
                    Stepper("Iterations: \(model.iterations)", value: $model.iterations, in: 1...5)
                    LabeledContent("Offset") {
                        TextField("Offset", value: $model.offset, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Protocol") {
                    LabeledContent("Warm-up", value: "30 per algorithm")
                    LabeledContent("Measured", value: "300 per algorithm")
                    Text("Simulator output verifies the harness only and must not be used for published performance claims.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Text(model.status)
                    if model.isRunning { ProgressView(value: model.progress) }
                    if ProcessInfo.processInfo.thermalState != .nominal {
                        Label("Thermal state is not nominal", systemImage: "thermometer.high")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if model.isRunning {
                        Button("Cancel", role: .destructive, action: model.cancel)
                    } else {
                        Button("Run Benchmark", systemImage: "gauge.with.dots.needle.67percent", action: model.start)
                    }
                    if let exportURL = model.exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export JSON", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Benchmark")
            .onDisappear(perform: model.cancel)
            .alert("Benchmark Failed", isPresented: $model.isShowingError) {
                Button("OK", role: .cancel) { model.isShowingError = false }
            } message: { Text(model.errorMessage) }
        }
    }
}

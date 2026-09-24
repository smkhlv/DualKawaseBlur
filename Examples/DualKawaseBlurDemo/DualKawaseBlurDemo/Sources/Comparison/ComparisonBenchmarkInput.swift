import Foundation

/// A benchmark never follows later photo/slider/layout changes in the comparison view.
struct ComparisonBenchmarkInput: Identifiable {
    let id = UUID()
    let pixels: Data
    let request: ComparisonRequest
    let materialStyle: String
}

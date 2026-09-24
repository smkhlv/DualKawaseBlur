/// Pixel dimensions and explicit independent filter controls identify a preview.
struct ComparisonRequest: Hashable {
    let revision: UInt64
    let width: Int
    let height: Int
    let iterations: Int
    let offset: Float
    let sigma: Float
}

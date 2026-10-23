import Foundation

/// Tracks when the opaque backing can protect previously confirmed surface content.
struct SharedBackgroundRevealState {
    enum Acknowledgement: Equatable {
        case stale
        case ignored
        case initialContentConfirmed
        case compatibleContentConfirmed
        case replacementContentConfirmed
    }

    private(set) var generation: UInt64 = 0
    private(set) var hasConfirmedContent = false
    private(set) var coverVisible = false

    @discardableResult
    mutating func advanceGeneration(incompatible: Bool) -> UInt64 {
        generation &+= 1
        if incompatible, hasConfirmedContent {
            coverVisible = true
        }
        return generation
    }

    mutating func acknowledge(
        generation acknowledgedGeneration: UInt64,
        succeeded: Bool,
        visible: Bool
    ) -> Acknowledgement {
        guard acknowledgedGeneration == generation else { return .stale }
        guard succeeded, visible else { return .ignored }

        let hadConfirmedContent = hasConfirmedContent
        let replacingConfirmedContent = coverVisible
        hasConfirmedContent = true
        coverVisible = false
        if replacingConfirmedContent { return .replacementContentConfirmed }
        return hadConfirmedContent ? .compatibleContentConfirmed : .initialContentConfirmed
    }
}

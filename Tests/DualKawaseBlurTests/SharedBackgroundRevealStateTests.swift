import Testing
@testable import DualKawaseBlur

@Test func initialBackingNeverNeedsTopCoverBeforeFirstConfirmedContent() {
    var state = SharedBackgroundRevealState()
    #expect(!state.coverVisible)
    #expect(!state.hasConfirmedContent)

    let firstSessionGeneration = state.advanceGeneration(incompatible: true)
    #expect(!state.coverVisible)
    let attachedGeneration = state.advanceGeneration(incompatible: false)
    #expect(!state.coverVisible)

    #expect(state.acknowledge(generation: firstSessionGeneration, succeeded: true, visible: true) == .stale)
    #expect(state.acknowledge(generation: attachedGeneration, succeeded: true, visible: true) == .initialContentConfirmed)
    #expect(!state.coverVisible)
}

@Test func incompatibleReplacementWaitsForCurrentGenerationAcknowledgement() {
    var state = SharedBackgroundRevealState()
    let initialGeneration = state.advanceGeneration(incompatible: true)
    #expect(state.acknowledge(generation: initialGeneration, succeeded: true, visible: true) == .initialContentConfirmed)

    let replacementGeneration = state.advanceGeneration(incompatible: true)
    #expect(state.coverVisible)
    #expect(state.acknowledge(generation: initialGeneration, succeeded: true, visible: true) == .stale)
    #expect(state.coverVisible)
    #expect(state.acknowledge(generation: replacementGeneration, succeeded: true, visible: true) == .replacementContentConfirmed)
    #expect(!state.coverVisible)
}

@Test func failedOrHiddenAcknowledgementPreservesOpaqueBackingAndReplacementCover() {
    var state = SharedBackgroundRevealState()
    let initialGeneration = state.advanceGeneration(incompatible: true)
    #expect(state.acknowledge(generation: initialGeneration, succeeded: false, visible: true) == .ignored)
    #expect(!state.coverVisible)
    #expect(state.acknowledge(generation: initialGeneration, succeeded: true, visible: true) == .initialContentConfirmed)

    let replacementGeneration = state.advanceGeneration(incompatible: true)
    #expect(state.acknowledge(generation: replacementGeneration, succeeded: false, visible: true) == .ignored)
    #expect(state.coverVisible)
    #expect(state.acknowledge(generation: replacementGeneration, succeeded: true, visible: false) == .ignored)
    #expect(state.coverVisible)
}

@Test func compatibleReattachmentInvalidatesCallbacksWithoutCoveringConfirmedDrawable() {
    var state = SharedBackgroundRevealState()
    let initialGeneration = state.advanceGeneration(incompatible: true)
    #expect(state.acknowledge(generation: initialGeneration, succeeded: true, visible: true) == .initialContentConfirmed)

    let detachedGeneration = state.advanceGeneration(incompatible: false)
    #expect(!state.coverVisible)
    #expect(state.hasConfirmedContent)
    #expect(state.acknowledge(generation: initialGeneration, succeeded: true, visible: true) == .stale)
    #expect(!state.coverVisible)

    let reattachedGeneration = state.advanceGeneration(incompatible: false)
    #expect(!state.coverVisible)
    #expect(state.acknowledge(generation: detachedGeneration, succeeded: true, visible: true) == .stale)
    #expect(state.acknowledge(generation: reattachedGeneration, succeeded: true, visible: true) == .compatibleContentConfirmed)
}

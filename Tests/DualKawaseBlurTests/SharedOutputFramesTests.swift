import Foundation
import Synchronization
import Testing
@testable import DualKawaseBlur

@Test func emptyStoreInstallsFirstThreeSlotGeneration() throws {
    let frames = SharedOutputFrames<String>(resources: [])
    #expect(frames.acquireLatest() == nil)
    #expect(frames.acquireWriter() == nil)
    #expect(frames.replaceResources(with: ["first-0", "first-1", "first-2"]))

    let writer = try #require(frames.acquireWriter())
    #expect(writer.complete(success: true))
    let latest = try #require(frames.acquireLatest())
    #expect(latest.resource == "first-0")
    latest.release()
}

@Test func independentReadersKeepReplacedOutputAliveUntilBothRelease() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let writer = try #require(frames.acquireWriter())
    #expect(writer.complete(success: true))
    let first = try #require(frames.acquireLatest())
    let second = try #require(frames.acquireLatest())

    let replacement = try #require(frames.acquireWriter())
    #expect(replacement.complete(success: true))

    first.release()
    first.release()
    #expect(frames.availableWriterCount == 1)

    second.release()
    #expect(frames.availableWriterCount == 2)
}

@Test func writerExhaustionDropsImmediatelyAndPreservesLatest() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let initial = try #require(frames.acquireWriter())
    #expect(initial.complete(success: true))

    let second = try #require(frames.acquireWriter())
    let third = try #require(frames.acquireWriter())
    #expect(frames.acquireWriter() == nil)

    let latest = try #require(frames.acquireLatest())
    #expect(latest.resource == initial.resource)
    #expect(latest.sequence == initial.sequence)

    second.cancelBeforeSubmission()
    third.cancelBeforeSubmission()
    latest.release()
}

@Test func outOfOrderSuccessfulCompletionCannotRegressLatestSequence() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let initial = try #require(frames.acquireWriter())
    #expect(initial.complete(success: true))
    let older = try #require(frames.acquireWriter())
    let newer = try #require(frames.acquireWriter())
    #expect(newer.sequence > older.sequence)

    #expect(newer.complete(success: true))
    #expect(!older.complete(success: true))

    let latest = try #require(frames.acquireLatest())
    #expect(latest.sequence == newer.sequence)
    #expect(latest.resource == newer.resource)
    latest.release()
}

@Test func failedWriterRetainsLastSuccessfulOutput() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let initial = try #require(frames.acquireWriter())
    #expect(initial.complete(success: true))
    let failure = try #require(frames.acquireWriter())

    #expect(!failure.complete(success: false))
    let latest = try #require(frames.acquireLatest())
    #expect(latest.sequence == initial.sequence)
    #expect(latest.resource == initial.resource)
    latest.release()
}

@Test func oldGenerationWriterCannotPublishAndRetiredGenerationWaitsForReaders() throws {
    let frames = SharedOutputFrames(resources: ["old-0", "old-1", "old-2"])
    let initial = try #require(frames.acquireWriter())
    #expect(initial.complete(success: true))
    let oldReader = try #require(frames.acquireLatest())
    let staleWriter = try #require(frames.acquireWriter())

    #expect(frames.replaceResources(with: ["new-0", "new-1", "new-2"]))
    #expect(!frames.replaceResources(with: ["later-0", "later-1", "later-2"]))
    #expect(!staleWriter.complete(success: true))

    let currentWriter = try #require(frames.acquireWriter())
    #expect(currentWriter.complete(success: true))
    #expect(!frames.replaceResources(with: ["later-0", "later-1", "later-2"]))

    oldReader.release()
    #expect(frames.replaceResources(with: ["later-0", "later-1", "later-2"]))
}

@Test func finishRejectsNewWritersAndNeverPublishesSubmittedWork() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let writer = try #require(frames.acquireWriter())
    frames.finish()

    #expect(!writer.complete(success: true))
    #expect(frames.acquireWriter() == nil)
    #expect(frames.acquireLatest() == nil)
}

@Test func finishKeepsSubmittedReaderPinnedUntilItsCompletion() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let writer = try #require(frames.acquireWriter())
    #expect(writer.complete(success: true))
    let submittedReader = try #require(frames.acquireLatest())
    frames.finish()

    #expect(frames.acquireLatest() == nil)
    #expect(frames.acquireWriter() == nil)
    submittedReader.release()
    submittedReader.release()
    #expect(frames.availableWriterCount == 0)
}

@Test func replacementProgressesAfterStaleWriterDrainsWithoutWaitingForOldReader() throws {
    let frames = SharedOutputFrames(resources: ["x0", "x1", "x2"])
    let xWriter = try #require(frames.acquireWriter())
    #expect(xWriter.complete(success: true))
    let xReader = try #require(frames.acquireLatest())

    #expect(frames.replaceResources(with: ["a0", "a1", "a2"]))
    let staleAWriter = try #require(frames.acquireWriter())
    frames.advanceTargetRevision()
    #expect(!frames.prepareForResourceReplacement())
    #expect(!staleAWriter.complete(success: true))

    #expect(frames.prepareForResourceReplacement())
    #expect(frames.replaceResources(with: ["b0", "b1", "b2"]))
    let bWriter = try #require(frames.acquireWriter())
    #expect(bWriter.complete(success: true))
    #expect(xReader.resource == "x0")

    let bReader = try #require(frames.acquireLatest())
    #expect(bReader.resource == "b0")
    #expect(!frames.prepareForResourceReplacement())
    xReader.release()
    #expect(frames.prepareForResourceReplacement())
    bReader.release()
}

@Test func staleOffsetRevisionCannotPublishOverLatestOutput() throws {
    let frames = SharedOutputFrames(resources: ["a", "b", "c"])
    let initial = try #require(frames.acquireWriter())
    #expect(initial.complete(success: true))
    let staleOffsetWork = try #require(frames.acquireWriter())

    // Offset is a render revision, but does not replace the resource generation.
    frames.advanceTargetRevision()
    #expect(!staleOffsetWork.complete(success: true))
    let latest = try #require(frames.acquireLatest())
    #expect(latest.sequence == initial.sequence)
    #expect(latest.resource == initial.resource)
    latest.release()

    let currentRevisionWork = try #require(frames.acquireWriter())
    #expect(currentRevisionWork.complete(success: true))
}


@Test func pinnedRevisionRejectsPublicationAfterInvalidation() throws {
    let outputs = SharedOutputFrames(resources: ["a", "b", "c"])
    let pinned = outputs.targetRevision
    outputs.advanceTargetRevision()
    let writer = try #require(outputs.acquireWriter(pinnedRevision: pinned))
    #expect(writer.complete(success: true) == false)
    #expect(outputs.acquireLatest() == nil)
}

@Test func pinnedWriterWaitsOutLockContentionInsteadOfDropping() throws {
    let outputs = SharedOutputFrames(resources: ["a", "b", "c"])
    let stop = Mutex(false)
    let contenderReads = Mutex(0)
    let contender = Thread {
        while !stop.withLock({ $0 }) {
            _ = outputs.targetRevision
            contenderReads.withLock { $0 += 1 }
        }
    }
    contender.start()
    defer { stop.withLock { $0 = true } }
    while contenderReads.withLock({ $0 }) == 0 {}

    var dropped = 0
    for _ in 0..<20_000 {
        guard let writer = outputs.acquireWriter(pinnedRevision: outputs.targetRevision) else {
            dropped += 1
            continue
        }
        writer.cancelBeforeSubmission()
    }
    #expect(dropped == 0)
}

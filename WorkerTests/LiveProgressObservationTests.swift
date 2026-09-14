import Foundation
import XCTest
@testable import BitMatchTransferCore

final class LiveProgressObservationTests: XCTestCase {
    func testDispatcherAdvertisesNonAuthoritativeLiveProgressCapability() {
        let capabilities = TransferWorkerDispatcher().capabilities()
        XCTAssertTrue(capabilities.capabilities.contains(TransferWorkerDispatcher.liveProgressCapability))
        XCTAssertTrue(capabilities.sourceReadOnly)
        XCTAssertTrue(capabilities.supportedProtocolVersions.contains(3))
        XCTAssertTrue(capabilities.supportedProtocolVersions.contains(4))
    }

    func testProgressObservationReceivesTheSameProgressObjectConstructionPath() async {
        let recorder = ProgressRecorder()
        await OperationProgressObservation.$sink.withValue({ recorder.record($0) }) {
            _ = OperationProgress(
                overallProgress: 0.25,
                currentFile: "DCIM/100MEDIA/CLIP001.MP4",
                filesProcessed: 1,
                totalFiles: 4,
                currentStage: .copying,
                speed: 12_000_000,
                timeRemaining: 9,
                elapsedTime: 3,
                averageSpeed: 10_000_000,
                peakSpeed: 15_000_000,
                bytesProcessed: 25,
                totalBytes: 100,
                stageProgress: 0.25,
                perDestinationTotals: [4, 4],
                perDestinationCompleted: [1, 1]
            )
        }

        let observed = recorder.latest
        XCTAssertEqual(observed?.filesProcessed, 1)
        XCTAssertEqual(observed?.totalFiles, 4)
        XCTAssertEqual(observed?.bytesProcessed, 25)
        XCTAssertEqual(observed?.totalBytes, 100)
        XCTAssertEqual(observed?.currentFile, "DCIM/100MEDIA/CLIP001.MP4")
    }

    func testV3FanOutEmitsIntraFileByteProgressBeforeLargeFileCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-live-progress-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let byteCount = 12 * 1024 * 1024
        try Data(repeating: 0x5a, count: byteCount)
            .write(to: source.appendingPathComponent("large.bin"))
        let job = TransferJobSpec(
            protocolVersion: 3,
            jobID: UUID(),
            attemptID: UUID(),
            requestedAt: Date(),
            sourceRoot: source.path,
            destinations: [
                DestinationRequest(requestID: "destination", executionRoot: destination.path, role: .working),
            ]
        )
        let recorder = ProgressRecorder()

        let result = await OperationProgressObservation.$sink.withValue({ recorder.record($0) }) {
            await TransferWorkerRuntime().run(
                job: job,
                evidenceURL: root.appendingPathComponent("evidence.json")
            )
        }

        XCTAssertEqual(result.exitCode, .success)
        let intermediate = recorder.all.first {
            $0.currentStage == .copying
                && ($0.bytesProcessed ?? 0) > 0
                && ($0.bytesProcessed ?? Int64.max) < Int64(byteCount)
        }
        XCTAssertNotNil(intermediate)
        XCTAssertEqual(intermediate?.currentFile, "large.bin")
        XCTAssertEqual(intermediate?.totalBytes, Int64(byteCount))
        let verification = recorder.all.first {
            $0.currentStage == .verifying && $0.currentFile == "large.bin"
        }
        XCTAssertNotNil(verification)
        XCTAssertEqual(verification?.bytesProcessed, Int64(byteCount))
        XCTAssertEqual(verification?.totalBytes, Int64(byteCount))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: OperationProgress?
    private var history: [OperationProgress] = []

    var latest: OperationProgress? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var all: [OperationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    func record(_ progress: OperationProgress) {
        lock.lock()
        storage = progress
        history.append(progress)
        lock.unlock()
    }
}

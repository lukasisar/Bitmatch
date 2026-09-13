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
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: OperationProgress?

    var latest: OperationProgress? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ progress: OperationProgress) {
        lock.lock()
        storage = progress
        lock.unlock()
    }
}

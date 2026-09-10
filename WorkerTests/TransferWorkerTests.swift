import CryptoKit
import Foundation
import XCTest
@testable import BitMatchTransferCore

#if canImport(Darwin)
import Darwin

private final class FaultingDurabilityIO: TransferDurabilityIO, @unchecked Sendable {
    var fullSyncOutcome: TransferSystemCallOutcome = .succeeded
    var directorySyncOutcome: TransferSystemCallOutcome = .succeeded
    var cacheBypassOutcome: TransferSystemCallOutcome = .succeeded
    var returnShortRead = false
    var corruptReadback = false
    var publicationHook: ((String) throws -> Void)?
    var sourceVerificationHook: ((String) throws -> Void)?
    var fullSyncObserver: ((Int32) -> Void)?
    private let lock = NSLock()
    private var readCallsStorage = 0

    var readCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCallsStorage
    }

    func fullSync(fileDescriptor: Int32) -> TransferSystemCallOutcome {
        fullSyncObserver?(fileDescriptor)
        return fullSyncOutcome
    }
    func syncDirectory(fileDescriptor: Int32) -> TransferSystemCallOutcome { directorySyncOutcome }
    func requestCacheBypass(fileDescriptor: Int32) -> TransferSystemCallOutcome { cacheBypassOutcome }
    func prepareForPublication(destinationPath: String) throws { try publicationHook?(destinationPath) }
    func prepareForSourceVerification(sourcePath: String) throws { try sourceVerificationHook?(sourcePath) }

    func readDestination(fileDescriptor: Int32, maximumCount: Int) throws -> Data {
        lock.lock()
        readCallsStorage += 1
        let call = readCallsStorage
        lock.unlock()
        if returnShortRead, call == 1 { return Data() }

        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = Darwin.read(fileDescriptor, &buffer, maximumCount)
        guard count >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var data = Data(buffer.prefix(count))
        if corruptReadback, call == 1, !data.isEmpty {
            data[data.startIndex] ^= 0xff
        }
        return data
    }
}
#endif

final class TransferWorkerTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destinationA: URL!
    private var destinationB: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-worker-tests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destinationA = root.appendingPathComponent("destination-a", isDirectory: true)
        destinationB = root.appendingPathComponent("destination-b", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let fixture = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/source") else {
            XCTFail("Missing deterministic source fixture")
            return
        }
        try FileManager.default.copyItem(at: fixture, to: source)
        try FileManager.default.createDirectory(at: destinationA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationB, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testProtocolRoundTripAndSafeDefault() throws {
        let job = makeJob()
        let data = try TransferWorkerRuntime.makeEncoder().encode(job)
        let decoded = try TransferWorkerRuntime.makeDecoder().decode(TransferJobSpec.self, from: data)
        XCTAssertEqual(decoded, job)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "verificationPolicy")
        let withoutPolicy = try JSONSerialization.data(withJSONObject: object)
        let defaulted = try TransferWorkerRuntime.makeDecoder().decode(TransferJobSpec.self, from: withoutPolicy)
        XCTAssertEqual(defaulted.verificationPolicy, .sha256)
    }

    func testFutureEvidenceVersionIsRejectedBeforeFieldsAreTrusted() async throws {
        let result = await TransferWorkerRuntime().run(
            job: makeJob(),
            evidenceURL: root.appendingPathComponent("versioned-evidence.json")
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: TransferWorkerRuntime.makeEncoder().encode(try XCTUnwrap(result.evidence))
        ) as? [String: Any])
        object["protocolVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try TransferWorkerRuntime.makeDecoder().decode(TransferEvidence.self, from: future)
        )
    }

    func testCapabilitiesAreDeterministicAndDescribeReadOnlySHA256Worker() throws {
        let runtime = TransferWorkerRuntime()
        let first = try TransferWorkerRuntime.makeEncoder().encode(runtime.capabilities())
        let second = try TransferWorkerRuntime.makeEncoder().encode(runtime.capabilities())
        XCTAssertEqual(first, second)
        XCTAssertTrue(runtime.capabilities().sourceReadOnly)
        XCTAssertEqual(runtime.capabilities().supportedProtocolVersions, [2])
        XCTAssertEqual(runtime.capabilities().supportedVerificationPolicies, ["sha256"])
        XCTAssertEqual(runtime.capabilities().upstreamRevision, TransferWorkerIdentity.upstreamRevision)
    }

    func testExactResultSetValidatorAcceptsCompleteCartesianProduct() {
        let validation = validateResultSet(completeResultObservations())

        XCTAssertTrue(validation.isExact)
        XCTAssertTrue(validation.errors.isEmpty)
        XCTAssertEqual(
            validation.verificationOutcome(candidate: .verifiedStrong, sourceStableAcrossAttempt: true),
            .verifiedStrong
        )
        XCTAssertEqual(
            validation.verificationOutcome(candidate: .verifiedDegraded, sourceStableAcrossAttempt: true),
            .verifiedDegraded
        )
    }

    func testResultSetValidatorRejectsOneMissingPairAndFailsClosed() {
        var observations = completeResultObservations()
        observations.removeLast()
        let validation = validateResultSet(observations)

        XCTAssertEqual(validation.errors.map(\.code), ["result-set-incomplete"])
        XCTAssertEqual(
            validation.verificationOutcome(candidate: .verifiedStrong, sourceStableAcrossAttempt: true),
            .failed
        )
        XCTAssertEqual(
            validation.verificationOutcome(candidate: .verifiedDegraded, sourceStableAcrossAttempt: true),
            .failed
        )
    }

    func testResultSetValidatorRejectsDuplicatePair() {
        var observations = completeResultObservations()
        observations.append(observations[0])
        let validation = validateResultSet(observations)

        XCTAssertEqual(validation.errors.map(\.code), ["result-set-duplicate"])
        XCTAssertEqual(
            validation.verificationOutcome(candidate: .verifiedStrong, sourceStableAcrossAttempt: true),
            .failed
        )
    }

    func testResultSetValidatorRejectsUnexpectedSourceAndDestinationPairs() {
        var unexpectedSource = completeResultObservations()
        unexpectedSource.append(WorkerResultObservation(
            relativePath: "unexpected.mov",
            destinationRequestID: "destination-a",
            success: true,
            fileSize: 30
        ))
        var unexpectedDestination = completeResultObservations()
        unexpectedDestination.append(WorkerResultObservation(
            relativePath: "a.mov",
            destinationRequestID: "destination-c",
            success: true,
            fileSize: 10
        ))

        for validation in [validateResultSet(unexpectedSource), validateResultSet(unexpectedDestination)] {
            XCTAssertEqual(validation.errors.map(\.code), ["result-set-unexpected"])
            XCTAssertEqual(
                validation.verificationOutcome(candidate: .verifiedDegraded, sourceStableAcrossAttempt: true),
                .failed
            )
        }
    }

    func testResultSetValidatorRejectsOmittedDestination() {
        let observations = completeResultObservations().filter {
            $0.destinationRequestID == "destination-a"
        }
        let validation = validateResultSet(observations)

        XCTAssertFalse(validation.isExact)
        XCTAssertEqual(validation.errors.map(\.code), ["result-set-incomplete", "result-set-incomplete"])
        XCTAssertTrue(validation.errors.allSatisfy { $0.destinationRequestID == "destination-b" })
    }

    func testResultSetValidatorRejectsSuccessfulByteCountMismatch() {
        var observations = completeResultObservations()
        observations[0] = WorkerResultObservation(
            relativePath: observations[0].relativePath,
            destinationRequestID: observations[0].destinationRequestID,
            success: true,
            fileSize: 9
        )
        let validation = validateResultSet(observations)

        XCTAssertEqual(validation.errors.map(\.code), ["result-set-inconsistent"])
        XCTAssertEqual(
            validation.verificationOutcome(candidate: .verifiedStrong, sourceStableAcrossAttempt: true),
            .failed
        )
    }

    func testUnsupportedProtocolAndMandatoryCapabilityFailBeforeDestinationWrites() async throws {
        let unsupportedVersion = makeJob(protocolVersion: 1)
        let versionResult = await TransferWorkerRuntime().run(
            job: unsupportedVersion,
            evidenceURL: root.appendingPathComponent("unsupported-version.json")
        )
        XCTAssertEqual(versionResult.exitCode, .unsupportedProtocolOrCapability)
        XCTAssertEqual(versionResult.evidence?.terminalStatus, .unsupportedProtocolOrCapability)
        try assertDestinationHasNoOutput(destinationA)
        try assertDestinationHasNoOutput(destinationB)

        let unsupportedCapability = makeJob(
            requestedCapabilities: [CapabilityRequest(name: "unknown-required-capability", required: true)]
        )
        let capabilityResult = await TransferWorkerRuntime().run(
            job: unsupportedCapability,
            evidenceURL: root.appendingPathComponent("unsupported-capability.json")
        )
        XCTAssertEqual(capabilityResult.exitCode, .unsupportedProtocolOrCapability)
        try assertDestinationHasNoOutput(destinationA)
        try assertDestinationHasNoOutput(destinationB)
    }

    func testUnsupportedVerificationPolicyFailsClosedBeforeWrites() async throws {
        let job = TransferJobSpec(
            protocolVersion: 1,
            jobID: UUID(),
            attemptID: UUID(),
            requestedAt: Date(),
            sourceRoot: source.path,
            destinations: [DestinationRequest(
                requestID: "destination-a",
                executionRoot: destinationA.path,
                role: .backup
            )],
            verificationPolicy: .unsupported("quick"),
            requestedCapabilities: []
        )
        let result = await TransferWorkerRuntime().run(
            job: job,
            evidenceURL: root.appendingPathComponent("unsupported-policy.json")
        )
        XCTAssertEqual(result.exitCode, .unsupportedProtocolOrCapability)
        XCTAssertNil(result.evidence?.verificationPolicyUsed)
        try assertDestinationHasNoOutput(destinationA)
    }

    func testUnsafeAndNestedDestinationTopologyFailBeforeWrites() async throws {
        let insideSource = source.appendingPathComponent("unsafe-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: insideSource, withIntermediateDirectories: true)
        let sourceContainedJob = makeJob(destinations: [
            DestinationRequest(requestID: "unsafe", executionRoot: insideSource.path, role: .backup)
        ])
        let containmentResult = await TransferWorkerRuntime().run(
            job: sourceContainedJob,
            evidenceURL: root.appendingPathComponent("containment.json")
        )
        XCTAssertEqual(containmentResult.exitCode, .invalidJob)
        try assertDestinationHasNoOutput(insideSource)

        let nested = destinationA.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedJob = makeJob(destinations: [
            DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .working),
            DestinationRequest(requestID: "nested", executionRoot: nested.path, role: .backup),
        ])
        let nestedResult = await TransferWorkerRuntime().run(
            job: nestedJob,
            evidenceURL: root.appendingPathComponent("nested.json")
        )
        XCTAssertEqual(nestedResult.exitCode, .invalidJob)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationA.appendingPathComponent("source").path))
    }

    func testUnsafeEvidencePathInsideSourceIsRejectedWithoutMutatingSource() async throws {
        let before = try sourceSnapshot()
        let evidenceInsideSource = source.appendingPathComponent("must-not-be-written.json")
        let result = await TransferWorkerRuntime().run(job: makeJob(), evidenceURL: evidenceInsideSource)
        XCTAssertEqual(result.exitCode, .invalidJob)
        XCTAssertNil(result.evidence)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceInsideSource.path))
        XCTAssertEqual(try sourceSnapshot(), before)
        try assertDestinationHasNoOutput(destinationA)
        try assertDestinationHasNoOutput(destinationB)
    }

    func testTwoDestinationTransferProducesEvidenceAndDoesNotMutateSource() async throws {
        let before = try sourceSnapshot()
        let job = makeJob()
        let evidenceURL = root.appendingPathComponent("evidence.json")
        let result = await TransferWorkerRuntime().run(job: job, evidenceURL: evidenceURL)

        XCTAssertEqual(result.exitCode, .success, result.diagnostic ?? "")
        XCTAssertEqual(result.evidence?.terminalStatus, .succeeded)
        XCTAssertEqual(result.evidence?.jobID, job.jobID)
        XCTAssertEqual(result.evidence?.attemptID, job.attemptID)
        XCTAssertEqual(result.evidence?.destinations.count, 2)
        XCTAssertEqual(Set(result.evidence?.destinations.map(\.requestID) ?? []), ["destination-a", "destination-b"])
        XCTAssertEqual(result.evidence?.detailEvidence?.recordCount, 4)
        XCTAssertEqual(result.evidence?.upstreamRevision, TransferWorkerIdentity.upstreamRevision)
        XCTAssertEqual(result.evidence?.verificationPolicyUsed, "sha256")
        XCTAssertEqual(result.evidence?.verificationOutcome, .verifiedStrong)
        XCTAssertEqual(result.evidence?.source.stabilityVerifiedFiles, 2)
        XCTAssertTrue(result.evidence?.destinations.allSatisfy { $0.verificationOutcome == .verifiedStrong } == true)
        let expectedBytes = try XCTUnwrap(result.evidence).source.totalBytes
        XCTAssertTrue(result.evidence?.destinations.allSatisfy {
            $0.successfulFiles == 2
                && $0.failedFiles == 0
                && $0.verifiedBytes == expectedBytes
                && $0.strongFiles == 2
                && $0.degradedFiles == 0
        } == true)

        let decoded = try TransferWorkerRuntime.makeDecoder().decode(
            TransferEvidence.self,
            from: Data(contentsOf: evidenceURL)
        )
        XCTAssertEqual(decoded.terminalStatus, .succeeded)
        for destination in [destinationA!, destinationB!] {
            for filename in ["camera-like-file-1.bin", "camera-like-file-2.bin"] {
                let sourceFile = source.appendingPathComponent(filename)
                let copied = destination.appendingPathComponent("source/\(filename)")
                XCTAssertEqual(try digest(sourceFile), try digest(copied))
            }
        }
        XCTAssertEqual(try sourceSnapshot(), before)
    }

    func testConflictingExistingFileIsNotOverwrittenOrReportedAsSuccess() async throws {
        let initial = await TransferWorkerRuntime().run(
            job: makeJob(),
            evidenceURL: root.appendingPathComponent("initial-evidence.json")
        )
        XCTAssertEqual(initial.exitCode, .success)

        let conflict = destinationA.appendingPathComponent("source/camera-like-file-1.bin")
        let conflictBytes = Data("different-existing-output".utf8)
        try conflictBytes.write(to: conflict)
        let before = try Data(contentsOf: conflict)

        let rerun = await TransferWorkerRuntime().run(
            job: makeJob(attemptID: UUID()),
            evidenceURL: root.appendingPathComponent("conflict-evidence.json")
        )
        XCTAssertEqual(rerun.exitCode, .completedWithFailures)
        XCTAssertEqual(rerun.evidence?.terminalStatus, .completedWithFailures)
        XCTAssertFalse(rerun.evidence?.errors.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: conflict), before)
    }

    func testFullReadbackIsPerformedForEveryPublishedFile() async throws {
        let io = FaultingDurabilityIO()
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("readback.json")
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertGreaterThanOrEqual(io.readCalls, 4, "Each file requires data reads plus an EOF read")
        let records = try detailRecords(from: result)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy(\.fullDestinationReadbackPerformed))
        XCTAssertEqual(records.reduce(0) { $0 + $1.destinationReadbackBytes }, result.evidence?.source.totalBytes)
    }

    func testReadbackChecksumMismatchFails() async throws {
        let io = FaultingDurabilityIO()
        io.corruptReadback = true
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("mismatch.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        let records = try detailRecords(from: result)
        XCTAssertTrue(records.contains { $0.verificationOutcome == .failed })
        let rolledBack = records.filter { $0.publication == .removedAfterFailure }
        XCTAssertFalse(rolledBack.isEmpty)
        XCTAssertTrue(rolledBack.allSatisfy {
            !FileManager.default.fileExists(
                atPath: destinationA.appendingPathComponent("source/\($0.relativePath)").path
            )
        })
    }

    func testShortDestinationReadbackFails() async throws {
        let io = FaultingDurabilityIO()
        io.returnShortRead = true
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("short-read.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        XCTAssertTrue(result.evidence?.errors.contains { $0.code == "short-readback" } == true)
        XCTAssertTrue(try detailRecords(from: result).contains { $0.publication == .removedAfterFailure })
    }

    func testFullSyncFailureCannotReportStrongOrPublishFinalFile() async throws {
        let io = FaultingDurabilityIO()
        io.fullSyncOutcome = .failed(code: EIO, message: "simulated full sync failure")
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("full-sync-failure.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationA.appendingPathComponent("source/camera-like-file-1.bin").path))
        XCTAssertTrue(result.evidence?.errors.contains { $0.code == "full-sync-failed" } == true)
    }

    func testFullSyncObservesPreservedModificationTime() async throws {
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        for filename in ["camera-like-file-1.bin", "camera-like-file-2.bin"] {
            try FileManager.default.setAttributes(
                [.modificationDate: expectedDate],
                ofItemAtPath: source.appendingPathComponent(filename).path
            )
        }
        let io = FaultingDurabilityIO()
        let lock = NSLock()
        var observedSeconds: [Int] = []
        io.fullSyncObserver = { descriptor in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return }
            lock.lock()
            observedSeconds.append(info.st_mtimespec.tv_sec)
            lock.unlock()
        }

        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("mtime-before-full-sync.json")
        )

        XCTAssertEqual(result.evidence?.verificationOutcome, .verifiedStrong)
        XCTAssertEqual(observedSeconds.count, 2)
        XCTAssertTrue(observedSeconds.allSatisfy { $0 == Int(expectedDate.timeIntervalSince1970) })
    }

    func testUnsupportedFullSyncIsExplicitlyDegraded() async throws {
        let io = FaultingDurabilityIO()
        io.fullSyncOutcome = .unsupported(code: ENOTSUP, message: "simulated unsupported full sync")
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("full-sync-unsupported.json")
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.evidence?.verificationOutcome, .verifiedDegraded)
        XCTAssertTrue(result.evidence?.warnings.contains { $0.contains("F_FULLFSYNC") } == true)
        XCTAssertTrue(try detailRecords(from: result).allSatisfy { $0.durabilityFlush.status == .unsupported })
        let summary = try XCTUnwrap(result.evidence?.destinations.first)
        XCTAssertEqual(summary.successfulFiles, 2)
        XCTAssertEqual(summary.failedFiles, 0)
        XCTAssertEqual(summary.verifiedBytes, try XCTUnwrap(result.evidence).source.totalBytes)
        XCTAssertEqual(summary.strongFiles, 0)
        XCTAssertEqual(summary.degradedFiles, 2)
    }

    func testDirectorySyncFailureRollsBackPublishedFile() async throws {
        let io = FaultingDurabilityIO()
        io.directorySyncOutcome = .failed(code: EIO, message: "simulated directory sync failure")
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("directory-sync-failure.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationA.appendingPathComponent("source/camera-like-file-1.bin").path
        ))
        XCTAssertTrue(result.evidence?.errors.contains { $0.code == "directory-flush-failed" } == true)
    }

    func testUnsupportedCacheBypassIsExplicitlyDegraded() async throws {
        let io = FaultingDurabilityIO()
        io.cacheBypassOutcome = .unsupported(code: ENOTSUP, message: "simulated unsupported cache bypass")
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("nocache-unsupported.json")
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.evidence?.verificationOutcome, .verifiedDegraded)
        XCTAssertTrue(try detailRecords(from: result).allSatisfy {
            $0.cacheBypass.status == .unsupported && $0.fullDestinationReadbackPerformed
        })
    }

    func testCacheBypassFailureRollsBackNewPublication() async throws {
        let io = FaultingDurabilityIO()
        io.cacheBypassOutcome = .failed(code: EIO, message: "simulated cache bypass failure")
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("nocache-failure.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        XCTAssertTrue(result.evidence?.errors.contains { $0.code == "cache-bypass-failed" } == true)
        XCTAssertTrue(try detailRecords(from: result).contains { $0.publication == .removedAfterFailure })
    }

    func testSourceMutationBetweenCopyAndReadbackIsCaught() async throws {
        let io = FaultingDurabilityIO()
        var mutated = false
        io.sourceVerificationHook = { path in
            guard !mutated else { return }
            mutated = true
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("mutation".utf8))
            try handle.close()
        }
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("source-mutated.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.terminalStatus, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        XCTAssertTrue(result.evidence?.errors.contains { $0.code == "source-mutated" } == true)
        XCTAssertTrue(result.evidence?.destinations.allSatisfy { $0.verificationOutcome == .failed } == true)
    }

    func testPublicationCollisionCannotLookCompleteAndTempIsCleaned() async throws {
        let io = FaultingDurabilityIO()
        var collided = false
        io.publicationHook = { path in
            guard !collided else { return }
            collided = true
            try Data("collision".utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
        let result = await TransferWorkerRuntime(durabilityIO: io).run(
            job: makeJob(destinations: [DestinationRequest(requestID: "a", executionRoot: destinationA.path, role: .backup)]),
            evidenceURL: root.appendingPathComponent("publication-collision.json")
        )

        XCTAssertEqual(result.exitCode, .completedWithFailures)
        XCTAssertEqual(result.evidence?.verificationOutcome, .failed)
        let outputDirectory = destinationA.appendingPathComponent("source")
        let items = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertFalse(items.contains { $0.hasPrefix(".bitmatch.tmp.") })
        XCTAssertTrue(result.evidence?.errors.contains { $0.code == "publication-collision" } == true)
    }

    func testGUIPreferenceCannotDisableWorkerChecksumPolicy() async throws {
        let key = "DisablePipelinedVerify"
        let oldValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldValue { UserDefaults.standard.set(oldValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)

        let result = await TransferWorkerRuntime().run(
            job: makeJob(),
            evidenceURL: root.appendingPathComponent("preference-evidence.json")
        )
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.evidence?.verificationPolicyUsed, "sha256")
        let detailURL = try XCTUnwrap(result.evidence?.detailEvidence).path
        let lines = try String(contentsOfFile: detailURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        for line in lines {
            let record = try TransferWorkerRuntime.makeDecoder().decode(FileEvidenceRecord.self, from: Data(line.utf8))
            XCTAssertEqual(record.checksumAlgorithm, "SHA-256")
            XCTAssertEqual(record.sourceChecksum, record.destinationChecksum)
            XCTAssertEqual(record.verificationOutcome, .verifiedStrong)
            XCTAssertTrue(record.fullDestinationReadbackPerformed)
            XCTAssertEqual(record.cacheBypass.status, .succeeded)
            XCTAssertEqual(record.durabilityFlush.status, .succeeded)
        }
    }

    private func makeJob(
        protocolVersion: Int = TransferWorkerIdentity.protocolVersion,
        attemptID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        destinations: [DestinationRequest]? = nil,
        requestedCapabilities: [CapabilityRequest] = []
    ) -> TransferJobSpec {
        TransferJobSpec(
            protocolVersion: protocolVersion,
            jobID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            attemptID: attemptID,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceRoot: source.path,
            destinations: destinations ?? [
                DestinationRequest(requestID: "destination-a", executionRoot: destinationA.path, role: .working),
                DestinationRequest(requestID: "destination-b", executionRoot: destinationB.path, role: .backup),
            ],
            verificationPolicy: .sha256,
            requestedCapabilities: requestedCapabilities
        )
    }

    private func validateResultSet(_ observations: [WorkerResultObservation]) -> WorkerResultSetValidation {
        WorkerResultSetValidator.validate(
            expectedFiles: [
                WorkerExpectedResultFile(relativePath: "a.mov", size: 10),
                WorkerExpectedResultFile(relativePath: "b.mov", size: 20),
            ],
            destinationRequestIDs: ["destination-a", "destination-b"],
            observations: observations
        )
    }

    private func completeResultObservations() -> [WorkerResultObservation] {
        [
            WorkerResultObservation(relativePath: "a.mov", destinationRequestID: "destination-a", success: true, fileSize: 10),
            WorkerResultObservation(relativePath: "b.mov", destinationRequestID: "destination-a", success: true, fileSize: 20),
            WorkerResultObservation(relativePath: "a.mov", destinationRequestID: "destination-b", success: true, fileSize: 10),
            WorkerResultObservation(relativePath: "b.mov", destinationRequestID: "destination-b", success: true, fileSize: 20),
        ]
    }

    private func assertDestinationHasNoOutput(_ destination: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertTrue(items.isEmpty, "Unexpected destination writes: \(items)")
    }

    private func detailRecords(from result: TransferWorkerRunResult) throws -> [FileEvidenceRecord] {
        let detailURL = try XCTUnwrap(result.evidence?.detailEvidence).path
        return try String(contentsOfFile: detailURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try TransferWorkerRuntime.makeDecoder().decode(FileEvidenceRecord.self, from: Data($0.utf8)) }
    }

    private struct Snapshot: Equatable {
        let relativePath: String
        let bytes: Data?
        let size: UInt64
        let modificationDate: Date?
        let permissions: UInt16
    }

    private func sourceSnapshot() throws -> [Snapshot] {
        let resolver = RelativePathResolver(base: source)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var snapshots: [Snapshot] = []
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: Array(keys), options: []
        ) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            snapshots.append(Snapshot(
                relativePath: try resolver.resolve(url),
                bytes: values.isRegularFile == true ? try Data(contentsOf: url) : nil,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modificationDate: attributes[.modificationDate] as? Date,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            ))
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

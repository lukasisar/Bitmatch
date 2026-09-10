import CryptoKit
import Foundation
import XCTest
@testable import BitMatchTransferCore

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

    func testCapabilitiesAreDeterministicAndDescribeReadOnlySHA256Worker() throws {
        let runtime = TransferWorkerRuntime()
        let first = try TransferWorkerRuntime.makeEncoder().encode(runtime.capabilities())
        let second = try TransferWorkerRuntime.makeEncoder().encode(runtime.capabilities())
        XCTAssertEqual(first, second)
        XCTAssertTrue(runtime.capabilities().sourceReadOnly)
        XCTAssertEqual(runtime.capabilities().supportedProtocolVersions, [1])
        XCTAssertEqual(runtime.capabilities().supportedVerificationPolicies, ["sha256"])
        XCTAssertEqual(runtime.capabilities().upstreamRevision, TransferWorkerIdentity.upstreamRevision)
    }

    func testUnsupportedProtocolAndMandatoryCapabilityFailBeforeDestinationWrites() async throws {
        let unsupportedVersion = makeJob(protocolVersion: 99)
        let versionResult = await TransferWorkerRuntime().run(
            job: unsupportedVersion,
            evidenceURL: root.appendingPathComponent("unsupported-version.json")
        )
        XCTAssertEqual(versionResult.exitCode, .unsupportedProtocolOrCapability)
        XCTAssertEqual(versionResult.evidence?.terminalStatus, .unsupportedProtocolOrCapability)
        try assertDestinationHasNoOutput(destinationA)
        try assertDestinationHasNoOutput(destinationB)

        let unsupportedCapability = makeJob(
            requestedCapabilities: [CapabilityRequest(name: "cold-readback-v2", required: true)]
        )
        let capabilityResult = await TransferWorkerRuntime().run(
            job: unsupportedCapability,
            evidenceURL: root.appendingPathComponent("unsupported-capability.json")
        )
        XCTAssertEqual(capabilityResult.exitCode, .unsupportedProtocolOrCapability)
        try assertDestinationHasNoOutput(destinationA)
        try assertDestinationHasNoOutput(destinationB)
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
        }
    }

    private func makeJob(
        protocolVersion: Int = 1,
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

    private func assertDestinationHasNoOutput(_ destination: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertTrue(items.isEmpty, "Unexpected destination writes: \(items)")
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

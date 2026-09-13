import Foundation
import XCTest
@testable import BitMatchTransferCore

final class TransferWorkerV4Tests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destinationA: URL!
    private var destinationB: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-v4-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destinationA = root.appendingPathComponent("destination-a", isDirectory: true)
        destinationB = root.appendingPathComponent("destination-b", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationB, withIntermediateDirectories: true)

        try write("old-video", to: "DCIM/OLD001.MP4")
        try write("new-video", to: "DCIM/NEW001.MP4")
        try write("sidecar", to: "PRIVATE/M4ROOT/CLIP/NEW001M01.XML")
        try write("support", to: "PRIVATE/M4ROOT/GENERAL/SONY/STATUS.BIN")
        try write("unicode", to: "DCIM/café-東京.MOV")
        try write("upper", to: "DCIM/Case.MOV")
        try write("lower", to: "DCIM/case.MOV")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCapabilitiesAdvertiseV3AndV4WithoutChangingLegacyRuntimeDefault() throws {
        XCTAssertEqual(TransferWorkerIdentity.protocolVersion, 3)
        XCTAssertEqual(TransferWorkerRuntime().capabilities().supportedProtocolVersions, [3])
        let capabilities = TransferWorkerDispatcher().capabilities()
        XCTAssertEqual(capabilities.supportedProtocolVersions, [3, 4])
        XCTAssertTrue(capabilities.capabilities.contains(TransferWorkerDispatcher.exactSubsetCapability))
    }

    func testV4CanonicalizesSelectionAndCopiesExactlySelectedFiles() async throws {
        let requested = [
            "PRIVATE/M4ROOT/CLIP/NEW001M01.XML",
            "DCIM/NEW001.MP4",
            "PRIVATE/M4ROOT/GENERAL/SONY/STATUS.BIN",
        ]
        let result = await TransferWorkerDispatcher().run(
            job: makeJob(version: 4, selected: requested, destinations: [destination("a", destinationA)]),
            evidenceURL: root.appendingPathComponent("exact.json")
        )

        XCTAssertEqual(result.exitCode, .success)
        let expected = TransferRelativePathSelection.canonicalized(requested)
        XCTAssertEqual(result.evidence?.protocolVersion, 4)
        XCTAssertEqual(result.evidence?.includeRelativePaths, expected)
        XCTAssertEqual(result.evidence?.source.fileCount, expected.count)
        XCTAssertEqual(Set(try detailPaths(result)), Set(expected))

        let outputNames = Set(try recursiveRelativePaths(in: destinationA))
        XCTAssertFalse(outputNames.contains { $0.hasSuffix("OLD001.MP4") })
        XCTAssertTrue(outputNames.contains { $0.hasSuffix("NEW001.MP4") })
        XCTAssertTrue(outputNames.contains { $0.hasSuffix("NEW001M01.XML") })
        XCTAssertTrue(outputNames.contains { $0.hasSuffix("STATUS.BIN") })
    }

    func testV4PreservesUnicodeAndCaseSensitiveNamesWithoutFolding() async throws {
        // Case.MOV/case.MOV are only genuinely distinct files if this run's temp directory
        // sits on a case-sensitive volume (not the default for a Mac boot/temp volume, this
        // one included). On a case-insensitive volume the second setUp write silently
        // overwrote the first, so both paths now name the same physical file with "lower"'s
        // content: selecting both together is then a real case-insensitive collision within
        // this job's own selected set, which the safety validator correctly refuses -- not a
        // folding bug. Only assert the case-distinct pair where the fixture actually made two
        // distinct files; Unicode preservation is unconditional.
        let caseAContent = try? Data(contentsOf: source.appendingPathComponent("DCIM/Case.MOV"))
        let caseBContent = try? Data(contentsOf: source.appendingPathComponent("DCIM/case.MOV"))
        let caseVariantsAreDistinctOnDisk = caseAContent != nil && caseAContent != caseBContent

        let selected = caseVariantsAreDistinctOnDisk
            ? ["DCIM/café-東京.MOV", "DCIM/Case.MOV", "DCIM/case.MOV"]
            : ["DCIM/café-東京.MOV"]
        let result = await TransferWorkerDispatcher().run(
            job: makeJob(version: 4, selected: selected, destinations: [destination("a", destinationA)]),
            evidenceURL: root.appendingPathComponent("unicode.json")
        )
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(Set(try detailPaths(result)), Set(selected))
    }

    func testV4RejectsEmptyDuplicateAbsoluteTraversalAndBackslashSelectionsBeforeWrites() async throws {
        let invalidSelections: [[String]] = [
            [],
            ["DCIM/NEW001.MP4", "DCIM/NEW001.MP4"],
            ["/DCIM/NEW001.MP4"],
            ["DCIM/../NEW001.MP4"],
            ["DCIM\\NEW001.MP4"],
        ]
        for (index, selection) in invalidSelections.enumerated() {
            let result = await TransferWorkerDispatcher().run(
                job: makeJob(version: 4, selected: selection, destinations: [destination("a", destinationA)]),
                evidenceURL: root.appendingPathComponent("invalid-\(index).json")
            )
            XCTAssertEqual(result.exitCode, .invalidJob)
            XCTAssertTrue(try recursiveRelativePaths(in: destinationA).isEmpty)
        }
    }

    func testV4SelectionUnaffectedByUnrelatedCaseCollisionElsewhereInSourceTree() async throws {
        // setUpWithError's fixture always contains an unrelated Case.MOV/case.MOV pair. A V4
        // selection that never references either of them must not be blocked by that: only
        // collisions among the files actually being read and written are this operation's
        // concern, not the rest of a large, possibly messy real source root.
        let result = await TransferWorkerDispatcher().run(
            job: makeJob(version: 4, selected: ["DCIM/NEW001.MP4"], destinations: [destination("a", destinationA)]),
            evidenceURL: root.appendingPathComponent("unrelated-collision.json")
        )
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(Set(try detailPaths(result)), ["DCIM/NEW001.MP4"])
    }

    func testV4DoesNotMaterializeEmptyDirectoriesForUnselectedPartsOfSourceTree() async throws {
        // setUpWithError's fixture always contains PRIVATE/M4ROOT/... paths that this
        // selection never references. Materializing an empty PRIVATE/ (or PRIVATE/M4ROOT/)
        // directory at the destination for an operation that never selected anything under
        // it defeats the point of an exact subset, and would surprise anyone diffing the
        // destination tree against the selected set. Two destinations so this exercises the
        // fan-out directory-preparation path (FileCopyService.prepareFanOutDirectoryTree),
        // not just the single/preEnumerated-destination path (createDirectoryTreeSafely) --
        // they are separate implementations and each needed this fix independently.
        let result = await TransferWorkerDispatcher().run(
            job: makeJob(
                version: 4,
                selected: ["DCIM/NEW001.MP4"],
                destinations: [destination("a", destinationA), destination("b", destinationB)]
            ),
            evidenceURL: root.appendingPathComponent("no-empty-dirs.json")
        )
        XCTAssertEqual(result.exitCode, .success)
        for destinationURL in [destinationA!, destinationB!] {
            let destinationEntries = try recursiveRelativePaths(in: destinationURL)
            XCTAssertFalse(destinationEntries.contains { $0.hasPrefix("PRIVATE") })
        }
    }

    func testV4MissingRequestedFileFailsClosedAndDoesNotPublishExcludedOldMedia() async throws {
        let result = await TransferWorkerDispatcher().run(
            job: makeJob(version: 4, selected: ["DCIM/MISSING.MP4"], destinations: [destination("a", destinationA)]),
            evidenceURL: root.appendingPathComponent("missing.json")
        )
        XCTAssertNotEqual(result.exitCode, .success)
        XCTAssertFalse(try recursiveRelativePaths(in: destinationA).contains { $0.hasSuffix("OLD001.MP4") })
    }

    func testV4TwoDestinationFanOutUsesTheSameExactSet() async throws {
        let selected = ["DCIM/NEW001.MP4", "PRIVATE/M4ROOT/CLIP/NEW001M01.XML"]
        let result = await TransferWorkerDispatcher().run(
            job: makeJob(
                version: 4,
                selected: selected,
                destinations: [destination("a", destinationA), destination("b", destinationB)]
            ),
            evidenceURL: root.appendingPathComponent("fanout.json")
        )
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try detailPaths(result).count, selected.count * 2)
        XCTAssertFalse(try recursiveRelativePaths(in: destinationA).contains { $0.hasSuffix("OLD001.MP4") })
        XCTAssertFalse(try recursiveRelativePaths(in: destinationB).contains { $0.hasSuffix("OLD001.MP4") })
    }

    func testV3WithoutAllowlistStillCopiesWholeSourceAndV3WithAllowlistFailsClosed() async throws {
        let dispatcher = TransferWorkerDispatcher()
        // The fixture writes Case.MOV and case.MOV as distinct paths, but on a
        // case-insensitive volume (the default for a Mac boot/temp volume) the second
        // write collapses onto the first, leaving one fewer file than written. Derive the
        // expectation from what setUp actually produced on this volume rather than
        // hardcoding a count that assumes case-sensitivity.
        let expectedSourceFileCount = try recursiveRegularFilePaths(in: source).count
        let v3 = await dispatcher.run(
            job: makeJob(version: 3, selected: nil, destinations: [destination("a", destinationA)]),
            evidenceURL: root.appendingPathComponent("v3.json")
        )
        XCTAssertEqual(v3.exitCode, .success)
        XCTAssertNil(v3.evidence?.includeRelativePaths)
        XCTAssertEqual(v3.evidence?.source.fileCount, expectedSourceFileCount)
        XCTAssertEqual(Set(try detailPaths(v3)).count, expectedSourceFileCount)

        let destinationC = root.appendingPathComponent("destination-c", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationC, withIntermediateDirectories: true)
        let invalidV3 = await dispatcher.run(
            job: makeJob(version: 3, selected: ["DCIM/NEW001.MP4"], destinations: [destination("c", destinationC)]),
            evidenceURL: root.appendingPathComponent("v3-invalid.json")
        )
        XCTAssertEqual(invalidV3.exitCode, .invalidJob)
        XCTAssertTrue(try recursiveRelativePaths(in: destinationC).isEmpty)
    }

    private func makeJob(
        version: Int,
        selected: [String]?,
        destinations: [DestinationRequest]
    ) -> TransferJobSpec {
        TransferJobSpec(
            protocolVersion: version,
            jobID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            attemptID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceRoot: source.path,
            destinations: destinations,
            verificationPolicy: .sha256,
            requestedCapabilities: version == 4
                ? [CapabilityRequest(name: TransferWorkerDispatcher.exactSubsetCapability, required: true)]
                : [],
            includeRelativePaths: selected
        )
    }

    private func destination(_ id: String, _ url: URL) -> DestinationRequest {
        DestinationRequest(requestID: id, executionRoot: url.path, role: .backup)
    }

    private func write(_ value: String, to relativePath: String) throws {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    private func detailPaths(_ result: TransferWorkerRunResult) throws -> [String] {
        let path = try XCTUnwrap(result.evidence?.detailEvidence?.path)
        return try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let record = try TransferWorkerRuntime.makeDecoder().decode(FileEvidenceRecord.self, from: Data(line.utf8))
                return record.relativePath
            }
    }

    private func recursiveRelativePaths(in base: URL) throws -> [String] {
        let resolver = RelativePathResolver(base: base)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return try resolver.resolve(url)
        }
    }

    private func recursiveRegularFilePaths(in base: URL) throws -> [String] {
        let resolver = RelativePathResolver(base: base)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let isRegularFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile ?? false
            guard isRegularFile else { return nil }
            return try resolver.resolve(url)
        }
    }
}

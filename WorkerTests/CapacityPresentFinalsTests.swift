import Darwin
import Foundation
import XCTest
@testable import BitMatchTransferCore

/// Post Prep #142: a destination that already holds finals from an interrupted or
/// abandoned earlier copy needs space only for the files still to write. The copy
/// never writes over an existing final: it reuses a same-size file after a full
/// checksum match, or refuses it as a conflict.
final class CapacityPresentFinalsTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private let settings = CameraLabelSettings(destinationPathComponents: ["CARD"])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-capacity-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("CARD", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("tiny".utf8).write(to: source.appendingPathComponent("tiny.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOnlyFinalsMissingOrDifferentInSizeCountTowardSpace() throws {
        let finalRoot = destination.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(
            at: finalRoot.appendingPathComponent("DCIM", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Same size: reused or refused, never written again.
        try Data(count: 100).write(to: finalRoot.appendingPathComponent("DCIM/PRESENT.MP4"))
        // Different size: still counts.
        try Data(count: 7).write(to: finalRoot.appendingPathComponent("DCIM/SHORT.MP4"))
        // A symbolic link is never a reusable final.
        try Data(count: 400).write(to: root.appendingPathComponent("elsewhere.bin"))
        try FileManager.default.createSymbolicLink(
            at: finalRoot.appendingPathComponent("DCIM/LINK.MP4"),
            withDestinationURL: root.appendingPathComponent("elsewhere.bin")
        )

        let manifest = [
            entry("DCIM/PRESENT.MP4", size: 100),
            entry("DCIM/SHORT.MP4", size: 200),
            entry("DCIM/MISSING.MP4", size: 300),
            entry("DCIM/LINK.MP4", size: 400),
        ]
        let pending = try SafetyValidator.bytesStillToWrite(
            manifest: manifest,
            source: source,
            destinations: [destination],
            settings: settings
        )
        XCTAssertEqual(pending, [200 + 300 + 400])
    }

    /// A sparse file stands in for a final larger than any real free space.
    func testPresentFinalNoLongerCountsAgainstFreeSpace() async throws {
        let hugeSize: Int64 = 1_000_000_000_000_000 // 1 PB: more than any test Mac has free
        let manifest = [entry("DCIM/HUGE.MP4", size: hugeSize)]

        let missing = try SafetyValidator.bytesStillToWrite(
            manifest: manifest,
            source: source,
            destinations: [destination],
            settings: settings
        )
        do {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [destination],
                sourceSizeBytes: hugeSize,
                bytesToWrite: missing
            )
            XCTFail("A 1 PB final that is not on the destination yet cannot fit")
        } catch FileOperationError.insufficientSpace {
            // Expected.
        }

        let final = destination.appendingPathComponent("CARD/DCIM/HUGE.MP4")
        try FileManager.default.createDirectory(
            at: final.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: final.path, contents: nil))
        let handle = try FileHandle(forWritingTo: final)
        try handle.truncate(atOffset: UInt64(hugeSize))
        try handle.close()

        let present = try SafetyValidator.bytesStillToWrite(
            manifest: manifest,
            source: source,
            destinations: [destination],
            settings: settings
        )
        XCTAssertEqual(present, [0])
        try await SafetyValidator.performSafetyChecks(
            source: source,
            destinations: [destination],
            sourceSizeBytes: hugeSize,
            bytesToWrite: present
        )
    }

    func testCapacityPlanMustMatchTheDestinations() async throws {
        do {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [destination],
                sourceSizeBytes: 0,
                bytesToWrite: [0, 0]
            )
            XCTFail("A capacity plan for other destinations must be refused")
        } catch FileOperationError.unsafeOperation {
            // Expected.
        }
    }

    private func entry(_ relativePath: String, size: Int64) -> FileEntry {
        FileEntry(
            url: source.appendingPathComponent(relativePath),
            relativePath: relativePath,
            size: size
        )
    }
}

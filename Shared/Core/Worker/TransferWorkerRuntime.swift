import CryptoKit
import Foundation

#if os(macOS)
import Darwin

private final class HeadlessFileSystemService: FileSystemService {
    func selectSourceFolder() async -> URL? { nil }
    func selectDestinationFolders() async -> [URL] { [] }
    func selectLeftFolder() async -> URL? { nil }
    func selectRightFolder() async -> URL? { nil }
    func validateFileAccess(url: URL) async -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func startAccessing(url: URL) -> Bool { true }
    func stopAccessing(url: URL) {}
    func getFileList(from folderURL: URL) async throws -> [URL] {
        try FileTreeEnumerator.enumerateRegularFiles(base: folderURL).map(\.url)
    }
    nonisolated func getFileSize(for url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    nonisolated func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    nonisolated func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

private enum WorkerValidationError: LocalizedError {
    case invalid(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unsupported(let message): return message
        }
    }
}

private actor DetailEvidenceWriter {
    private let finalURL: URL
    private let temporaryURL: URL
    private var handle: FileHandle?
    private var count = 0
    private var failureMessage: String?
    private let encoder: JSONEncoder

    init(finalURL: URL, encoder: JSONEncoder) throws {
        self.finalURL = finalURL
        self.temporaryURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).partial-\(UUID().uuidString)")
        self.encoder = encoder
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: temporaryURL)
    }

    func append(_ record: FileEvidenceRecord) -> Bool {
        guard failureMessage == nil, let handle else { return false }
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            count += 1
            return true
        } catch {
            failureMessage = error.localizedDescription
            return false
        }
    }

    func recordedFailure() -> String? {
        failureMessage
    }

    func publish() throws -> DetailEvidenceReference {
        if let failureMessage {
            throw NSError(
                domain: "BitMatchTransferWorker.Evidence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failureMessage]
            )
        }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.close()
        self.handle = nil
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        let data = try Data(contentsOf: finalURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return DetailEvidenceReference(path: finalURL.path, format: "application/x-ndjson", recordCount: count, sha256: digest)
    }

}

private final class WorkerDurabilityFactsCollector: TransferDurabilityRecorder, @unchecked Sendable {
    struct Snapshot {
        var copy: TransferCopyDurabilityFacts?
        var readback: TransferReadbackFacts?
    }

    private let lock = NSLock()
    private var facts: [String: Snapshot] = [:]

    func recordCopyFacts(_ copyFacts: TransferCopyDurabilityFacts, destinationPath: String) {
        lock.lock()
        facts[destinationPath, default: Snapshot()].copy = copyFacts
        lock.unlock()
    }

    func recordReadbackFacts(_ readbackFacts: TransferReadbackFacts, destinationPath: String) {
        lock.lock()
        facts[destinationPath, default: Snapshot()].readback = readbackFacts
        lock.unlock()
    }

    func copyFacts(destinationPath: String) -> TransferCopyDurabilityFacts? {
        lock.lock()
        defer { lock.unlock() }
        return facts[destinationPath]?.copy
    }

    func snapshot(destinationPath: String) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return facts[destinationPath] ?? Snapshot()
    }
}

private struct SourceAttemptFileSnapshot: Equatable {
    let relativePath: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
}

public struct TransferWorkerRuntime {
    public static let supportedCapabilities = [
        "atomic-no-overwrite",
        "bounded-detail-evidence",
        "darwin-full-fsync-facts",
        "directory-publication-flush",
        "full-destination-readback",
        "os-cache-bypass-request",
        "sha256-verification",
        "source-read-only",
    ]

    private let durabilityIO: any TransferDurabilityIO

    public init() {
        self.durabilityIO = DarwinTransferDurabilityIO()
    }

    init(durabilityIO: any TransferDurabilityIO) {
        self.durabilityIO = durabilityIO
    }

    public func capabilities() -> TransferWorkerCapabilities {
        TransferWorkerCapabilities(
            workerVersion: TransferWorkerIdentity.semanticVersion,
            workerBuild: TransferWorkerIdentity.build,
            upstreamRepository: TransferWorkerIdentity.upstreamRepository,
            upstreamRevision: TransferWorkerIdentity.upstreamRevision,
            supportedProtocolVersions: [TransferWorkerIdentity.protocolVersion],
            supportedVerificationPolicies: ["sha256"],
            supportedVerificationAlgorithms: ["SHA-256"],
            maximumDestinations: 16,
            pauseResume: false,
            sourceReadOnly: true,
            capabilities: Self.supportedCapabilities
        )
    }

    public func run(job: TransferJobSpec, evidenceURL: URL) async -> TransferWorkerRunResult {
        let startedAt = Date()
        let sourceURL = URL(fileURLWithPath: job.sourceRoot, isDirectory: true).standardizedFileURL
        let detailsURL = URL(fileURLWithPath: evidenceURL.path + ".details.jsonl")
        var sourceSummary = SourceEvidenceSummary(
            executionRoot: sourceURL.path,
            fileCount: 0,
            totalBytes: 0,
            stabilityVerifiedFiles: 0,
            stabilityFailedFiles: 0
        )
        var summaries = emptyDestinationSummaries(for: job)

        do {
            try validateArtifactTargets(evidenceURL: evidenceURL, detailsURL: detailsURL, sourceURL: sourceURL)
        } catch {
            // The requested output path itself is unsafe or unavailable. Do
            // not try to explain the rejection by writing to that same path.
            return TransferWorkerRunResult(
                exitCode: .invalidJob,
                evidence: nil,
                diagnostic: error.localizedDescription
            )
        }

        do {
            try validate(job: job, sourceURL: sourceURL)
            let manifest = try FileTreeEnumerator.enumerateRegularFiles(base: sourceURL)
            let sourceAttemptSnapshot = try captureSourceAttemptSnapshot(manifest)
            let totalBytes = try manifest.reduce(Int64(0)) { partial, entry in
                let (sum, overflow) = partial.addingReportingOverflow(entry.size)
                guard !overflow else { throw WorkerValidationError.invalid("Source size exceeds the supported range") }
                return sum
            }
            sourceSummary = SourceEvidenceSummary(
                executionRoot: sourceURL.path,
                fileCount: manifest.count,
                totalBytes: totalBytes,
                stabilityVerifiedFiles: 0,
                stabilityFailedFiles: 0
            )

            let destinationURLs = job.destinations.map { URL(fileURLWithPath: $0.executionRoot, isDirectory: true).standardizedFileURL }
            let settings = CameraLabelSettings(destinationPathComponents: [sourceURL.lastPathComponent])
            do {
                try SafetyValidator.validateResolvedDestinationRoots(
                    source: sourceURL,
                    destinations: destinationURLs,
                    settings: settings
                )
                try await SafetyValidator.performSafetyChecks(
                    source: sourceURL,
                    destinations: destinationURLs,
                    sourceSizeBytes: totalBytes
                )
            } catch {
                throw WorkerValidationError.invalid(error.localizedDescription)
            }

            let encoder = Self.makeDetailEncoder()
            let writer = try DetailEvidenceWriter(finalURL: detailsURL, encoder: encoder)
            let durabilityFacts = WorkerDurabilityFactsCollector()
            let service = SharedFileOperationsService(
                fileSystem: HeadlessFileSystemService(),
                checksum: SharedChecksumService.shared,
                pipelineVerification: true,
                durabilityIO: durabilityIO,
                durabilityRecorder: durabilityFacts
            )

            do {
                let operation = try await service.performFileOperation(
                    sourceURL: sourceURL,
                    destinationURLs: destinationURLs,
                    verificationMode: .standard,
                    settings: settings,
                    estimatedTotalBytes: totalBytes,
                    progressCallback: { _ in },
                    onFileResult: { result in
                        // The shared service reports a successful copy and
                        // then upserts it with the terminal verification.
                        // Evidence records terminal outcomes, not progress.
                        guard !result.success || result.verificationResult != nil else { return }
                        let record = makeFileEvidence(
                            result: result,
                            sourceURL: sourceURL,
                            destinations: job.destinations,
                            facts: durabilityFacts.snapshot(destinationPath: result.destinationURL.path)
                        )
                        let recorded = await writer.append(record)
                        if !recorded {
                            service.cancelOperation()
                        }
                    }
                )
                if let callbackFailure = await writer.recordedFailure() {
                    throw NSError(
                        domain: "BitMatchTransferWorker.Evidence",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: callbackFailure]
                    )
                }
                let sourceStableAcrossAttempt = sourceManifestRemainedStable(
                    sourceAttemptSnapshot,
                    sourceURL: sourceURL
                )
                summaries = makeDestinationSummaries(
                    operation: operation,
                    job: job,
                    sourceURL: sourceURL,
                    facts: durabilityFacts,
                    sourceStableAcrossAttempt: sourceStableAcrossAttempt
                )
                sourceSummary = makeSourceSummary(
                    sourceSummary,
                    operation: operation,
                    facts: durabilityFacts,
                    sourceStableAcrossAttempt: sourceStableAcrossAttempt
                )
                var errors = makeErrors(operation: operation, job: job, sourceURL: sourceURL)
                if !sourceStableAcrossAttempt {
                    errors.append(WorkerTypedError(code: "source-mutated", message: "Source manifest changed during the transfer attempt"))
                }
                let detailReference = try await writer.publish()
                let outcome = sourceStableAcrossAttempt
                    ? aggregateOutcome(operation: operation, facts: durabilityFacts)
                    : .failed
                if outcome == .failed && errors.isEmpty {
                    errors.append(WorkerTypedError(
                        code: "verification-facts-incomplete",
                        message: "Required verification or durability facts were incomplete"
                    ))
                }
                let status: TransferTerminalStatus = outcome == .failed ? .completedWithFailures : .succeeded
                let evidence = makeEvidence(
                    job: job,
                    startedAt: startedAt,
                    status: status,
                    source: sourceSummary,
                    destinations: summaries,
                    verificationPolicyUsed: "sha256",
                    detailReference: detailReference,
                    errors: errors,
                    verificationOutcome: outcome,
                    warnings: makeDegradationWarnings(operation: operation, facts: durabilityFacts)
                )
                try Self.writeEvidenceAtomically(evidence, to: evidenceURL)
                return TransferWorkerRunResult(
                    exitCode: outcome == .failed ? .completedWithFailures : .success,
                    evidence: evidence,
                    diagnostic: nil
                )
            } catch is CancellationError {
                let detailReference = try? await writer.publish()
                let error = WorkerTypedError(code: "interrupted", message: "Transfer was interrupted or cancelled")
                let evidence = makeEvidence(
                    job: job,
                    startedAt: startedAt,
                    status: .interrupted,
                    source: sourceSummary,
                    destinations: summaries,
                    verificationPolicyUsed: "sha256",
                    detailReference: detailReference,
                    errors: [error]
                )
                try Self.writeEvidenceAtomically(evidence, to: evidenceURL)
                return TransferWorkerRunResult(exitCode: .interrupted, evidence: evidence, diagnostic: error.message)
            } catch {
                let detailReference = try? await writer.publish()
                let statusAndExit = classifyExecutionError(error)
                let typedError = WorkerTypedError(code: statusAndExit.code, message: error.localizedDescription)
                let evidence = makeEvidence(
                    job: job,
                    startedAt: startedAt,
                    status: statusAndExit.status,
                    source: sourceSummary,
                    destinations: summaries,
                    verificationPolicyUsed: "sha256",
                    detailReference: detailReference,
                    errors: [typedError]
                )
                try Self.writeEvidenceAtomically(evidence, to: evidenceURL)
                return TransferWorkerRunResult(exitCode: statusAndExit.exit, evidence: evidence, diagnostic: typedError.message)
            }
        } catch WorkerValidationError.unsupported(let message) {
            return writePreflightEvidence(
                job: job, evidenceURL: evidenceURL, startedAt: startedAt,
                status: .unsupportedProtocolOrCapability, exitCode: .unsupportedProtocolOrCapability,
                code: "unsupported", message: message, source: sourceSummary, destinations: summaries
            )
        } catch WorkerValidationError.invalid(let message) {
            return writePreflightEvidence(
                job: job, evidenceURL: evidenceURL, startedAt: startedAt,
                status: .invalidJob, exitCode: .invalidJob,
                code: "invalid-job", message: message, source: sourceSummary, destinations: summaries
            )
        } catch {
            return TransferWorkerRunResult(exitCode: .internalFailure, evidence: nil, diagnostic: error.localizedDescription)
        }
    }

    private func validate(job: TransferJobSpec, sourceURL: URL) throws {
        guard job.protocolVersion == TransferWorkerIdentity.protocolVersion else {
            throw WorkerValidationError.unsupported("Unsupported protocol version \(job.protocolVersion)")
        }
        if case .unsupported(let value) = job.verificationPolicy {
            throw WorkerValidationError.unsupported("Unsupported verification policy \(value)")
        }
        let unsupportedMandatory = job.requestedCapabilities.filter {
            $0.required && !Self.supportedCapabilities.contains($0.name)
        }
        guard unsupportedMandatory.isEmpty else {
            throw WorkerValidationError.unsupported(
                "Unsupported mandatory capability \(unsupportedMandatory[0].name)"
            )
        }
        guard !job.sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerValidationError.invalid("Source root must not be empty")
        }
        guard job.sourceRoot.hasPrefix("/") else {
            throw WorkerValidationError.invalid("Source root must be absolute")
        }
        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
            throw WorkerValidationError.invalid("Source root must be an existing directory")
        }
        guard !job.destinations.isEmpty else {
            throw WorkerValidationError.invalid("At least one destination is required")
        }
        guard job.destinations.count <= capabilities().maximumDestinations else {
            throw WorkerValidationError.unsupported("Destination count exceeds worker capability")
        }
        let requestIDs = job.destinations.map(\.requestID)
        guard requestIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(requestIDs).count == requestIDs.count else {
            throw WorkerValidationError.invalid("Destination request IDs must be non-empty and unique")
        }

        let destinationURLs = job.destinations.map { URL(fileURLWithPath: $0.executionRoot, isDirectory: true).standardizedFileURL }
        guard job.destinations.allSatisfy({ $0.executionRoot.hasPrefix("/") }) else {
            throw WorkerValidationError.invalid("Destination roots must be absolute")
        }
        for (index, destination) in destinationURLs.enumerated() {
            guard !job.destinations[index].executionRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkerValidationError.invalid("Destination root must not be empty")
            }
            if let issue = SafetyValidator.destinationSafetyIssue(source: sourceURL, destination: destination) {
                throw WorkerValidationError.invalid(issue)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WorkerValidationError.invalid("Destination root must be an existing directory: \(destination.path)")
            }
        }
        let canonical = destinationURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents }
        for left in canonical.indices {
            for right in canonical.indices where left < right {
                if Self.contains(canonical[left], canonical[right]) || Self.contains(canonical[right], canonical[left]) {
                    throw WorkerValidationError.invalid("Destination roots must be unique and non-nested")
                }
            }
        }
    }

    private func validateArtifactTargets(evidenceURL: URL, detailsURL: URL, sourceURL: URL) throws {
        guard evidenceURL.path.hasPrefix("/"), detailsURL.path.hasPrefix("/") else {
            throw WorkerValidationError.invalid("Evidence path must be absolute")
        }
        guard !FileManager.default.fileExists(atPath: evidenceURL.path),
              !FileManager.default.fileExists(atPath: detailsURL.path) else {
            throw WorkerValidationError.invalid("Evidence artifacts already exist; refusing to overwrite them")
        }
        var parentIsDirectory: ObjCBool = false
        let parent = evidenceURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw WorkerValidationError.invalid("Evidence parent must be an existing directory")
        }
        let sourceComponents = sourceURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let evidenceComponents = evidenceURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !Self.contains(sourceComponents, evidenceComponents) else {
            throw WorkerValidationError.invalid("Evidence must not be written inside the source tree")
        }
    }

    private static func contains(_ root: [String], _ candidate: [String]) -> Bool {
        guard candidate.count >= root.count else { return false }
        return zip(root, candidate).allSatisfy(==)
    }

    private func writePreflightEvidence(
        job: TransferJobSpec,
        evidenceURL: URL,
        startedAt: Date,
        status: TransferTerminalStatus,
        exitCode: TransferWorkerExitCode,
        code: String,
        message: String,
        source: SourceEvidenceSummary,
        destinations: [DestinationEvidenceSummary]
    ) -> TransferWorkerRunResult {
        let error = WorkerTypedError(code: code, message: message)
        let evidence = makeEvidence(
            job: job,
            startedAt: startedAt,
            status: status,
            source: source,
            destinations: destinations,
            verificationPolicyUsed: nil,
            detailReference: nil,
            errors: [error]
        )
        do {
            try Self.writeEvidenceAtomically(evidence, to: evidenceURL)
            return TransferWorkerRunResult(exitCode: exitCode, evidence: evidence, diagnostic: message)
        } catch {
            return TransferWorkerRunResult(exitCode: exitCode, evidence: nil, diagnostic: "\(message); evidence unavailable: \(error.localizedDescription)")
        }
    }

    private func makeEvidence(
        job: TransferJobSpec,
        startedAt: Date,
        status: TransferTerminalStatus,
        source: SourceEvidenceSummary,
        destinations: [DestinationEvidenceSummary],
        verificationPolicyUsed: String?,
        detailReference: DetailEvidenceReference?,
        errors: [WorkerTypedError],
        verificationOutcome: WorkerVerificationOutcome = .failed,
        warnings: [String] = []
    ) -> TransferEvidence {
        TransferEvidence(
            protocolVersion: TransferWorkerIdentity.protocolVersion,
            jobID: job.jobID,
            attemptID: job.attemptID,
            workerVersion: TransferWorkerIdentity.semanticVersion,
            workerBuild: TransferWorkerIdentity.build,
            upstreamRepository: TransferWorkerIdentity.upstreamRepository,
            upstreamRevision: TransferWorkerIdentity.upstreamRevision,
            startedAt: startedAt,
            endedAt: Date(),
            terminalStatus: status,
            verificationOutcome: verificationOutcome,
            source: source,
            destinations: destinations,
            verificationPolicyUsed: verificationPolicyUsed,
            detailEvidence: detailReference,
            warnings: warnings,
            errors: errors,
            capabilitiesUsed: verificationPolicyUsed == nil ? [] : Self.supportedCapabilities
        )
    }

    private func emptyDestinationSummaries(for job: TransferJobSpec) -> [DestinationEvidenceSummary] {
        job.destinations.map {
            DestinationEvidenceSummary(
                requestID: $0.requestID,
                executionRoot: $0.executionRoot,
                role: $0.role,
                successfulFiles: 0,
                failedFiles: 0,
                verifiedBytes: 0,
                verificationOutcome: .failed,
                strongFiles: 0,
                degradedFiles: 0
            )
        }
    }

    private func makeDestinationSummaries(
        operation: FileOperation,
        job: TransferJobSpec,
        sourceURL: URL,
        facts: WorkerDurabilityFactsCollector,
        sourceStableAcrossAttempt: Bool
    ) -> [DestinationEvidenceSummary] {
        job.destinations.map { destination in
            let matching = operation.results.filter {
                destinationRequestID(for: $0.destinationURL, destinations: job.destinations) == destination.requestID
            }
            let outcomes = matching.map { result in
                sourceStableAcrossAttempt
                    ? fileOutcome(result: result, facts: facts.snapshot(destinationPath: result.destinationURL.path))
                    : .failed
            }
            return DestinationEvidenceSummary(
                requestID: destination.requestID,
                executionRoot: destination.executionRoot,
                role: destination.role,
                successfulFiles: matching.filter(\.success).count,
                failedFiles: matching.filter { !$0.success }.count,
                verifiedBytes: matching.filter(\.success).reduce(0) { $0 + $1.fileSize },
                verificationOutcome: aggregate(outcomes),
                strongFiles: outcomes.filter { $0 == .verifiedStrong }.count,
                degradedFiles: outcomes.filter { $0 == .verifiedDegraded }.count
            )
        }
    }

    private func makeSourceSummary(
        _ base: SourceEvidenceSummary,
        operation: FileOperation,
        facts: WorkerDurabilityFactsCollector,
        sourceStableAcrossAttempt: Bool
    ) -> SourceEvidenceSummary {
        guard sourceStableAcrossAttempt else {
            return SourceEvidenceSummary(
                executionRoot: base.executionRoot,
                fileCount: base.fileCount,
                totalBytes: base.totalBytes,
                stabilityVerifiedFiles: 0,
                stabilityFailedFiles: base.fileCount
            )
        }
        let grouped = Dictionary(grouping: operation.results, by: { $0.sourceURL.path })
        let stable = grouped.values.filter { results in
            !results.isEmpty && results.allSatisfy { result in
                let snapshot = facts.snapshot(destinationPath: result.destinationURL.path)
                return snapshot.copy?.sourceRemainedStable == true
                    && snapshot.readback?.sourceRemainedStable == true
            }
        }.count
        return SourceEvidenceSummary(
            executionRoot: base.executionRoot,
            fileCount: base.fileCount,
            totalBytes: base.totalBytes,
            stabilityVerifiedFiles: stable,
            stabilityFailedFiles: max(0, base.fileCount - stable)
        )
    }

    private func captureSourceAttemptSnapshot(_ manifest: [FileEntry]) throws -> [SourceAttemptFileSnapshot] {
        try manifest.map { entry in
            var info = stat()
            let result = entry.url.path.withCString { lstat($0, &info) }
            guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw WorkerValidationError.invalid("Unable to capture stable identity for source file \(entry.relativePath)")
            }
            return SourceAttemptFileSnapshot(
                relativePath: entry.relativePath,
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                modificationSeconds: info.st_mtimespec.tv_sec,
                modificationNanoseconds: info.st_mtimespec.tv_nsec
            )
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private func sourceManifestRemainedStable(
        _ initial: [SourceAttemptFileSnapshot],
        sourceURL: URL
    ) -> Bool {
        guard let finalManifest = try? FileTreeEnumerator.enumerateRegularFiles(base: sourceURL),
              let final = try? captureSourceAttemptSnapshot(finalManifest) else { return false }
        return initial == final
    }

    private func aggregateOutcome(
        operation: FileOperation,
        facts: WorkerDurabilityFactsCollector
    ) -> WorkerVerificationOutcome {
        aggregate(operation.results.map {
            fileOutcome(result: $0, facts: facts.snapshot(destinationPath: $0.destinationURL.path))
        })
    }

    private func aggregate(_ outcomes: [WorkerVerificationOutcome]) -> WorkerVerificationOutcome {
        guard !outcomes.isEmpty else { return .failed }
        if outcomes.contains(.failed) { return .failed }
        if outcomes.contains(.verifiedDegraded) { return .verifiedDegraded }
        return .verifiedStrong
    }

    private func fileOutcome(
        result: FileOperationResult,
        facts: WorkerDurabilityFactsCollector.Snapshot
    ) -> WorkerVerificationOutcome {
        guard result.success,
              result.verificationResult?.matches == true,
              let copy = facts.copy,
              let readback = facts.readback,
              copy.sourceRemainedStable,
              readback.sourceRemainedStable,
              readback.fullReadPerformed else {
            return .failed
        }

        if copy.reusedExistingDestination {
            return operationSucceeded(readback.cacheBypass) ? .verifiedDegraded : operationDegraded(readback.cacheBypass) ? .verifiedDegraded : .failed
        }

        guard copy.ordinaryFlushSucceeded,
              copy.prePublicationChecksumMatched,
              copy.publicationSucceeded else { return .failed }
        let required = [copy.fullSync, copy.directorySync, readback.cacheBypass]
        if required.allSatisfy(operationSucceeded) { return .verifiedStrong }
        if required.allSatisfy({ operationSucceeded($0) || operationDegraded($0) }) {
            return .verifiedDegraded
        }
        return .failed
    }

    private func operationSucceeded(_ outcome: TransferSystemCallOutcome?) -> Bool {
        if case .succeeded? = outcome { return true }
        return false
    }

    private func operationDegraded(_ outcome: TransferSystemCallOutcome?) -> Bool {
        if case .unsupported? = outcome { return true }
        return false
    }

    private func makeDegradationWarnings(
        operation: FileOperation,
        facts: WorkerDurabilityFactsCollector
    ) -> [String] {
        var warnings = Set<String>()
        for result in operation.results where result.success {
            let snapshot = facts.snapshot(destinationPath: result.destinationURL.path)
            if snapshot.copy?.reusedExistingDestination == true {
                warnings.insert("A matching pre-existing destination was reused; this attempt cannot attest its original durability flush or publication.")
            }
            if operationDegraded(snapshot.copy?.fullSync) {
                warnings.insert("F_FULLFSYNC was unsupported; ordinary fsync is recorded but is not treated as equivalent strong durability.")
            }
            if operationDegraded(snapshot.copy?.directorySync) {
                warnings.insert("Destination directory metadata fsync was unsupported; publication durability is degraded.")
            }
            if operationDegraded(snapshot.readback?.cacheBypass) {
                warnings.insert("F_NOCACHE was unsupported; full readback completed without an OS-cache-bypass request.")
            }
        }
        return warnings.sorted()
    }

    private func makeErrors(operation: FileOperation, job: TransferJobSpec, sourceURL: URL) -> [WorkerTypedError] {
        operation.results.compactMap { result in
            guard !result.success else { return nil }
            return WorkerTypedError(
                code: workerErrorCode(for: result),
                message: result.error?.localizedDescription ?? "Verification failed",
                destinationRequestID: destinationRequestID(for: result.destinationURL, destinations: job.destinations),
                relativePath: try? RelativePathResolver(base: sourceURL).resolve(result.sourceURL)
            )
        }
    }

    private func classifyExecutionError(_ error: Error) -> (status: TransferTerminalStatus, exit: TransferWorkerExitCode, code: String) {
        return (.internalFailure, .internalFailure, "internal-failure")
    }

    private static func writeEvidenceAtomically(_ evidence: TransferEvidence, to finalURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            let data = try makeEncoder().encode(evidence)
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeDetailEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private func destinationRequestID(for fileURL: URL, destinations: [DestinationRequest]) -> String? {
    let fileComponents = fileURL.standardizedFileURL.pathComponents
    return destinations.first { destination in
        let root = URL(fileURLWithPath: destination.executionRoot, isDirectory: true).standardizedFileURL.pathComponents
        return fileComponents.count >= root.count && zip(root, fileComponents).allSatisfy(==)
    }?.requestID
}

private func makeFileEvidence(
    result: FileOperationResult,
    sourceURL: URL,
    destinations: [DestinationRequest],
    facts: WorkerDurabilityFactsCollector.Snapshot
) -> FileEvidenceRecord {
    let destinationID = destinationRequestID(for: result.destinationURL, destinations: destinations) ?? "unknown"
    let relativePath = (try? RelativePathResolver(base: sourceURL).resolve(result.sourceURL)) ?? result.sourceURL.lastPathComponent
    let typedError = result.success ? nil : WorkerTypedError(
        code: workerErrorCode(for: result),
        message: result.error?.localizedDescription ?? "Verification failed",
        destinationRequestID: destinationID,
        relativePath: relativePath
    )
    let copy = facts.copy ?? TransferCopyDurabilityFacts()
    let readback = facts.readback ?? TransferReadbackFacts()
    let outcome: WorkerVerificationOutcome
    if !result.success || result.verificationResult?.matches != true {
        outcome = .failed
    } else if copy.reusedExistingDestination,
              readback.fullReadPerformed,
              readback.sourceRemainedStable,
              operationFact(readback.cacheBypass).status != .failed {
        outcome = .verifiedDegraded
    } else if copy.ordinaryFlushSucceeded,
              copy.prePublicationChecksumMatched,
              copy.publicationSucceeded,
              copy.sourceRemainedStable,
              readback.fullReadPerformed,
              readback.sourceRemainedStable,
              operationFact(copy.fullSync).status == .succeeded,
              operationFact(copy.directorySync).status == .succeeded,
              operationFact(readback.cacheBypass).status == .succeeded {
        outcome = .verifiedStrong
    } else if copy.ordinaryFlushSucceeded,
              copy.prePublicationChecksumMatched,
              copy.publicationSucceeded,
              copy.sourceRemainedStable,
              readback.fullReadPerformed,
              readback.sourceRemainedStable,
              ![operationFact(copy.fullSync), operationFact(copy.directorySync), operationFact(readback.cacheBypass)]
                .contains(where: { $0.status == .failed || $0.status == .notRequested }) {
        outcome = .verifiedDegraded
    } else {
        outcome = .failed
    }

    return FileEvidenceRecord(
        destinationRequestID: destinationID,
        relativePath: relativePath,
        status: result.success ? "verified" : "failed",
        fileSize: result.fileSize,
        checksumAlgorithm: result.verificationResult?.checksumType.rawValue,
        sourceChecksum: result.verificationResult?.sourceChecksum,
        destinationChecksum: result.verificationResult?.destinationChecksum,
        verificationOutcome: outcome,
        sourceStableDuringReads: copy.sourceRemainedStable && readback.sourceRemainedStable,
        prePublicationChecksumMatched: copy.prePublicationChecksumMatched,
        fullDestinationReadbackPerformed: readback.fullReadPerformed,
        destinationReadbackBytes: readback.bytesRead,
        cacheBypass: operationFact(readback.cacheBypass),
        durabilityFlush: operationFact(copy.fullSync),
        directoryMetadataFlush: operationFact(copy.directorySync),
        publication: copy.reusedExistingDestination
            ? .reusedExisting
            : copy.publicationRemovedAfterFailure
                ? .removedAfterFailure
                : copy.publicationSucceeded ? .published : .notPublished,
        error: typedError
    )
}

private func workerErrorCode(for result: FileOperationResult) -> String {
    if result.verificationResult?.matches == false || (result.error == nil && !result.success) {
        return "checksum-mismatch"
    }
    let error = result.error as NSError?
    let message = error?.localizedDescription.lowercased() ?? ""
    if error?.domain == "BitMatchTransferWorker.Readback" {
        switch error?.code {
        case -2: return "source-mutated"
        case -3: return "short-readback"
        case -4: return "destination-mutated"
        default: return "readback-failed"
        }
    }
    if error?.domain == "BitMatchTransferWorker.Durability" {
        if message.contains("f_fullfsync") { return "full-sync-failed" }
        if message.contains("f_nocache") { return "cache-bypass-failed" }
        if message.contains("directory") { return "directory-flush-failed" }
        return "durability-failed"
    }
    if message.contains("appeared during copy") { return "publication-collision" }
    if message.contains("source file changed") { return "source-mutated" }
    if error?.domain == NSPOSIXErrorDomain, error?.code == Int(ENOENT) { return "destination-disappeared" }
    return "io-failure"
}

private func operationFact(_ outcome: TransferSystemCallOutcome?) -> WorkerOperationFact {
    switch outcome {
    case .none:
        return WorkerOperationFact(status: .notRequested)
    case .succeeded:
        return WorkerOperationFact(status: .succeeded)
    case .unsupported(let code, let message):
        return WorkerOperationFact(status: .unsupported, errorCode: code, errorMessage: message)
    case .failed(let code, let message):
        return WorkerOperationFact(status: .failed, errorCode: code, errorMessage: message)
    }
}
#endif

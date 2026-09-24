import Foundation
#if os(macOS)
import Darwin
#endif

/// The legacy runtime was qualified as protocol V3. V4 execution binds this task-local
/// override only for one validated exact-subset job, allowing the same hardened runtime
/// to execute and emit V4 without changing V3's default meaning or behavior.
public enum TransferProtocolExecutionContext {
    @TaskLocal public static var protocolVersionOverride: Int?
}

public enum TransferWorkerIdentity {
    public static let semanticVersion = "0.4.0"
    public static let build = "pp-068.0"
    public static let upstreamRepository = "https://github.com/mikecerisano/Bitmatch"
    public static let upstreamRevision = "3debabe2e1049c7e02ee5f3587464894f3b190d5"
    /// V3 remains the default. V4 is selected only through the explicit dispatcher.
    public static var protocolVersion: Int { TransferProtocolExecutionContext.protocolVersionOverride ?? 3 }
    public static let supportedProtocolVersions = [3, 4]
}

/// Shared wire-level rules for the V4 exact file selection. Identity and ordering use
/// the original UTF-8 bytes: do not lowercase or Unicode-normalize filesystem names.
public enum TransferRelativePathSelection {
    public static func canonicalized(_ paths: [String]) -> [String] {
        paths.sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
    }

    public static func validationIssue(_ paths: [String]) -> String? {
        guard !paths.isEmpty else { return "V4 includeRelativePaths must not be empty" }
        var seen = Set<Data>()
        for path in paths {
            if let issue = validationIssue(path) { return issue }
            let key = Data(path.utf8)
            guard seen.insert(key).inserted else {
                return "V4 includeRelativePaths contains a duplicate path: \(path)"
            }
        }
        return nil
    }

    public static func validationIssue(_ path: String) -> String? {
        guard !path.isEmpty else { return "V4 selected relative paths must not be empty" }
        guard !path.hasPrefix("/") else { return "V4 selected paths must be source-root-relative: \(path)" }
        guard !path.hasPrefix("~") else { return "V4 selected paths must not use home-relative syntax: \(path)" }
        guard !path.contains("\\") else { return "V4 selected paths must use forward-slash separators: \(path)" }
        guard !path.utf8.contains(0) else { return "V4 selected paths must not contain NUL bytes" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return "V4 selected paths must not contain empty, dot, or traversal components: \(path)"
        }
        return nil
    }

    public static func isCanonicalOrder(_ paths: [String]) -> Bool {
        let canonical = canonicalized(paths)
        guard canonical.count == paths.count else { return false }
        return zip(paths, canonical).allSatisfy { Data($0.utf8) == Data($1.utf8) }
    }
}

public struct TransferWorkerCapabilities: Codable, Equatable, Sendable {
    public let workerVersion: String
    public let workerBuild: String
    public let upstreamRepository: String
    public let upstreamRevision: String
    public let supportedProtocolVersions: [Int]
    public let supportedVerificationPolicies: [String]
    public let supportedVerificationAlgorithms: [String]
    public let maximumDestinations: Int
    public let pauseResume: Bool
    public let sourceReadOnly: Bool
    public let capabilities: [String]

    public init(
        workerVersion: String,
        workerBuild: String,
        upstreamRepository: String,
        upstreamRevision: String,
        supportedProtocolVersions: [Int],
        supportedVerificationPolicies: [String],
        supportedVerificationAlgorithms: [String],
        maximumDestinations: Int,
        pauseResume: Bool,
        sourceReadOnly: Bool,
        capabilities: [String]
    ) {
        self.workerVersion = workerVersion
        self.workerBuild = workerBuild
        self.upstreamRepository = upstreamRepository
        self.upstreamRevision = upstreamRevision
        self.supportedProtocolVersions = supportedProtocolVersions
        self.supportedVerificationPolicies = supportedVerificationPolicies
        self.supportedVerificationAlgorithms = supportedVerificationAlgorithms
        self.maximumDestinations = maximumDestinations
        self.pauseResume = pauseResume
        self.sourceReadOnly = sourceReadOnly
        self.capabilities = capabilities
    }
}

public struct TransferJobSpec: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let jobID: UUID
    public let attemptID: UUID
    public let requestedAt: Date
    public let sourceRoot: String
    public let destinations: [DestinationRequest]
    public let verificationPolicy: WorkerVerificationPolicy
    public let requestedCapabilities: [CapabilityRequest]
    /// Optional kernel-enforced lease path for this exact job + attempt. A caller that
    /// requires `attempt-lease-v1` must provide an absolute path. The dispatcher acquires
    /// the lease before any destination media side effect and holds it through the run.
    public let attemptLeasePath: String?
    /// V4 only. Exact, source-root-relative file set. V3 must omit this field and keeps
    /// its qualified whole-source behavior unchanged.
    public let includeRelativePaths: [String]?

    public init(
        protocolVersion: Int,
        jobID: UUID,
        attemptID: UUID,
        requestedAt: Date,
        sourceRoot: String,
        destinations: [DestinationRequest],
        verificationPolicy: WorkerVerificationPolicy = .sha256,
        requestedCapabilities: [CapabilityRequest] = [],
        attemptLeasePath: String? = nil,
        includeRelativePaths: [String]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptID = attemptID
        self.requestedAt = requestedAt
        self.sourceRoot = sourceRoot
        self.destinations = destinations
        self.verificationPolicy = verificationPolicy
        self.requestedCapabilities = requestedCapabilities
        self.attemptLeasePath = attemptLeasePath
        self.includeRelativePaths = includeRelativePaths.map(TransferRelativePathSelection.canonicalized)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptID, requestedAt, sourceRoot
        case destinations, verificationPolicy, requestedCapabilities, attemptLeasePath, includeRelativePaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        attemptID = try container.decode(UUID.self, forKey: .attemptID)
        requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        sourceRoot = try container.decode(String.self, forKey: .sourceRoot)
        destinations = try container.decode([DestinationRequest].self, forKey: .destinations)
        verificationPolicy = try container.decodeIfPresent(WorkerVerificationPolicy.self, forKey: .verificationPolicy) ?? .sha256
        requestedCapabilities = try container.decodeIfPresent([CapabilityRequest].self, forKey: .requestedCapabilities) ?? []
        attemptLeasePath = try container.decodeIfPresent(String.self, forKey: .attemptLeasePath)
        includeRelativePaths = try container.decodeIfPresent([String].self, forKey: .includeRelativePaths)
            .map(TransferRelativePathSelection.canonicalized)
    }
}

public struct DestinationRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let executionRoot: String
    public let role: DestinationRole

    public init(requestID: String, executionRoot: String, role: DestinationRole) {
        self.requestID = requestID
        self.executionRoot = executionRoot
        self.role = role
    }
}

public enum DestinationRole: String, Codable, Equatable, Sendable {
    case working
    case backup
    case optional
}

public enum WorkerVerificationPolicy: Equatable, Sendable {
    case sha256
    case unsupported(String)

    public var wireValue: String {
        switch self {
        case .sha256: return "sha256"
        case .unsupported(let value): return value
        }
    }
}

extension WorkerVerificationPolicy: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "sha256" ? .sha256 : .unsupported(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

public struct CapabilityRequest: Codable, Equatable, Sendable {
    public let name: String
    public let required: Bool

    public init(name: String, required: Bool) {
        self.name = name
        self.required = required
    }
}

public enum TransferTerminalStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case completedWithFailures
    case invalidJob
    case unsupportedProtocolOrCapability
    case interrupted
    case internalFailure
}

public enum WorkerVerificationOutcome: String, Codable, Equatable, Sendable {
    case verifiedStrong = "VERIFIED_STRONG"
    case verifiedDegraded = "VERIFIED_DEGRADED"
    case failed = "FAILED"
}

public enum WorkerOperationStatus: String, Codable, Equatable, Sendable {
    case notRequested
    case succeeded
    case unsupported
    case failed
}

public struct WorkerOperationFact: Codable, Equatable, Sendable {
    public let status: WorkerOperationStatus
    public let errorCode: Int32?
    public let errorMessage: String?

    public init(status: WorkerOperationStatus, errorCode: Int32? = nil, errorMessage: String? = nil) {
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public var requested: Bool { status != .notRequested }
    public var supported: Bool? {
        switch status {
        case .notRequested: return nil
        case .unsupported: return false
        case .succeeded, .failed: return true
        }
    }
    public var succeeded: Bool? {
        switch status {
        case .notRequested, .unsupported: return nil
        case .succeeded: return true
        case .failed: return false
        }
    }
}

public enum WorkerPublicationDisposition: String, Codable, Equatable, Sendable {
    case published
    case reusedExisting
    case removedAfterFailure
    case notPublished
}

public enum TransferWorkerExitCode: Int32, Codable, Equatable, Sendable {
    case success = 0
    case completedWithFailures = 2
    case invalidJob = 3
    case unsupportedProtocolOrCapability = 4
    case interrupted = 5
    case internalFailure = 70
}

public struct TransferEvidence: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let jobID: UUID
    public let attemptID: UUID
    public let workerVersion: String
    public let workerBuild: String
    public let upstreamRepository: String
    public let upstreamRevision: String
    public let startedAt: Date
    public let endedAt: Date
    public let terminalStatus: TransferTerminalStatus
    public let verificationOutcome: WorkerVerificationOutcome
    public let source: SourceEvidenceSummary
    public let destinations: [DestinationEvidenceSummary]
    public let storageTopology: StorageTopologyEvidence
    public let verificationPolicyUsed: String?
    public let detailEvidence: DetailEvidenceReference?
    public let warnings: [String]
    public let errors: [WorkerTypedError]
    public let capabilitiesUsed: [String]
    /// V4 request binding. Nil for V3 artifacts so existing V3 wire shape remains
    /// compatible; required, non-empty and canonical for V4 artifacts.
    public let includeRelativePaths: [String]?

    init(
        protocolVersion: Int,
        jobID: UUID,
        attemptID: UUID,
        workerVersion: String,
        workerBuild: String,
        upstreamRepository: String,
        upstreamRevision: String,
        startedAt: Date,
        endedAt: Date,
        terminalStatus: TransferTerminalStatus,
        verificationOutcome: WorkerVerificationOutcome,
        source: SourceEvidenceSummary,
        destinations: [DestinationEvidenceSummary],
        storageTopology: StorageTopologyEvidence,
        verificationPolicyUsed: String?,
        detailEvidence: DetailEvidenceReference?,
        warnings: [String],
        errors: [WorkerTypedError],
        capabilitiesUsed: [String],
        includeRelativePaths: [String]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptID = attemptID
        self.workerVersion = workerVersion
        self.workerBuild = workerBuild
        self.upstreamRepository = upstreamRepository
        self.upstreamRevision = upstreamRevision
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.terminalStatus = terminalStatus
        self.verificationOutcome = verificationOutcome
        self.source = source
        self.destinations = destinations
        self.storageTopology = storageTopology
        self.verificationPolicyUsed = verificationPolicyUsed
        self.detailEvidence = detailEvidence
        self.warnings = warnings
        self.errors = errors
        self.capabilitiesUsed = capabilitiesUsed
        self.includeRelativePaths = includeRelativePaths
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptID, workerVersion, workerBuild
        case upstreamRepository, upstreamRevision, startedAt, endedAt
        case terminalStatus, verificationOutcome, source, destinations, storageTopology
        case verificationPolicyUsed, detailEvidence, warnings, errors, capabilitiesUsed
        case includeRelativePaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .protocolVersion)
        guard TransferWorkerIdentity.supportedProtocolVersions.contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported transfer evidence protocol version \(version)"
            )
        }
        let selectedPaths = try container.decodeIfPresent([String].self, forKey: .includeRelativePaths)
        if version == 3, selectedPaths != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .includeRelativePaths,
                in: container,
                debugDescription: "Protocol V3 evidence must not contain includeRelativePaths"
            )
        }
        if version == 4 {
            guard let selectedPaths,
                  TransferRelativePathSelection.validationIssue(selectedPaths) == nil,
                  TransferRelativePathSelection.isCanonicalOrder(selectedPaths) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .includeRelativePaths,
                    in: container,
                    debugDescription: "Protocol V4 evidence requires a non-empty canonical exact selected path set"
                )
            }
        }
        protocolVersion = version
        jobID = try container.decode(UUID.self, forKey: .jobID)
        attemptID = try container.decode(UUID.self, forKey: .attemptID)
        workerVersion = try container.decode(String.self, forKey: .workerVersion)
        workerBuild = try container.decode(String.self, forKey: .workerBuild)
        upstreamRepository = try container.decode(String.self, forKey: .upstreamRepository)
        upstreamRevision = try container.decode(String.self, forKey: .upstreamRevision)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        terminalStatus = try container.decode(TransferTerminalStatus.self, forKey: .terminalStatus)
        verificationOutcome = try container.decode(WorkerVerificationOutcome.self, forKey: .verificationOutcome)
        source = try container.decode(SourceEvidenceSummary.self, forKey: .source)
        destinations = try container.decode([DestinationEvidenceSummary].self, forKey: .destinations)
        storageTopology = try container.decode(StorageTopologyEvidence.self, forKey: .storageTopology)
        verificationPolicyUsed = try container.decodeIfPresent(String.self, forKey: .verificationPolicyUsed)
        detailEvidence = try container.decodeIfPresent(DetailEvidenceReference.self, forKey: .detailEvidence)
        warnings = try container.decode([String].self, forKey: .warnings)
        errors = try container.decode([WorkerTypedError].self, forKey: .errors)
        capabilitiesUsed = try container.decode([String].self, forKey: .capabilitiesUsed)
        includeRelativePaths = selectedPaths
    }
}

public struct SourceEvidenceSummary: Codable, Equatable, Sendable {
    public let executionRoot: String
    public let fileCount: Int
    public let totalBytes: Int64
    public let transferReadPasses: Int
    public let transferBytesRead: Int64
    public let maximumBufferedBytes: Int
    public let stabilityVerifiedFiles: Int
    public let stabilityFailedFiles: Int
}

public struct DestinationEvidenceSummary: Codable, Equatable, Sendable {
    public let requestID: String
    public let executionRoot: String
    public let role: DestinationRole
    public let successfulFiles: Int
    public let failedFiles: Int
    public let verifiedBytes: Int64
    public let verificationOutcome: WorkerVerificationOutcome
    public let strongFiles: Int
    public let degradedFiles: Int
}

public struct DetailEvidenceReference: Codable, Equatable, Sendable {
    public let path: String
    public let format: String
    public let recordCount: Int
    public let sha256: String
}

public struct WorkerTypedError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let destinationRequestID: String?
    public let relativePath: String?

    public init(code: String, message: String, destinationRequestID: String? = nil, relativePath: String? = nil) {
        self.code = code
        self.message = message
        self.destinationRequestID = destinationRequestID
        self.relativePath = relativePath
    }
}

struct FileEvidenceRecord: Codable, Equatable, Sendable {
    let destinationRequestID: String
    let relativePath: String
    let status: String
    let fileSize: Int64
    let checksumAlgorithm: String?
    let sourceChecksum: String?
    let destinationChecksum: String?
    let verificationOutcome: WorkerVerificationOutcome
    let sourceStableDuringReads: Bool
    let prePublicationChecksumMatched: Bool
    let fullDestinationReadbackPerformed: Bool
    let destinationReadbackBytes: Int64
    let cacheBypass: WorkerOperationFact
    let durabilityFlush: WorkerOperationFact
    let directoryMetadataFlush: WorkerOperationFact
    /// Added compatibly within V3; `nil` is accepted when decoding evidence
    /// emitted by an earlier V3 worker build.
    let publicationInterrupted: Bool?
    let publication: WorkerPublicationDisposition
    let error: WorkerTypedError?
}

public struct TransferWorkerRunResult: Sendable {
    public let exitCode: TransferWorkerExitCode
    public let evidence: TransferEvidence?
    public let diagnostic: String?

    public init(exitCode: TransferWorkerExitCode, evidence: TransferEvidence?, diagnostic: String?) {
        self.exitCode = exitCode
        self.evidence = evidence
        self.diagnostic = diagnostic
    }
}


public struct TransferWorkerAttemptIdentity: Sendable, Equatable {
    public let jobID: UUID
    public let attemptID: UUID

    public init(jobID: UUID, attemptID: UUID) {
        self.jobID = jobID
        self.attemptID = attemptID
    }
}

/// Execution identity used only for hidden worker staging names. It is intentionally
/// platform-neutral because the shared file-copy services also build for iPad.
public enum TransferWorkerExecutionContext {
    @TaskLocal public static var attemptIdentity: TransferWorkerAttemptIdentity?
    /// Recovery-only opt-in. Normal transfers keep the established rule that a
    /// matching pre-existing final is degraded because this attempt did not write it.
    @TaskLocal public static var strengthenReusedExistingDestination = false

    static func makeTemporaryFileName() -> String {
        guard let identity = attemptIdentity else {
            return ".bitmatch.tmp." + UUID().uuidString
        }
        return temporaryFileName(jobID: identity.jobID, attemptID: identity.attemptID)
    }

    static func temporaryFileName(
        jobID: UUID,
        attemptID: UUID,
        randomID: UUID = UUID()
    ) -> String {
        temporaryFilePrefix(jobID: jobID, attemptID: attemptID)
            + randomID.uuidString.lowercased()
    }

    static func temporaryFilePrefix(jobID: UUID, attemptID: UUID) -> String {
        ".bitmatch.tmp."
            + jobID.uuidString.lowercased() + "."
            + attemptID.uuidString.lowercased() + "."
    }

    static func ownsTemporaryFile(named name: String, jobID: UUID, attemptID: UUID) -> Bool {
        let prefix = temporaryFilePrefix(jobID: jobID, attemptID: attemptID)
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}

#if os(macOS)
public enum TransferWorkerAttemptLeaseError: Error, Sendable, Equatable, LocalizedError {
    case openFailed(Int32)
    case notRegularFile
    case alreadyHeld
    case identityMismatch
    case readFailed(Int32)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code):
            return "Could not open the attempt lease (errno \(code))."
        case .notRegularFile:
            return "The attempt lease is not a regular file."
        case .alreadyHeld:
            return "Another process still holds this attempt lease."
        case .identityMismatch:
            return "The attempt lease belongs to a different job or attempt."
        case .readFailed(let code):
            return "Could not read the attempt lease identity (errno \(code))."
        case .writeFailed(let code):
            return "Could not persist the attempt lease identity (errno \(code))."
        }
    }
}

/// Kernel-enforced ownership for one exact transfer job + attempt.
public final class TransferWorkerAttemptLease: @unchecked Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }

    public static func acquire(
        at url: URL,
        jobID: UUID,
        attemptID: UUID
    ) throws -> TransferWorkerAttemptLease {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw TransferWorkerAttemptLeaseError.openFailed(errno)
        }

        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw TransferWorkerAttemptLeaseError.readFailed(errno)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw TransferWorkerAttemptLeaseError.notRegularFile
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw TransferWorkerAttemptLeaseError.alreadyHeld
                }
                throw TransferWorkerAttemptLeaseError.openFailed(code)
            }

            let expected = identityData(jobID: jobID, attemptID: attemptID)
            let existing = try readAll(from: descriptor)
            if existing.isEmpty {
                try writeIdentity(expected, to: descriptor)
            } else if existing != expected {
                throw TransferWorkerAttemptLeaseError.identityMismatch
            }
            return TransferWorkerAttemptLease(fileDescriptor: descriptor)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    public static func identityData(jobID: UUID, attemptID: UUID) -> Data {
        Data((
            "bitmatch-attempt-lease-v1\n"
            + "job=" + jobID.uuidString.lowercased() + "\n"
            + "attempt=" + attemptID.uuidString.lowercased() + "\n"
        ).utf8)
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw TransferWorkerAttemptLeaseError.readFailed(errno)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw TransferWorkerAttemptLeaseError.readFailed(errno)
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
        return result
    }

    private static func writeIdentity(_ data: Data, to descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw TransferWorkerAttemptLeaseError.writeFailed(errno)
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    raw.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw TransferWorkerAttemptLeaseError.writeFailed(errno)
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw TransferWorkerAttemptLeaseError.writeFailed(errno)
        }
    }
}
#endif

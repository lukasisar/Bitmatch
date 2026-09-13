import Foundation

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
        self.includeRelativePaths = includeRelativePaths.map(TransferRelativePathSelection.canonicalized)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptID, requestedAt, sourceRoot
        case destinations, verificationPolicy, requestedCapabilities, includeRelativePaths
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

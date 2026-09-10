import Foundation

public enum TransferWorkerIdentity {
    public static let semanticVersion = "0.2.0"
    public static let build = "pp-016.1"
    public static let upstreamRepository = "https://github.com/mikecerisano/Bitmatch"
    public static let upstreamRevision = "3debabe2e1049c7e02ee5f3587464894f3b190d5"
    public static let protocolVersion = 2
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

    public init(
        protocolVersion: Int,
        jobID: UUID,
        attemptID: UUID,
        requestedAt: Date,
        sourceRoot: String,
        destinations: [DestinationRequest],
        verificationPolicy: WorkerVerificationPolicy = .sha256,
        requestedCapabilities: [CapabilityRequest] = []
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptID = attemptID
        self.requestedAt = requestedAt
        self.sourceRoot = sourceRoot
        self.destinations = destinations
        self.verificationPolicy = verificationPolicy
        self.requestedCapabilities = requestedCapabilities
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptID, requestedAt, sourceRoot
        case destinations, verificationPolicy, requestedCapabilities
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
    public let verificationPolicyUsed: String?
    public let detailEvidence: DetailEvidenceReference?
    public let warnings: [String]
    public let errors: [WorkerTypedError]
    public let capabilitiesUsed: [String]

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
        verificationPolicyUsed: String?,
        detailEvidence: DetailEvidenceReference?,
        warnings: [String],
        errors: [WorkerTypedError],
        capabilitiesUsed: [String]
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
        self.verificationPolicyUsed = verificationPolicyUsed
        self.detailEvidence = detailEvidence
        self.warnings = warnings
        self.errors = errors
        self.capabilitiesUsed = capabilitiesUsed
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptID, workerVersion, workerBuild
        case upstreamRepository, upstreamRevision, startedAt, endedAt
        case terminalStatus, verificationOutcome, source, destinations
        case verificationPolicyUsed, detailEvidence, warnings, errors, capabilitiesUsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .protocolVersion)
        guard version == TransferWorkerIdentity.protocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported transfer evidence protocol version \(version)"
            )
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
        verificationPolicyUsed = try container.decodeIfPresent(String.self, forKey: .verificationPolicyUsed)
        detailEvidence = try container.decodeIfPresent(DetailEvidenceReference.self, forKey: .detailEvidence)
        warnings = try container.decode([String].self, forKey: .warnings)
        errors = try container.decode([WorkerTypedError].self, forKey: .errors)
        capabilitiesUsed = try container.decode([String].self, forKey: .capabilitiesUsed)
    }
}

public struct SourceEvidenceSummary: Codable, Equatable, Sendable {
    public let executionRoot: String
    public let fileCount: Int
    public let totalBytes: Int64
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
    let publication: WorkerPublicationDisposition
    let error: WorkerTypedError?
}

public struct TransferWorkerRunResult: Sendable {
    public let exitCode: TransferWorkerExitCode
    public let evidence: TransferEvidence?
    public let diagnostic: String?
}

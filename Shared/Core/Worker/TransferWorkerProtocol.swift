import Foundation

public enum TransferWorkerIdentity {
    public static let semanticVersion = "0.1.0"
    public static let build = "pp-015.1"
    public static let upstreamRepository = "https://github.com/mikecerisano/Bitmatch"
    public static let upstreamRevision = "3debabe2e1049c7e02ee5f3587464894f3b190d5"
    public static let protocolVersion = 1
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
    public let source: SourceEvidenceSummary
    public let destinations: [DestinationEvidenceSummary]
    public let verificationPolicyUsed: String?
    public let detailEvidence: DetailEvidenceReference?
    public let warnings: [String]
    public let errors: [WorkerTypedError]
    public let capabilitiesUsed: [String]
}

public struct SourceEvidenceSummary: Codable, Equatable, Sendable {
    public let executionRoot: String
    public let fileCount: Int
    public let totalBytes: Int64
}

public struct DestinationEvidenceSummary: Codable, Equatable, Sendable {
    public let requestID: String
    public let executionRoot: String
    public let role: DestinationRole
    public let successfulFiles: Int
    public let failedFiles: Int
    public let verifiedBytes: Int64
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
    let error: WorkerTypedError?
}

public struct TransferWorkerRunResult: Sendable {
    public let exitCode: TransferWorkerExitCode
    public let evidence: TransferEvidence?
    public let diagnostic: String?
}

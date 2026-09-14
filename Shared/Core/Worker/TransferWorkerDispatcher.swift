import Foundation

/// Explicit protocol router. V3 remains the already-qualified whole-source operation.
/// V4 binds an exact source selection and then executes through the same hardened
/// TransferWorkerRuntime, SharedFileOperationsService, fan-out, verification,
/// no-clobber publication, durability and topology code paths.
public struct TransferWorkerDispatcher {
    public static let exactSubsetCapability = "exact-relative-path-subset-v4"
    /// Observational only. `--progress` writes lossy JSONL telemetry and is never
    /// transfer evidence or completion authority.
    public static let liveProgressCapability = "live-progress-jsonl-v1"

    private let runtime: TransferWorkerRuntime

    public init(runtime: TransferWorkerRuntime = TransferWorkerRuntime()) {
        self.runtime = runtime
    }

    public func capabilities() -> TransferWorkerCapabilities {
        let legacy = runtime.capabilities()
        return TransferWorkerCapabilities(
            workerVersion: TransferWorkerIdentity.semanticVersion,
            workerBuild: TransferWorkerIdentity.build,
            upstreamRepository: legacy.upstreamRepository,
            upstreamRevision: legacy.upstreamRevision,
            supportedProtocolVersions: TransferWorkerIdentity.supportedProtocolVersions,
            supportedVerificationPolicies: legacy.supportedVerificationPolicies,
            supportedVerificationAlgorithms: legacy.supportedVerificationAlgorithms,
            maximumDestinations: legacy.maximumDestinations,
            pauseResume: legacy.pauseResume,
            sourceReadOnly: legacy.sourceReadOnly,
            capabilities: Array(Set(legacy.capabilities + [Self.exactSubsetCapability, Self.liveProgressCapability])).sorted()
        )
    }

    public func run(job: TransferJobSpec, evidenceURL: URL) async -> TransferWorkerRunResult {
        switch job.protocolVersion {
        case 3:
            guard job.includeRelativePaths == nil else {
                return TransferWorkerRunResult(
                    exitCode: .invalidJob,
                    evidence: nil,
                    diagnostic: "Protocol V3 must not contain includeRelativePaths; V3 always transfers the complete accepted source root"
                )
            }
            return await runtime.run(job: job, evidenceURL: evidenceURL)

        case 4:
            guard let selected = job.includeRelativePaths else {
                return TransferWorkerRunResult(
                    exitCode: .invalidJob,
                    evidence: nil,
                    diagnostic: "Protocol V4 requires includeRelativePaths"
                )
            }
            if let issue = TransferRelativePathSelection.validationIssue(selected) {
                return TransferWorkerRunResult(exitCode: .invalidJob, evidence: nil, diagnostic: issue)
            }
            let canonical = TransferRelativePathSelection.canonicalized(selected)
            return await runV4(job: job, canonicalSelection: canonical, evidenceURL: evidenceURL)

        default:
            return TransferWorkerRunResult(
                exitCode: .unsupportedProtocolOrCapability,
                evidence: nil,
                diagnostic: "Unsupported protocol version \(job.protocolVersion)"
            )
        }
    }

    private func runV4(
        job: TransferJobSpec,
        canonicalSelection: [String],
        evidenceURL: URL
    ) async -> TransferWorkerRunResult {
        let requiredUnsupported = job.requestedCapabilities.filter {
            $0.required && !capabilities().capabilities.contains($0.name)
        }
        guard requiredUnsupported.isEmpty else {
            return TransferWorkerRunResult(
                exitCode: .unsupportedProtocolOrCapability,
                evidence: nil,
                diagnostic: "Unsupported mandatory capability \(requiredUnsupported[0].name)"
            )
        }

        let detailsURL = URL(fileURLWithPath: evidenceURL.path + ".details.jsonl")
        guard !FileManager.default.fileExists(atPath: evidenceURL.path),
              !FileManager.default.fileExists(atPath: detailsURL.path) else {
            return TransferWorkerRunResult(
                exitCode: .invalidJob,
                evidence: nil,
                diagnostic: "Evidence artifacts already exist; refusing to overwrite them"
            )
        }

        // The legacy runtime already validates all of its own mandatory capabilities.
        // Exact-subset support and live progress are dispatcher/CLI-owned markers, so
        // remove only those before delegating to the unchanged transfer runtime.
        let delegatedCapabilities = job.requestedCapabilities.filter {
            $0.name != Self.exactSubsetCapability && $0.name != Self.liveProgressCapability
        }
        let delegatedJob = TransferJobSpec(
            protocolVersion: 4,
            jobID: job.jobID,
            attemptID: job.attemptID,
            requestedAt: job.requestedAt,
            sourceRoot: job.sourceRoot,
            destinations: job.destinations,
            verificationPolicy: job.verificationPolicy,
            requestedCapabilities: delegatedCapabilities,
            includeRelativePaths: canonicalSelection
        )

        let tempEvidenceURL = evidenceURL.deletingLastPathComponent().appendingPathComponent(
            ".\(evidenceURL.lastPathComponent).pp068-v4-\(UUID().uuidString)"
        )
        let tempDetailsURL = URL(fileURLWithPath: tempEvidenceURL.path + ".details.jsonl")

        let delegatedResult = await TransferProtocolExecutionContext.$protocolVersionOverride.withValue(4) {
            await FileTreeEnumerator.$exactRelativePaths.withValue(canonicalSelection) {
                await runtime.run(job: delegatedJob, evidenceURL: tempEvidenceURL)
            }
        }

        guard let delegatedEvidence = delegatedResult.evidence else {
            try? FileManager.default.removeItem(at: tempEvidenceURL)
            try? FileManager.default.removeItem(at: tempDetailsURL)
            return delegatedResult
        }

        do {
            var reboundDetail = delegatedEvidence.detailEvidence
            if let detail = delegatedEvidence.detailEvidence {
                guard detail.path == tempDetailsURL.path,
                      FileManager.default.fileExists(atPath: tempDetailsURL.path) else {
                    throw NSError(
                        domain: "BitMatchTransferWorker.V4Binding",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Delegated V4 detail evidence was not bound to the expected artifact path"]
                    )
                }
                try FileManager.default.moveItem(at: tempDetailsURL, to: detailsURL)
                reboundDetail = DetailEvidenceReference(
                    path: detailsURL.path,
                    format: detail.format,
                    recordCount: detail.recordCount,
                    sha256: detail.sha256
                )
            }

            let rebound = TransferEvidence(
                protocolVersion: 4,
                jobID: delegatedEvidence.jobID,
                attemptID: delegatedEvidence.attemptID,
                workerVersion: delegatedEvidence.workerVersion,
                workerBuild: delegatedEvidence.workerBuild,
                upstreamRepository: delegatedEvidence.upstreamRepository,
                upstreamRevision: delegatedEvidence.upstreamRevision,
                startedAt: delegatedEvidence.startedAt,
                endedAt: delegatedEvidence.endedAt,
                terminalStatus: delegatedEvidence.terminalStatus,
                verificationOutcome: delegatedEvidence.verificationOutcome,
                source: delegatedEvidence.source,
                destinations: delegatedEvidence.destinations,
                storageTopology: delegatedEvidence.storageTopology,
                verificationPolicyUsed: delegatedEvidence.verificationPolicyUsed,
                detailEvidence: reboundDetail,
                warnings: delegatedEvidence.warnings,
                errors: delegatedEvidence.errors,
                capabilitiesUsed: delegatedEvidence.verificationPolicyUsed == nil
                    ? delegatedEvidence.capabilitiesUsed
                    : Array(Set(delegatedEvidence.capabilitiesUsed + [Self.exactSubsetCapability])).sorted(),
                includeRelativePaths: canonicalSelection
            )

            try writeEvidenceAtomically(rebound, to: evidenceURL)
            try? FileManager.default.removeItem(at: tempEvidenceURL)
            return TransferWorkerRunResult(
                exitCode: delegatedResult.exitCode,
                evidence: rebound,
                diagnostic: delegatedResult.diagnostic
            )
        } catch {
            try? FileManager.default.removeItem(at: tempEvidenceURL)
            try? FileManager.default.removeItem(at: tempDetailsURL)
            // If the detail artifact moved but the envelope failed, remove it rather
            // than leave an unbound artifact that could be mistaken for accepted proof.
            if !FileManager.default.fileExists(atPath: evidenceURL.path) {
                try? FileManager.default.removeItem(at: detailsURL)
            }
            return TransferWorkerRunResult(
                exitCode: .internalFailure,
                evidence: nil,
                diagnostic: "Could not bind V4 evidence to the requested exact set: \(error.localizedDescription)"
            )
        }
    }

    private func writeEvidenceAtomically(_ evidence: TransferEvidence, to finalURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let temporaryURL = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).partial-\(UUID().uuidString)"
        )
        do {
            let data = try TransferWorkerRuntime.makeEncoder().encode(evidence)
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

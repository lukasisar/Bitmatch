import BitMatchTransferCore
import Foundation

/// Non-authoritative live telemetry for the Post Prep pilot UI.
///
/// The JSONL sidecar is intentionally separate from transfer evidence. Losing it,
/// failing to write it, or observing 100% here must never change worker exit status,
/// verification, evidence, publication, or any safe-to-clear conclusion.
struct WorkerLiveProgressRecord: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case progress, heartbeat }
    enum Phase: String, Codable, Sendable { case scanning, copying, verifying, finishingRecords = "finishing_records" }

    let schemaVersion: Int
    let sequence: Int64
    let kind: Kind
    let observedAt: Date
    let lastProgressAt: Date
    let phase: Phase
    let filesCompleted: Int
    let filesTotal: Int
    let bytesCompleted: Int64?
    let bytesTotal: Int64?
    let fractionCompleted: Double?
    let currentFile: String?
    let elapsedSeconds: TimeInterval?
    let bytesPerSecond: Double?
    let approximateRemainingSeconds: TimeInterval?
}

final class WorkerLiveProgressSidecar: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var sequence: Int64 = 0
    private var latest: WorkerLiveProgressRecord?
    private var heartbeat: DispatchSourceTimer?

    static func open(at url: URL) -> WorkerLiveProgressSidecar? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = FileHandle(forWritingAtPath: url.path) else {
                return nil
            }
            return WorkerLiveProgressSidecar(handle: handle)
        } catch {
            return nil
        }
    }

    private init(handle: FileHandle) {
        self.handle = handle
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        startHeartbeat()
    }

    deinit {
        heartbeat?.cancel()
        try? handle.close()
    }

    func emitInitialScanning() {
        let now = Date()
        emit(WorkerLiveProgressRecord(
            schemaVersion: 1,
            sequence: 0,
            kind: .progress,
            observedAt: now,
            lastProgressAt: now,
            phase: .scanning,
            filesCompleted: 0,
            filesTotal: 0,
            bytesCompleted: 0,
            bytesTotal: nil,
            fractionCompleted: nil,
            currentFile: nil,
            elapsedSeconds: 0,
            bytesPerSecond: nil,
            approximateRemainingSeconds: nil
        ), advancesProgressClock: true)
    }

    func observe(_ progress: OperationProgress) {
        let now = Date()
        let perDestinationTotals = progress.perDestinationTotals ?? []
        let perDestinationCompleted = progress.perDestinationCompleted ?? []
        let filesTotal = perDestinationTotals.max() ?? progress.totalFiles
        let filesCompleted = perDestinationCompleted.min() ?? min(progress.filesProcessed, filesTotal)
        let elapsed = progress.elapsedTime
        let enoughHistory = (elapsed ?? 0) >= 2 && ((progress.bytesProcessed ?? 0) > 0 || filesCompleted > 0)
        let speed = enoughHistory ? (progress.averageSpeed ?? progress.speed) : nil
        let remaining = enoughHistory ? progress.timeRemaining : nil
        let fraction: Double?
        if let bytesDone = progress.bytesProcessed,
           let totalBytes = progress.totalBytes,
           totalBytes > 0 {
            fraction = min(1, max(0, Double(bytesDone) / Double(totalBytes)))
        } else if progress.overallProgress.isFinite {
            fraction = min(1, max(0, progress.overallProgress))
        } else {
            fraction = nil
        }

        emit(WorkerLiveProgressRecord(
            schemaVersion: 1,
            sequence: 0,
            kind: .progress,
            observedAt: now,
            lastProgressAt: now,
            phase: Self.phase(for: progress.currentStage),
            filesCompleted: max(0, filesCompleted),
            filesTotal: max(0, filesTotal),
            bytesCompleted: progress.bytesProcessed.map { max(0, $0) },
            bytesTotal: progress.totalBytes.map { max(0, $0) },
            fractionCompleted: fraction,
            currentFile: progress.currentFile,
            elapsedSeconds: elapsed,
            bytesPerSecond: speed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            approximateRemainingSeconds: remaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        ), advancesProgressClock: true)
    }

    func emitFinishing() {
        lock.lock()
        let previous = latest
        lock.unlock()
        let now = Date()
        emit(WorkerLiveProgressRecord(
            schemaVersion: 1,
            sequence: 0,
            kind: .progress,
            observedAt: now,
            lastProgressAt: now,
            phase: .finishingRecords,
            filesCompleted: previous?.filesCompleted ?? 0,
            filesTotal: previous?.filesTotal ?? 0,
            bytesCompleted: previous?.bytesCompleted,
            bytesTotal: previous?.bytesTotal,
            fractionCompleted: previous?.fractionCompleted,
            currentFile: nil,
            elapsedSeconds: previous?.elapsedSeconds,
            bytesPerSecond: previous?.bytesPerSecond,
            approximateRemainingSeconds: nil
        ), advancesProgressClock: true)
    }

    func close() {
        lock.lock()
        heartbeat?.cancel()
        heartbeat = nil
        try? handle.synchronize()
        try? handle.close()
        lock.unlock()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.emitHeartbeat() }
        timer.resume()
        heartbeat = timer
    }

    private func emitHeartbeat() {
        lock.lock()
        guard let previous = latest else {
            lock.unlock()
            return
        }
        let progressAt = previous.lastProgressAt
        lock.unlock()
        let now = Date()
        let record = WorkerLiveProgressRecord(
            schemaVersion: 1,
            sequence: 0,
            kind: .heartbeat,
            observedAt: now,
            lastProgressAt: progressAt,
            phase: previous.phase,
            filesCompleted: previous.filesCompleted,
            filesTotal: previous.filesTotal,
            bytesCompleted: previous.bytesCompleted,
            bytesTotal: previous.bytesTotal,
            fractionCompleted: previous.fractionCompleted,
            currentFile: previous.currentFile,
            elapsedSeconds: previous.elapsedSeconds.map { $0 + now.timeIntervalSince(previous.observedAt) },
            bytesPerSecond: previous.bytesPerSecond,
            approximateRemainingSeconds: previous.approximateRemainingSeconds,
        )
        emit(record, advancesProgressClock: false)
    }

    private func emit(_ record: WorkerLiveProgressRecord, advancesProgressClock: Bool) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let priorProgressAt = latest?.lastProgressAt
        let sequenced = WorkerLiveProgressRecord(
            schemaVersion: record.schemaVersion,
            sequence: sequence,
            kind: record.kind,
            observedAt: record.observedAt,
            lastProgressAt: advancesProgressClock ? record.observedAt : (priorProgressAt ?? record.lastProgressAt),
            phase: record.phase,
            filesCompleted: record.filesCompleted,
            filesTotal: record.filesTotal,
            bytesCompleted: record.bytesCompleted,
            bytesTotal: record.bytesTotal,
            fractionCompleted: record.fractionCompleted,
            currentFile: record.currentFile,
            elapsedSeconds: record.elapsedSeconds,
            bytesPerSecond: record.bytesPerSecond,
            approximateRemainingSeconds: record.approximateRemainingSeconds
        )
        latest = sequenced
        guard let data = try? encoder.encode(sequenced) else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            try handle.synchronize()
        } catch {
            // Observability is intentionally lossy and never transfer authority.
        }
    }

    private static func phase(for stage: ProgressStage) -> WorkerLiveProgressRecord.Phase {
        switch stage {
        case .idle, .preparing: .scanning
        case .copying: .copying
        case .verifying: .verifying
        case .generating, .completed: .finishingRecords
        }
    }
}

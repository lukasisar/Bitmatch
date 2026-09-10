import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin

struct FanOutDestinationTarget: Sendable {
    let index: Int
    let root: PinnedDestinationDirectory
}

struct FanOutDestinationCopyResult: @unchecked Sendable {
    let destinationIndex: Int
    let destinationURL: URL
    let success: Bool
    let error: Error?
    let fileSize: Int64
}

struct FanOutFileCopyResult: @unchecked Sendable {
    let sourceSHA256: String
    let sourceBytesRead: Int64
    let sourceReadPasses: Int
    let maximumBufferedBytes: Int
    let sourceIdentity: FanOutSourceIdentity
    let destinations: [FanOutDestinationCopyResult]
}

struct FanOutSourceIdentity: Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
    }

    func matches(_ info: stat) -> Bool {
        device == UInt64(info.st_dev)
            && inode == UInt64(info.st_ino)
            && size == Int64(info.st_size)
            && modificationSeconds == info.st_mtimespec.tv_sec
            && modificationNanoseconds == info.st_mtimespec.tv_nsec
    }
}

private final class FanOutTemporaryWriter {
    let target: FanOutDestinationTarget
    let destinationPath: String
    let parentFD: Int32
    let filename: String
    let temporaryName: String
    let temporaryFD: Int32
    let handle: FileHandle
    var published = false
    var closed = false

    init(target: FanOutDestinationTarget, relativeComponents: [String]) throws {
        self.target = target
        self.parentFD = try target.root.openOrCreateDirectory(at: Array(relativeComponents.dropLast()))
        self.filename = relativeComponents[relativeComponents.count - 1]
        self.destinationPath = target.root.destinationURL(for: relativeComponents.joined(separator: "/")).path
        self.temporaryName = ".bitmatch.tmp." + UUID().uuidString
        do {
            self.temporaryFD = try PinnedDestinationDirectory.createTemporaryFile(
                named: temporaryName,
                relativeTo: parentFD
            )
            self.handle = FileHandle(fileDescriptor: temporaryFD, closeOnDealloc: false)
        } catch {
            _ = Darwin.close(parentFD)
            throw error
        }
    }

    deinit {
        cleanup()
        _ = Darwin.close(parentFD)
    }

    func cleanup() {
        if !closed {
            try? handle.close()
            closed = true
        }
        if !published {
            PinnedDestinationDirectory.removeItem(named: temporaryName, relativeTo: parentFD)
        }
    }
}

extension FileCopyService {
    /// The worker fan-out keeps exactly one source chunk resident and writes it
    /// to every still-active destination before reading the next chunk. This is
    /// deliberately synchronous backpressure: a slow writer bounds producer
    /// progress instead of growing a queue.
    static let fanOutChunkSize = 4 * 1024 * 1024
    static let fanOutMaximumBufferedBytes = fanOutChunkSize

    static func prepareFanOutDirectoryTree(
        from sourceRoot: URL,
        in destinationRoot: PinnedDestinationDirectory
    ) throws {
        let resolver = RelativePathResolver(base: sourceRoot)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            if enumerator.level == 1,
               FileTreeEnumerator.skippedVolumeMetadataDirectories.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let relativePath = try resolver.resolve(item)
            guard let components = fanOutRelativeComponents(relativePath) else {
                throw FileOperationError.unsafeOperation("Invalid destination directory path")
            }
            let descriptor = try destinationRoot.openOrCreateDirectory(at: components)
            _ = Darwin.close(descriptor)
        }
    }

    static func copyFileFanOut(
        from source: URL,
        relativePath: String,
        to targets: [FanOutDestinationTarget],
        durabilityIO: any TransferDurabilityIO,
        durabilityRecorder: (any TransferDurabilityRecorder)?,
        pauseCheck: (@Sendable () async throws -> Void)? = nil
    ) async throws -> FanOutFileCopyResult {
        guard let components = fanOutRelativeComponents(relativePath) else {
            throw FileOperationError.unsafeOperation("Invalid destination file path")
        }

        try durabilityIO.prepareForSourceTransfer(sourcePath: source.path)
        let sourceFD = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard sourceFD >= 0 else { throw fanOutPOSIXError("Unable to open source read-only") }
        defer { _ = Darwin.close(sourceFD) }

        var sourceInitial = stat()
        guard fstat(sourceFD, &sourceInitial) == 0,
              (sourceInitial.st_mode & S_IFMT) == S_IFREG else {
            throw fanOutPOSIXError("Unable to inspect opened source file")
        }
        let sourceSize = Int64(sourceInitial.st_size)

        var writers: [Int: FanOutTemporaryWriter] = [:]
        var terminal: [Int: FanOutDestinationCopyResult] = [:]
        var reused: [Int: FanOutDestinationTarget] = [:]

        for target in targets {
            let destinationURL = target.root.destinationURL(for: relativePath)
            do {
                let parentFD = try target.root.openOrCreateDirectory(at: Array(components.dropLast()))
                let filename = components[components.count - 1]
                let exists = try PinnedDestinationDirectory.isExistingRegularFile(
                    named: filename,
                    relativeTo: parentFD
                )
                _ = Darwin.close(parentFD)
                if exists {
                    let existing = try target.root.openRegularFile(at: components)
                    guard Int64(try existing.snapshot().st_size) == sourceSize else {
                        throw NSError(
                            domain: "FileCopyService",
                            code: NSFileWriteFileExistsError,
                            userInfo: [NSLocalizedDescriptionKey: "Existing destination file differs in size; refusing to overwrite it"]
                        )
                    }
                    reused[target.index] = target
                } else {
                    writers[target.index] = try FanOutTemporaryWriter(
                        target: target,
                        relativeComponents: components
                    )
                }
            } catch {
                terminal[target.index] = FanOutDestinationCopyResult(
                    destinationIndex: target.index,
                    destinationURL: destinationURL,
                    success: false,
                    error: error,
                    fileSize: 0
                )
            }
        }

        var sourceHasher = SHA256()
        var sourceBytesRead: Int64 = 0
        var maximumBufferedBytes = 0
        while true {
            try Task.checkCancellation()
            if let pauseCheck { try await pauseCheck() }
            let chunk = try durabilityIO.readSource(
                fileDescriptor: sourceFD,
                maximumCount: fanOutChunkSize
            )
            if chunk.isEmpty { break }
            sourceBytesRead += Int64(chunk.count)
            maximumBufferedBytes = max(maximumBufferedBytes, chunk.count)
            sourceHasher.update(data: chunk)

            for index in writers.keys.sorted() {
                guard let writer = writers[index] else { continue }
                do {
                    try durabilityIO.prepareForDestinationChunkWrite(
                        destinationPath: writer.destinationPath,
                        byteCount: chunk.count
                    )
                    try writer.handle.write(contentsOf: chunk)
                } catch {
                    terminal[index] = FanOutDestinationCopyResult(
                        destinationIndex: index,
                        destinationURL: writer.target.root.destinationURL(for: relativePath),
                        success: false,
                        error: error,
                        fileSize: 0
                    )
                    writer.cleanup()
                    writers[index] = nil
                }
            }
        }

        var sourceFinal = stat()
        let sourceStable = fstat(sourceFD, &sourceFinal) == 0
            && sourceBytesRead == sourceSize
            && fanOutFileRemainedStable(sourceInitial, sourceFinal)
        guard sourceStable else {
            let error = NSError(
                domain: "FileCopyService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Source file changed during fan-out copy; destinations were not published"]
            )
            for target in targets where terminal[target.index] == nil {
                terminal[target.index] = FanOutDestinationCopyResult(
                    destinationIndex: target.index,
                    destinationURL: target.root.destinationURL(for: relativePath),
                    success: false,
                    error: error,
                    fileSize: 0
                )
            }
            writers.values.forEach { $0.cleanup() }
            let digest = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
            durabilityRecorder?.recordSourceReadFacts(
                TransferSourceReadFacts(
                    readPasses: 1,
                    bytesRead: sourceBytesRead,
                    maximumBufferedBytes: maximumBufferedBytes
                ),
                sourcePath: source.path
            )
            return FanOutFileCopyResult(
                sourceSHA256: digest,
                sourceBytesRead: sourceBytesRead,
                sourceReadPasses: 1,
                maximumBufferedBytes: maximumBufferedBytes,
                sourceIdentity: FanOutSourceIdentity(sourceInitial),
                destinations: targets.compactMap { terminal[$0.index] }
            )
        }

        let sourceChecksum = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        durabilityRecorder?.recordSourceReadFacts(
            TransferSourceReadFacts(
                readPasses: 1,
                bytesRead: sourceBytesRead,
                maximumBufferedBytes: maximumBufferedBytes
            ),
            sourcePath: source.path
        )
        for (index, target) in reused {
            durabilityRecorder?.recordCopyFacts(
                TransferCopyDurabilityFacts(
                    reusedExistingDestination: true,
                    sourceRemainedStable: true
                ),
                destinationPath: target.root.destinationURL(for: relativePath).path
            )
            terminal[index] = FanOutDestinationCopyResult(
                destinationIndex: index,
                destinationURL: target.root.destinationURL(for: relativePath),
                success: true,
                error: nil,
                fileSize: sourceSize
            )
        }

        for index in writers.keys.sorted() {
            guard let writer = writers[index], terminal[index] == nil else { continue }
            do {
                try finalizeFanOutWriter(
                    writer,
                    source: sourceInitial,
                    sourceChecksum: sourceChecksum,
                    sourceSize: sourceSize,
                    durabilityIO: durabilityIO,
                    durabilityRecorder: durabilityRecorder
                )
                terminal[index] = FanOutDestinationCopyResult(
                    destinationIndex: index,
                    destinationURL: writer.target.root.destinationURL(for: relativePath),
                    success: true,
                    error: nil,
                    fileSize: sourceSize
                )
            } catch {
                terminal[index] = FanOutDestinationCopyResult(
                    destinationIndex: index,
                    destinationURL: writer.target.root.destinationURL(for: relativePath),
                    success: false,
                    error: error,
                    fileSize: 0
                )
                writer.cleanup()
            }
        }

        return FanOutFileCopyResult(
            sourceSHA256: sourceChecksum,
            sourceBytesRead: sourceBytesRead,
            sourceReadPasses: 1,
            maximumBufferedBytes: maximumBufferedBytes,
            sourceIdentity: FanOutSourceIdentity(sourceInitial),
            destinations: targets.compactMap { terminal[$0.index] }
        )
    }

    static func verifyPinnedDestinationFile(
        referenceSHA256: String,
        expectedSize: Int64,
        source: URL,
        sourceIdentity: FanOutSourceIdentity,
        pinnedRoot: PinnedDestinationDirectory,
        relativePath: String,
        durabilityIO: any TransferDurabilityIO,
        durabilityRecorder: (any TransferDurabilityRecorder)? = nil
    ) async throws -> VerificationResult {
        guard let components = fanOutRelativeComponents(relativePath) else {
            throw FileOperationError.unsafeOperation("Invalid destination file path")
        }
        let destination = try pinnedRoot.openRegularFile(at: components)
        let startedAt = Date()
        let destinationPath = pinnedRoot.destinationURL(for: relativePath).path

        do {
            try durabilityIO.prepareForSourceVerification(sourcePath: source.path)
            let sourceFD = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard sourceFD >= 0 else { throw fanOutPOSIXError("Unable to reopen source read-only for stability check") }
            var currentSource = stat()
            let sourceStable = fstat(sourceFD, &currentSource) == 0
                && (currentSource.st_mode & S_IFMT) == S_IFREG
                && sourceIdentity.matches(currentSource)
            _ = Darwin.close(sourceFD)
            guard sourceStable else {
                throw NSError(
                    domain: "BitMatchTransferWorker.Readback",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Source file changed after the fan-out read"]
                )
            }

            let opened = try destination.independentReadingDescriptor()
            defer { _ = Darwin.close(opened.descriptor) }
            guard Int64(opened.expected.st_size) == expectedSize else {
                throw NSError(
                    domain: "BitMatchTransferWorker.Readback",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Destination size differs before full readback"]
                )
            }

            var facts = TransferReadbackFacts(sourceRemainedStable: true)
            let cacheBypass = durabilityIO.requestCacheBypass(fileDescriptor: opened.descriptor)
            facts.cacheBypass = cacheBypass
            durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)
            if case .failed = cacheBypass {
                throw fanOutDurabilityError("F_NOCACHE readback request", outcome: cacheBypass)
            }

            var hasher = SHA256()
            while facts.bytesRead < expectedSize {
                try Task.checkCancellation()
                let remaining = expectedSize - facts.bytesRead
                let data = try durabilityIO.readDestination(
                    fileDescriptor: opened.descriptor,
                    maximumCount: Int(min(Int64(1024 * 1024), remaining))
                )
                guard !data.isEmpty else {
                    durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)
                    throw NSError(
                        domain: "BitMatchTransferWorker.Readback",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Short destination readback: expected \(expectedSize) bytes, read \(facts.bytesRead)"]
                    )
                }
                hasher.update(data: data)
                facts.bytesRead += Int64(data.count)
            }
            let trailing = try durabilityIO.readDestination(fileDescriptor: opened.descriptor, maximumCount: 1)
            var final = stat()
            guard trailing.isEmpty,
                  fstat(opened.descriptor, &final) == 0,
                  fanOutFileRemainedStable(opened.expected, final) else {
                durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)
                throw NSError(
                    domain: "BitMatchTransferWorker.Readback",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Destination changed during full readback"]
                )
            }
            facts.fullReadPerformed = true
            durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)

            let destinationChecksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let result = VerificationResult(
                sourceChecksum: referenceSHA256,
                destinationChecksum: destinationChecksum,
                matches: referenceSHA256 == destinationChecksum,
                checksumType: .sha256,
                processingTime: Date().timeIntervalSince(startedAt),
                fileSize: expectedSize
            )
            if !result.matches {
                rollbackFanOutPublication(
                    destination: destination,
                    destinationPath: destinationPath,
                    durabilityIO: durabilityIO,
                    durabilityRecorder: durabilityRecorder
                )
            }
            return result
        } catch {
            rollbackFanOutPublication(
                destination: destination,
                destinationPath: destinationPath,
                durabilityIO: durabilityIO,
                durabilityRecorder: durabilityRecorder
            )
            throw error
        }
    }

    private static func finalizeFanOutWriter(
        _ writer: FanOutTemporaryWriter,
        source: stat,
        sourceChecksum: String,
        sourceSize: Int64,
        durabilityIO: any TransferDurabilityIO,
        durabilityRecorder: (any TransferDurabilityRecorder)?
    ) throws {
        var times = [source.st_mtimespec, source.st_mtimespec]
        guard futimens(writer.temporaryFD, &times) == 0 else {
            throw fanOutPOSIXError("Unable to preserve destination modification date")
        }
        try writer.handle.synchronize()

        var facts = TransferCopyDurabilityFacts(
            ordinaryFlushSucceeded: true,
            sourceRemainedStable: true
        )
        durabilityRecorder?.recordCopyFacts(facts, destinationPath: writer.destinationPath)

        guard Darwin.lseek(writer.temporaryFD, 0, SEEK_SET) == 0 else {
            throw fanOutPOSIXError("Unable to seek temporary destination for pre-publication verification")
        }
        var temporaryHasher = SHA256()
        var verifiedBytes: Int64 = 0
        while verifiedBytes < sourceSize {
            let data = try fanOutReadDescriptor(
                writer.temporaryFD,
                maximumCount: Int(min(Int64(1024 * 1024), sourceSize - verifiedBytes))
            )
            guard !data.isEmpty else {
                throw NSError(
                    domain: "BitMatchTransferWorker.Readback",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Short temporary destination read before publication"]
                )
            }
            temporaryHasher.update(data: data)
            verifiedBytes += Int64(data.count)
        }
        let temporaryChecksum = temporaryHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard temporaryChecksum == sourceChecksum else {
            throw NSError(
                domain: "BitMatchTransferWorker.Readback",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Temporary destination checksum mismatch before publication"]
            )
        }
        facts.prePublicationChecksumMatched = true
        durabilityRecorder?.recordCopyFacts(facts, destinationPath: writer.destinationPath)

        let fullSync = durabilityIO.fullSync(fileDescriptor: writer.temporaryFD)
        facts.fullSync = fullSync
        durabilityRecorder?.recordCopyFacts(facts, destinationPath: writer.destinationPath)
        if case .failed = fullSync {
            throw fanOutDurabilityError("F_FULLFSYNC", outcome: fullSync)
        }

        var temporaryInfo = stat()
        guard fstat(writer.temporaryFD, &temporaryInfo) == 0,
              Int64(temporaryInfo.st_size) == sourceSize else {
            throw NSError(
                domain: "FileCopyService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Size mismatch after fan-out copy"]
            )
        }

        try durabilityIO.prepareForPublication(destinationPath: writer.destinationPath)
        try PinnedDestinationDirectory.publishTemporaryFile(
            named: writer.temporaryName,
            as: writer.filename,
            relativeTo: writer.parentFD
        )
        facts.publicationSucceeded = true
        let directorySync = durabilityIO.syncDirectory(fileDescriptor: writer.parentFD)
        facts.directorySync = directorySync
        durabilityRecorder?.recordCopyFacts(facts, destinationPath: writer.destinationPath)
        if case .failed = directorySync {
            if PinnedDestinationDirectory.removePublishedFile(
                named: writer.filename,
                relativeTo: writer.parentFD,
                expected: temporaryInfo
            ) {
                facts.publicationSucceeded = false
                facts.publicationRemovedAfterFailure = true
                _ = durabilityIO.syncDirectory(fileDescriptor: writer.parentFD)
                durabilityRecorder?.recordCopyFacts(facts, destinationPath: writer.destinationPath)
            }
            throw fanOutDurabilityError("destination directory fsync", outcome: directorySync)
        }

        writer.published = true
        try writer.handle.close()
        writer.closed = true
        durabilityRecorder?.recordCopyFacts(facts, destinationPath: writer.destinationPath)
    }

    private static func rollbackFanOutPublication(
        destination: PinnedDestinationFile,
        destinationPath: String,
        durabilityIO: any TransferDurabilityIO,
        durabilityRecorder: (any TransferDurabilityRecorder)?
    ) {
        guard var copy = durabilityRecorder?.copyFacts(destinationPath: destinationPath),
              copy.publicationSucceeded,
              !copy.reusedExistingDestination,
              destination.removeNamedFileIfStillThisFile() else { return }
        copy.publicationSucceeded = false
        copy.publicationRemovedAfterFailure = true
        durabilityRecorder?.recordCopyFacts(copy, destinationPath: destinationPath)
        destination.synchronizeParent(using: durabilityIO)
    }

    private static func fanOutRelativeComponents(_ relativePath: String) -> [String]? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            return nil
        }
        return components
    }

    private static func fanOutFileRemainedStable(_ initial: stat, _ final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
    }

    private static func fanOutReadDescriptor(_ fileDescriptor: Int32, maximumCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = Darwin.read(fileDescriptor, &buffer, maximumCount)
        guard count >= 0 else { throw fanOutPOSIXError("Destination read failed") }
        return Data(buffer.prefix(count))
    }

    private static func fanOutPOSIXError(_ message: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(errno))]
        )
    }

    private static func fanOutDurabilityError(
        _ operation: String,
        outcome: TransferSystemCallOutcome
    ) -> NSError {
        let details: (Int32, String)
        switch outcome {
        case .succeeded:
            details = (0, "Unexpected successful result")
        case .unsupported(let code, let message), .failed(let code, let message):
            details = (code, message)
        }
        return NSError(
            domain: "BitMatchTransferWorker.Durability",
            code: Int(details.0),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(details.1)"]
        )
    }
}
#endif

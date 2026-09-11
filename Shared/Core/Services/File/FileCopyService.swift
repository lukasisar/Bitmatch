// FileCopyService.swift - Atomic file copy with streaming enumeration
// Uses shared AsyncSemaphore from AsyncSemaphore.swift
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin

enum TransferSystemCallOutcome: Equatable, Sendable {
    case succeeded
    case unsupported(code: Int32, message: String)
    case failed(code: Int32, message: String)
}

struct TransferCopyDurabilityFacts: Equatable, Sendable {
    var ordinaryFlushSucceeded = false
    var fullSync: TransferSystemCallOutcome?
    var prePublicationChecksumMatched = false
    var publicationSucceeded = false
    var publicationInterrupted = false
    var publicationIdentity: PublishedFileIdentity?
    var reusedExistingDestination = false
    var directorySync: TransferSystemCallOutcome?
    var sourceRemainedStable = false
}

/// The filesystem object this attempt actually published. Paths are mutable
/// directory entries; durable evidence must stay bound to the object claimed by
/// this attempt rather than trusting whichever object later occupies the name.
struct PublishedFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }

    func matches(_ info: stat) -> Bool {
        device == UInt64(info.st_dev) && inode == UInt64(info.st_ino)
    }
}

struct FilePublicationResult: Equatable, Sendable {
    let identity: PublishedFileIdentity
    /// `nil` means the already-flushed temporary inode was published directly.
    /// A value means a non-linking filesystem required a distinct final inode,
    /// and this is the durability result for that final inode.
    let finalFullSync: TransferSystemCallOutcome?
}

struct DestinationPublicationFailure: Error, CustomNSError, LocalizedError {
    enum Kind: Int, Sendable {
        case interrupted = 1
        case ownershipLost = 2
    }

    static let errorDomain = "BitMatchTransferWorker.Publication"

    let kind: Kind
    let message: String
    let finalNameWasClaimed: Bool
    let claimedIdentity: PublishedFileIdentity?
    let underlyingError: Error?

    var errorCode: Int { kind.rawValue }
    var errorDescription: String? { message }
    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlyingError { info[NSUnderlyingErrorKey] = underlyingError }
        return info
    }

    static func interrupted(
        _ message: String,
        identity: PublishedFileIdentity?,
        underlying: Error
    ) -> DestinationPublicationFailure {
        DestinationPublicationFailure(
            kind: .interrupted,
            message: message,
            finalNameWasClaimed: true,
            claimedIdentity: identity,
            underlyingError: underlying
        )
    }

    static func ownershipLost(
        identity: PublishedFileIdentity,
        finalNameWasClaimed: Bool = true
    ) -> DestinationPublicationFailure {
        DestinationPublicationFailure(
            kind: .ownershipLost,
            message: "Published destination name no longer identifies the file claimed by this attempt",
            finalNameWasClaimed: finalNameWasClaimed,
            claimedIdentity: identity,
            underlyingError: nil
        )
    }
}

struct TransferReadbackFacts: Equatable, Sendable {
    var cacheBypass: TransferSystemCallOutcome?
    var fullReadPerformed = false
    var bytesRead: Int64 = 0
    var sourceRemainedStable = false
}

struct TransferSourceReadFacts: Equatable, Sendable {
    let readPasses: Int
    let bytesRead: Int64
    let maximumBufferedBytes: Int
}

protocol TransferDurabilityIO: Sendable {
    func fullSync(fileDescriptor: Int32) -> TransferSystemCallOutcome
    func syncDirectory(fileDescriptor: Int32) -> TransferSystemCallOutcome
    func requestCacheBypass(fileDescriptor: Int32) -> TransferSystemCallOutcome
    func readDestination(fileDescriptor: Int32, maximumCount: Int) throws -> Data
    func prepareForPublication(destinationPath: String) throws
    func prepareForClaimedPublication(destinationPath: String) throws
    func prepareForSourceVerification(sourcePath: String) throws
    func prepareForSourceTransfer(sourcePath: String) throws
    func readSource(fileDescriptor: Int32, maximumCount: Int) throws -> Data
    func prepareForDestinationChunkWrite(destinationPath: String, byteCount: Int) throws
}

extension TransferDurabilityIO {
    func prepareForSourceTransfer(sourcePath: String) throws {}
    func prepareForClaimedPublication(destinationPath: String) throws {}

    func readSource(fileDescriptor: Int32, maximumCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = Darwin.read(fileDescriptor, &buffer, maximumCount)
        guard count >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Source read failed: " + String(cString: strerror(errno))]
            )
        }
        return Data(buffer.prefix(count))
    }

    func prepareForDestinationChunkWrite(destinationPath: String, byteCount: Int) throws {}
}

protocol TransferDurabilityRecorder: Sendable {
    func recordCopyFacts(_ facts: TransferCopyDurabilityFacts, destinationPath: String)
    func recordReadbackFacts(_ facts: TransferReadbackFacts, destinationPath: String)
    func copyFacts(destinationPath: String) -> TransferCopyDurabilityFacts?
    func recordSourceReadFacts(_ facts: TransferSourceReadFacts, sourcePath: String)
}

extension TransferDurabilityRecorder {
    func recordSourceReadFacts(_ facts: TransferSourceReadFacts, sourcePath: String) {}
}

struct DarwinTransferDurabilityIO: TransferDurabilityIO {
    func prepareForPublication(destinationPath: String) throws {}
    func prepareForSourceVerification(sourcePath: String) throws {}

    func fullSync(fileDescriptor: Int32) -> TransferSystemCallOutcome {
        let result = Darwin.fcntl(fileDescriptor, F_FULLFSYNC)
        return Self.outcome(result: result, unsupportedCodes: [EINVAL, ENOTSUP, ENOTTY])
    }

    func syncDirectory(fileDescriptor: Int32) -> TransferSystemCallOutcome {
        let result = Darwin.fsync(fileDescriptor)
        return Self.outcome(result: result, unsupportedCodes: [EINVAL, ENOTSUP])
    }

    func requestCacheBypass(fileDescriptor: Int32) -> TransferSystemCallOutcome {
        let result = Darwin.fcntl(fileDescriptor, F_NOCACHE, 1)
        return Self.outcome(result: result, unsupportedCodes: [EINVAL, ENOTSUP, ENOTTY])
    }

    func readDestination(fileDescriptor: Int32, maximumCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = Darwin.read(fileDescriptor, &buffer, maximumCount)
        guard count >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Destination readback failed: " + String(cString: strerror(errno))]
            )
        }
        return Data(buffer.prefix(count))
    }

    private static func outcome(result: Int32, unsupportedCodes: Set<Int32>) -> TransferSystemCallOutcome {
        guard result != 0 else { return .succeeded }
        let code = errno
        let message = String(cString: strerror(code))
        return unsupportedCodes.contains(code)
            ? .unsupported(code: code, message: message)
            : .failed(code: code, message: message)
    }
}

private enum TransferDurabilityError {
    static func syscall(_ operation: String, outcome: TransferSystemCallOutcome) -> NSError {
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

/// Owns an already-open destination directory.  All writes below this point use
/// descriptor-relative calls so renaming a pathname after setup cannot redirect
/// a copy outside the selected destination.
final class PinnedDestinationDirectory: @unchecked Sendable {
    let logicalRootURL: URL
    private let directoryFD: Int32

    private init(logicalRootURL: URL, directoryFD: Int32) {
        self.logicalRootURL = logicalRootURL
        self.directoryFD = directoryFD
    }

    deinit { _ = Darwin.close(directoryFD) }

    static func open(destination: URL, rootComponents: [String]) throws -> PinnedDestinationDirectory {
        let destinationFD = try openDirectory(at: destination, description: "selected destination")
        var currentFD = destinationFD
        var logicalRoot = destination
        do {
            for component in rootComponents {
                try validate(component: component)
                let childFD = try openOrCreateDirectory(named: component, relativeTo: currentFD)
                _ = Darwin.close(currentFD)
                currentFD = childFD
                logicalRoot.appendPathComponent(component, isDirectory: true)
            }
            return PinnedDestinationDirectory(logicalRootURL: logicalRoot, directoryFD: currentFD)
        } catch {
            _ = Darwin.close(currentFD)
            throw error
        }
    }

    func openOrCreateDirectory(at relativeComponents: [String]) throws -> Int32 {
        var currentFD = Darwin.dup(directoryFD)
        guard currentFD >= 0 else { throw Self.posixError("Unable to duplicate pinned destination directory") }
        do {
            for component in relativeComponents {
                try Self.validate(component: component)
                let childFD = try Self.openOrCreateDirectory(named: component, relativeTo: currentFD)
                _ = Darwin.close(currentFD)
                currentFD = childFD
            }
            return currentFD
        } catch {
            _ = Darwin.close(currentFD)
            throw error
        }
    }

    func destinationURL(for relativePath: String) -> URL {
        logicalRootURL.appendingPathComponent(relativePath)
    }

    /// Opens a destination file below the pinned directory. The returned
    /// descriptor, not `logicalRootURL`, is the authority for subsequent
    /// reads. This is deliberately separate from the display URL above.
    func openRegularFile(
        at relativeComponents: [String],
        expectedIdentity: PublishedFileIdentity? = nil
    ) throws -> PinnedDestinationFile {
        guard let name = relativeComponents.last else {
            throw FileOperationError.unsafeOperation("Invalid destination file path")
        }
        let parentFD = try openOrCreateDirectory(at: Array(relativeComponents.dropLast()))
        defer { _ = Darwin.close(parentFD) }
        return try PinnedDestinationFile.open(
            named: name,
            relativeTo: parentFD,
            expectedIdentity: expectedIdentity
        )
    }

    static func isExistingRegularFile(named name: String, relativeTo parentFD: Int32) throws -> Bool {
        var info = stat()
        let status = name.withCString { fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw FileCopyService.existingDestinationConflictError("Existing destination item is not a regular file")
            }
            return true
        }
        guard errno == ENOENT else { throw posixError("Unable to inspect destination item") }
        return false
    }

    static func createTemporaryFile(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fd = name.withCString { openat(parentFD, $0, flags, 0o600) }
        guard fd >= 0 else { throw posixError("Unable to create temporary destination file") }
        return fd
    }

    static func removeItem(named name: String, relativeTo parentFD: Int32) {
        _ = name.withCString { unlinkat(parentFD, $0, 0) }
    }

    /// Publishes a verified temporary file without ever replacing an existing
    /// destination name.
    ///
    /// Hard-link-capable filesystems retain the original atomic `linkat`
    /// publication. FAT-family filesystems have no hard links, so only an
    /// explicit unsupported-operation result selects the descriptor-copy
    /// fallback. That fallback atomically claims the real final name with
    /// `O_CREAT | O_EXCL`, copies from the already-open verified temporary
    /// descriptor into the claimed descriptor, preserves timestamps, and
    /// flushes the distinct final inode. It deliberately gives up invisible
    /// atomic publication because exFAT provides no primitive that combines
    /// that property with no-clobber behavior.
    ///
    /// The returned identity must be carried into independent readback. A path
    /// is mutable and is never proof that the object currently at `name` is the
    /// object this attempt published.
    static func publishTemporaryFile(
        named temporaryName: String,
        temporaryFileDescriptor temporaryFD: Int32,
        expectedTemporaryFile temporaryInfo: stat,
        as name: String,
        relativeTo parentFD: Int32,
        destinationPath: String,
        durabilityIO: any TransferDurabilityIO
    ) throws -> FilePublicationResult {
        let linkResult: (status: Int32, error: Int32) = temporaryName.withCString { temporaryNamePointer in
            name.withCString { namePointer in
                let status = linkat(parentFD, temporaryNamePointer, parentFD, namePointer, 0)
                return (status, status == 0 ? 0 : errno)
            }
        }

        let temporaryIdentity = PublishedFileIdentity(temporaryInfo)
        if linkResult.status == 0 {
            guard nameStillIdentifies(
                temporaryIdentity,
                named: name,
                relativeTo: parentFD
            ) else {
                throw DestinationPublicationFailure.ownershipLost(identity: temporaryIdentity)
            }
            removeItem(named: temporaryName, relativeTo: parentFD)
            return FilePublicationResult(identity: temporaryIdentity, finalFullSync: nil)
        }

        guard linkResult.error == ENOTSUP || linkResult.error == EOPNOTSUPP else {
            throw posixError(
                "Destination file appeared during copy; refusing to overwrite it",
                code: linkResult.error
            )
        }
        return try publishByClaimingNameThenCopying(
            temporaryName: temporaryName,
            temporaryFileDescriptor: temporaryFD,
            expectedTemporaryFile: temporaryInfo,
            as: name,
            relativeTo: parentFD,
            destinationPath: destinationPath,
            durabilityIO: durabilityIO
        )
    }

    /// exFAT/FAT fallback. Once the final name is claimed, failures preserve
    /// both the partial final entry and the verified temporary file. Deleting a
    /// pathname after an identity check would still be a check/unlink race;
    /// leaving recoverable evidence is safer than risking deletion of a
    /// concurrent writer's replacement.
    static func publishByClaimingNameThenCopying(
        temporaryName: String,
        temporaryFileDescriptor temporaryFD: Int32,
        expectedTemporaryFile temporaryInfo: stat,
        as name: String,
        relativeTo parentFD: Int32,
        destinationPath: String,
        durabilityIO: any TransferDurabilityIO
    ) throws -> FilePublicationResult {
        let claimFlags = O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC
        let claimResult: (descriptor: Int32, error: Int32) = name.withCString {
            let descriptor = openat(parentFD, $0, claimFlags, 0o600)
            return (descriptor, descriptor >= 0 ? 0 : errno)
        }
        guard claimResult.descriptor >= 0 else {
            throw posixError(
                "Destination file appeared during copy; refusing to overwrite it",
                code: claimResult.error
            )
        }
        let finalFD = claimResult.descriptor
        defer { _ = Darwin.close(finalFD) }

        var claimedInfo = stat()
        guard fstat(finalFD, &claimedInfo) == 0 else {
            let error = posixError("Unable to inspect newly claimed destination file")
            throw DestinationPublicationFailure.interrupted(
                "Final destination name was claimed, but its identity could not be inspected",
                identity: nil,
                underlying: error
            )
        }
        let claimedIdentity = PublishedFileIdentity(claimedInfo)

        do {
            try durabilityIO.prepareForClaimedPublication(destinationPath: destinationPath)
            try copyVerifiedTemporaryFile(
                descriptor: temporaryFD,
                expected: temporaryInfo,
                into: finalFD
            )

            var times = [temporaryInfo.st_mtimespec, temporaryInfo.st_mtimespec]
            guard futimens(finalFD, &times) == 0 else {
                throw posixError("Unable to preserve final destination modification date")
            }
            guard Darwin.fsync(finalFD) == 0 else {
                throw posixError("Unable to synchronize final destination file")
            }

            let finalFullSync = durabilityIO.fullSync(fileDescriptor: finalFD)
            if case .failed = finalFullSync {
                throw TransferDurabilityError.syscall("final destination F_FULLFSYNC", outcome: finalFullSync)
            }

            var finalInfo = stat()
            guard fstat(finalFD, &finalInfo) == 0 else {
                throw posixError("Unable to inspect final destination file after publication")
            }
            guard claimedIdentity.matches(finalInfo) else {
                throw DestinationPublicationFailure.ownershipLost(identity: claimedIdentity)
            }
            guard Int64(finalInfo.st_size) == Int64(temporaryInfo.st_size) else {
                throw NSError(
                    domain: "BitMatchTransferWorker.PublicationCopy",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Final destination size changed during publication"]
                )
            }
            guard nameStillIdentifies(claimedIdentity, named: name, relativeTo: parentFD) else {
                throw DestinationPublicationFailure.ownershipLost(identity: claimedIdentity)
            }

            removeItem(named: temporaryName, relativeTo: parentFD)
            return FilePublicationResult(identity: claimedIdentity, finalFullSync: finalFullSync)
        } catch let failure as DestinationPublicationFailure {
            throw failure
        } catch {
            throw DestinationPublicationFailure.interrupted(
                "Final destination name was claimed, but publication did not complete",
                identity: claimedIdentity,
                underlying: error
            )
        }
    }

    private static func copyVerifiedTemporaryFile(
        descriptor temporaryFD: Int32,
        expected temporaryInfo: stat,
        into finalFD: Int32
    ) throws {
        var before = stat()
        guard fstat(temporaryFD, &before) == 0,
              PublishedFileIdentity(temporaryInfo).matches(before),
              before.st_size == temporaryInfo.st_size,
              before.st_mtimespec.tv_sec == temporaryInfo.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == temporaryInfo.st_mtimespec.tv_nsec else {
            throw NSError(
                domain: "BitMatchTransferWorker.VerifiedTemporaryFile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Verified temporary file changed before publication"]
            )
        }
        guard Darwin.lseek(temporaryFD, 0, SEEK_SET) == 0 else {
            throw posixError("Unable to seek verified temporary file for publication")
        }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let readCount: Int = try retryingInterruptedSystemCall(
                "Unable to read verified temporary file during publication"
            ) {
                buffer.withUnsafeMutableBytes { Darwin.read(temporaryFD, $0.baseAddress, $0.count) }
            }
            if readCount == 0 { break }

            var written = 0
            while written < readCount {
                let wroteCount: Int = try retryingInterruptedSystemCall(
                    "Unable to write final destination file during publication"
                ) {
                    buffer.withUnsafeBytes { rawBuffer in
                        Darwin.write(finalFD, rawBuffer.baseAddress!.advanced(by: written), readCount - written)
                    }
                }
                guard wroteCount > 0 else {
                    throw posixError("Unable to make progress writing final destination file", code: EIO)
                }
                written += wroteCount
            }
        }

        var after = stat()
        guard fstat(temporaryFD, &after) == 0,
              PublishedFileIdentity(temporaryInfo).matches(after),
              after.st_size == temporaryInfo.st_size,
              after.st_mtimespec.tv_sec == temporaryInfo.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == temporaryInfo.st_mtimespec.tv_nsec else {
            throw NSError(
                domain: "BitMatchTransferWorker.VerifiedTemporaryFile",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Verified temporary file changed during publication"]
            )
        }
    }

    private static func nameStillIdentifies(
        _ expected: PublishedFileIdentity,
        named name: String,
        relativeTo parentFD: Int32
    ) -> Bool {
        let descriptor = name.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && expected.matches(info)
    }

    private static func retryingInterruptedSystemCall<T: FixedWidthInteger>(
        _ message: String,
        operation: () -> T
    ) throws -> T {
        while true {
            let result = operation()
            if result >= 0 { return result }
            let code = errno
            if code == EINTR { continue }
            throw posixError(message, code: code)
        }
    }

    /// Descends from `/` one descriptor at a time so `O_NOFOLLOW` protects
    /// every selected-destination component, not merely the final one.
    private static func openDirectory(at url: URL, description: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let components = descriptorSafePathComponents(for: url)
        guard components.first == "/" else {
            throw FileOperationError.unsafeOperation("\(description) must be an absolute folder")
        }

        var currentFD = "/".withCString { Darwin.open($0, flags) }
        guard currentFD >= 0 else { throw posixError("Unable to open filesystem root") }
        do {
            for component in components.dropFirst() {
                try validate(component: component)
                let childFD = component.withCString { openat(currentFD, $0, flags) }
                guard childFD >= 0 else {
                    if errno == ELOOP || (errno == ENOTDIR && isSymbolicLink(named: component, relativeTo: currentFD)) {
                        throw FileOperationError.unsafeOperation("\(description) contains a symbolic link")
                    }
                    throw posixError("Unable to open \(description) component \(component)")
                }
                _ = Darwin.close(currentFD)
                currentFD = childFD
            }
            return currentFD
        } catch {
            _ = Darwin.close(currentFD)
            throw error
        }
    }

    /// macOS exposes /var, /tmp, and /etc as system-owned aliases beneath
    /// /private. Resolve only those fixed aliases before descriptor traversal;
    /// every user-selected component still uses O_NOFOLLOW and is rejected if
    /// it is a symlink.
    private static func descriptorSafePathComponents(for url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 1,
              ["var", "tmp", "etc"].contains(components[1]) else {
            return components
        }
        return ["/", "private"] + Array(components.dropFirst())
    }

    private static func isSymbolicLink(named name: String, relativeTo directoryFD: Int32) -> Bool {
        var info = stat()
        let status = name.withCString { fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        return status == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func openOrCreateDirectory(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let openExisting = { name.withCString { openat(parentFD, $0, flags) } }
        var fd = openExisting()
        if fd < 0 && errno == ENOENT {
            let created = name.withCString { mkdirat(parentFD, $0, 0o755) }
            if created != 0 && errno != EEXIST { throw posixError("Unable to create destination directory") }
            fd = openExisting()
        }
        guard fd >= 0 else {
            if errno == ELOOP || (errno == ENOTDIR && isSymbolicLink(named: name, relativeTo: parentFD)) {
                throw FileOperationError.unsafeOperation("Destination component \(name) is a symbolic link")
            }
            throw posixError("Unable to open destination directory \(name)")
        }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(fd)
            throw FileOperationError.unsafeOperation("Destination component \(name) is not a folder")
        }
        return fd
    }

    private static func validate(component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/") else {
            throw FileOperationError.unsafeOperation("Invalid destination path component")
        }
    }

    private static func posixError(_ message: String) -> NSError {
        posixError(message, code: errno)
    }

    private static func posixError(_ message: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(code))]
        )
    }
}

/// A regular file opened relative to a pinned directory. It owns a descriptor
/// so symlink swaps of presentation paths cannot redirect checksum or byte
/// verification reads.
final class PinnedDestinationFile: @unchecked Sendable {
    private let fileFD: Int32
    private let parentFD: Int32
    private let name: String

    private init(fileFD: Int32, parentFD: Int32, name: String) {
        self.fileFD = fileFD
        self.parentFD = parentFD
        self.name = name
    }

    deinit {
        _ = Darwin.close(fileFD)
        _ = Darwin.close(parentFD)
    }

    static func open(
        named name: String,
        relativeTo parentFD: Int32,
        expectedIdentity: PublishedFileIdentity? = nil
    ) throws -> PinnedDestinationFile {
        let fileFD = try openRegularFile(named: name, relativeTo: parentFD)
        var openedInfo = stat()
        guard fstat(fileFD, &openedInfo) == 0 else {
            _ = Darwin.close(fileFD)
            throw posixError("Unable to inspect opened destination file")
        }
        if let expectedIdentity, !expectedIdentity.matches(openedInfo) {
            _ = Darwin.close(fileFD)
            throw DestinationPublicationFailure.ownershipLost(identity: expectedIdentity)
        }
        let retainedParentFD = Darwin.dup(parentFD)
        guard retainedParentFD >= 0 else {
            _ = Darwin.close(fileFD)
            throw posixError("Unable to retain pinned destination parent directory")
        }
        return PinnedDestinationFile(fileFD: fileFD, parentFD: retainedParentFD, name: name)
    }

    func snapshot() throws -> stat {
        var info = stat()
        guard fstat(fileFD, &info) == 0 else {
            throw Self.posixError("Unable to inspect pinned destination file")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw FileCopyService.existingDestinationConflictError("Existing destination item is not a regular file")
        }
        return info
    }

    /// A fresh `openat` is required for every reader. `dup` would retain the
    /// same open-file description and its current offset, so a second Thorough
    /// checksum could otherwise start at EOF.
    func readingHandle() throws -> FileHandle {
        let expected = try snapshot()
        let readerFD = try Self.openRegularFile(named: name, relativeTo: parentFD)
        var actual = stat()
        guard fstat(readerFD, &actual) == 0,
              actual.st_dev == expected.st_dev,
              actual.st_ino == expected.st_ino else {
            _ = Darwin.close(readerFD)
            throw DestinationPublicationFailure.ownershipLost(
                identity: PublishedFileIdentity(expected)
            )
        }
        return FileHandle(fileDescriptor: readerFD, closeOnDealloc: true)
    }

    func independentReadingDescriptor() throws -> (descriptor: Int32, expected: stat) {
        let expected = try snapshot()
        let readerFD = try Self.openRegularFile(named: name, relativeTo: parentFD)
        var actual = stat()
        guard fstat(readerFD, &actual) == 0,
              actual.st_dev == expected.st_dev,
              actual.st_ino == expected.st_ino else {
            _ = Darwin.close(readerFD)
            throw DestinationPublicationFailure.ownershipLost(
                identity: PublishedFileIdentity(expected)
            )
        }
        return (readerFD, expected)
    }

    func nameStillIdentifiesThisFile() -> Bool {
        guard let expected = try? snapshot() else { return false }
        let readerFD = name.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard readerFD >= 0 else { return false }
        defer { _ = Darwin.close(readerFD) }
        var actual = stat()
        return fstat(readerFD, &actual) == 0
            && actual.st_dev == expected.st_dev
            && actual.st_ino == expected.st_ino
    }

    private static func openRegularFile(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let fd = name.withCString { openat(parentFD, $0, flags) }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw FileOperationError.unsafeOperation("Destination file \(name) is a symbolic link")
            }
            throw posixError("Unable to open destination file \(name)")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(fd)
            throw FileCopyService.existingDestinationConflictError("Existing destination item is not a regular file")
        }
        return fd
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(errno))])
    }
}
#endif

final class FileCopyService {
    private actor _EnumeratorSource {
        private let fm = FileManager.default
        private let enumerator: FileManager.DirectoryEnumerator?
        init(base: URL) {
            self.enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: []
            )
        }
        func nextRegularFile() -> URL? {
            while let item = enumerator?.nextObject() as? URL {
                if let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    if values.isSymbolicLink == true {
                        continue
                    }
                    if values.isRegularFile == true {
                    return item
                    }
                }
            }
            return nil
        }
    }
    // Perf 1: actor wrapping pre-enumerated file list for concurrent worker access
    private actor _ArraySource {
        private let urls: [URL]
        private var index: Int = 0
        init(_ urls: [URL]) { self.urls = urls }
        func next() -> URL? {
            guard index < urls.count else { return nil }
            defer { index += 1 }
            return urls[index]
        }
    }
    static func copyAllSafely(
        from src: URL,
        toRoot dstRoot: URL,
        verificationMode: VerificationMode,
        workers: Int,
        preEnumeratedFiles: [URL]? = nil,
        pauseCheck: (@Sendable () async throws -> Void)? = nil,
        onProgress: @escaping (String, Int64) async -> Void,
        onError: @escaping (String, Error) async -> Void
    ) async throws {
        let fm = FileManager.default
        var dstRootIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: dstRoot.path, isDirectory: &dstRootIsDirectory) {
            guard dstRootIsDirectory.boolValue else {
                throw NSError(
                    domain: "FileCopyService",
                    code: NSFileWriteFileExistsError,
                    userInfo: [NSLocalizedDescriptionKey: "Destination root exists and is not a folder"]
                )
            }
        } else {
            try fm.createDirectory(at: dstRoot, withIntermediateDirectories: true, attributes: nil)
        }

        try await createDirectoryTreeSafely(from: src, toRoot: dstRoot, onError: onError)
        let sourceResolver = RelativePathResolver(base: src)

        // Streaming copy with bounded concurrency
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Perf 1: use pre-enumerated files when available to avoid redundant filesystem walk
            let nextFile: @Sendable () async -> URL?
            if let preFiles = preEnumeratedFiles {
                let arraySource = _ArraySource(preFiles)
                nextFile = { await arraySource.next() }
            } else {
                let enumSource = _EnumeratorSource(base: src)
                nextFile = { await enumSource.nextRegularFile() }
            }
            let workerCount = max(1, workers)
            for _ in 0..<workerCount {
                group.addTask {
                    let fm = FileManager.default
                    while true {
                        try Task.checkCancellation()
                        if let pauseCheck = pauseCheck {
                            try await pauseCheck()
                        }
                        guard let fileURL = await nextFile() else { break }
                        // Compute relative path before do block so it's available in catch.
                        // A file that cannot be placed below `src` is reported, never
                        // flattened to its bare name.
                        let relPath: String
                        do {
                            relPath = try sourceResolver.resolve(fileURL)
                        } catch {
                            await onError(fileURL.path, error)
                            continue
                        }
                        // Security 11: reject path traversal components
                        if relPath.split(separator: "/").contains("..") {
                            await onError(relPath, NSError(
                                domain: "FileCopyService",
                                code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "Path contains traversal component (..)"]
                            ))
                            continue
                        }
                        // Security 11: verify resolved source is under source root
                        let resolvedSource = fileURL.resolvingSymlinksInPath()
                        let resolvedSrcRoot = src.resolvingSymlinksInPath()
                        guard Self.pathIsWithin(resolvedSource.path, root: resolvedSrcRoot.path) else {
                            await onError(relPath, NSError(
                                domain: "FileCopyService",
                                code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "Source file resolves outside source directory"]
                            ))
                            continue
                        }
                        do {
                            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                            let dstURL = dstRoot.appendingPathComponent(relPath)
                            let parentDir = dstURL.deletingLastPathComponent()
                            // Security: Resolve symlinks in destination path to prevent writes outside intended directory
                            let realParentDirURL = parentDir.standardized.resolvingSymlinksInPath()
                            let realDstRootURL = dstRoot.standardized.resolvingSymlinksInPath()

                            guard Self.pathIsWithin(realParentDirURL.path, root: realDstRootURL.path) else {
                                await onError(relPath, NSError(
                                    domain: "FileCopyService",
                                    code: NSFileWriteNoPermissionError,
                                    userInfo: [NSLocalizedDescriptionKey: "Destination path escapes root directory"]
                                ))
                                continue
                            }
                            if !fm.fileExists(atPath: parentDir.path) {
                                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                            }
                            let resolvedParentAfterCreate = parentDir.standardized.resolvingSymlinksInPath()
                            guard Self.pathIsWithin(resolvedParentAfterCreate.path, root: realDstRootURL.path) else {
                                await onError(relPath, NSError(
                                    domain: "FileCopyService",
                                    code: NSFileWriteNoPermissionError,
                                    userInfo: [NSLocalizedDescriptionKey: "Destination directory changed while preparing copy"]
                                ))
                                continue
                            }
                            let sourceSize = Int64(resourceValues.fileSize ?? 0)
                            if fm.fileExists(atPath: dstURL.path) {
                                let shouldReuseExisting = try await Self.canReuseExistingDestinationFile(
                                    source: fileURL,
                                    destination: dstURL,
                                    sourceSize: sourceSize,
                                    verificationMode: verificationMode
                                )
                                if shouldReuseExisting {
                                    await onProgress(relPath, sourceSize)
                                    continue
                                }
                            }
                            try await copyFileSecurely(from: fileURL, to: dstURL, pauseCheck: pauseCheck)
                            await onProgress(relPath, sourceSize)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await onError(relPath, error)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    #if canImport(Darwin)
    /// Descriptor-pinned variant for local destinations. The pathname is used
    /// only for display/reporting; directory creation and publication stay on
    /// the directory descriptor owned by `pinnedRoot`.
    static func copyAllSafely(
        from src: URL,
        toPinnedRoot pinnedRoot: PinnedDestinationDirectory,
        verificationMode: VerificationMode,
        workers: Int,
        checksumService: any ChecksumService,
        durabilityIO: (any TransferDurabilityIO)? = nil,
        durabilityRecorder: (any TransferDurabilityRecorder)? = nil,
        preEnumeratedFiles: [URL]? = nil,
        pauseCheck: (@Sendable () async throws -> Void)? = nil,
        onProgress: @escaping (String, Int64) async -> Void,
        onError: @escaping (String, Error) async -> Void
    ) async throws {
        try await createDirectoryTreeSafely(from: src, in: pinnedRoot, onError: onError)
        let sourceResolver = RelativePathResolver(base: src)

        try await withThrowingTaskGroup(of: Void.self) { group in
            let nextFile: @Sendable () async -> URL?
            if let preEnumeratedFiles {
                let arraySource = _ArraySource(preEnumeratedFiles)
                nextFile = { await arraySource.next() }
            } else {
                let enumerator = _EnumeratorSource(base: src)
                nextFile = { await enumerator.nextRegularFile() }
            }

            for _ in 0..<max(1, workers) {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        if let pauseCheck { try await pauseCheck() }
                        guard let fileURL = await nextFile() else { break }
                        let relativePath: String
                        do {
                            relativePath = try sourceResolver.resolve(fileURL)
                        } catch {
                            await onError(fileURL.path, error)
                            continue
                        }
                        guard let components = safeRelativeComponents(relativePath) else {
                            await onError(relativePath, NSError(
                                domain: "FileCopyService",
                                code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "Path contains traversal component"]
                            ))
                            continue
                        }

                        let resolvedSource = fileURL.resolvingSymlinksInPath()
                        guard pathIsWithin(resolvedSource.path, root: src.resolvingSymlinksInPath().path) else {
                            await onError(relativePath, NSError(
                                domain: "FileCopyService",
                                code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "Source file resolves outside source directory"]
                            ))
                            continue
                        }

                        do {
                            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                            let parentFD = try pinnedRoot.openOrCreateDirectory(at: Array(components.dropLast()))
                            defer { _ = Darwin.close(parentFD) }
                            let filename = components[components.count - 1]
                            let sourceSize = Int64(values.fileSize ?? 0)
                            if try PinnedDestinationDirectory.isExistingRegularFile(named: filename, relativeTo: parentFD) {
                                let destinationFile = try PinnedDestinationFile.open(named: filename, relativeTo: parentFD)
                                if try await canReuseExistingDestinationFile(
                                    source: fileURL,
                                    destination: destinationFile,
                                    sourceSize: sourceSize,
                                    verificationMode: verificationMode,
                                    checksumService: checksumService
                                ) {
                                    durabilityRecorder?.recordCopyFacts(
                                        TransferCopyDurabilityFacts(
                                            reusedExistingDestination: true,
                                            sourceRemainedStable: true
                                        ),
                                        destinationPath: pinnedRoot.destinationURL(for: relativePath).path
                                    )
                                    await onProgress(relativePath, sourceSize)
                                    continue
                                }
                            }
                            try await copyFileSecurely(
                                from: fileURL,
                                toPinnedParent: parentFD,
                                filename: filename,
                                destinationPath: pinnedRoot.destinationURL(for: relativePath).path,
                                durabilityIO: durabilityIO,
                                durabilityRecorder: durabilityRecorder,
                                pauseCheck: pauseCheck
                            )
                            await onProgress(relativePath, sourceSize)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await onError(relativePath, error)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
    #endif

    private static func copyFileSecurely(
        from source: URL,
        to destination: URL,
        pauseCheck: (@Sendable () async throws -> Void)?
    ) async throws {
        let fm = FileManager.default
        let srcHandle = try FileHandle(forReadingFrom: source)
        defer { closeFileHandle(srcHandle, context: source.path) }
        let tempName = ".bitmatch.tmp." + UUID().uuidString
        let tempURL = destination.deletingLastPathComponent().appendingPathComponent(tempName)
        // Security 12: set restrictive permissions on temp files
        fm.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let dstHandle = FileHandle(forWritingAtPath: tempURL.path) else {
            removeTempItemIfPresent(at: tempURL)
            throw NSError(domain: "FileCopyService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to open temp destination for writing"])
        }
        var replaceSucceeded = false
        defer {
            closeFileHandle(dstHandle, context: tempURL.path)
            if !replaceSucceeded { removeTempItemIfPresent(at: tempURL) }
        }
        let bufferSize = 4 * 1024 * 1024 // Perf 3: 4MB chunk for better throughput
        // Get source attributes at START - captures original state before any race conditions
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let sourceModificationDate = sourceAttributes[.modificationDate] as? Date
        let sourceIdentity = fileIdentity(from: sourceAttributes)
        let logInterval: Int64 = 512 * 1024 * 1024
        var bytesCopied: Int64 = 0
        var nextLogMark = logInterval
        let shouldLog = sourceSize >= logInterval
        let sizeFormatter = ByteCountFormatter()
        sizeFormatter.countStyle = .file
        if shouldLog {
            Self.logMemoryUsage(context: "start copy \(source.lastPathComponent)")
        }
        var reachedEOF = false
        while !reachedEOF {
            try Task.checkCancellation()
            if let pauseCheck = pauseCheck {
                try await pauseCheck()
            }
            var localError: Error?
            var chunkSize: Int = 0
            // Autorelease scope keeps chunk Data from piling up on massive transfers
            autoreleasepool {
                do {
                    guard let data = try srcHandle.read(upToCount: bufferSize), !data.isEmpty else {
                        reachedEOF = true
                        return
                    }
                    chunkSize = data.count
                    try dstHandle.write(contentsOf: data)
                } catch {
                    localError = error
                    reachedEOF = true
                }
            }
            if let error = localError {
                throw error
            }
            if chunkSize == 0 {
                break
            }
            bytesCopied += Int64(chunkSize)
            if shouldLog, bytesCopied >= nextLogMark {
                let copiedString = sizeFormatter.string(fromByteCount: bytesCopied)
                let totalString = sizeFormatter.string(fromByteCount: sourceSize)
                Self.logMemoryUsage(context: "\(source.lastPathComponent) – \(copiedString)/\(totalString)")
                nextLogMark += logInterval
            }
        }
        #if compiler(>=5.7)
        if #available(iOS 16.0, macOS 13.0, *) {
            do {
                try dstHandle.synchronize()
            } catch {
                throw NSError(
                    domain: "FileCopyService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to flush destination file: \(error.localizedDescription)"]
                )
            }
        } else {
            dstHandle.synchronizeFile()
        }
        #else
        dstHandle.synchronizeFile()
        #endif
        let tempAttributes = try fm.attributesOfItem(atPath: tempURL.path)
        let tempSize = (tempAttributes[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize == tempSize else {
            throw NSError(domain: "FileCopyService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Size mismatch after copy"])
        }

        let finalSourceAttributes = try fm.attributesOfItem(atPath: source.path)
        guard sourceRemainedStable(
            initialSize: sourceSize,
            initialModificationDate: sourceModificationDate,
            initialIdentity: sourceIdentity,
            finalAttributes: finalSourceAttributes
        ) else {
            throw NSError(
                domain: "FileCopyService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Source file changed during copy; destination was not modified"]
            )
        }

        guard !fm.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "FileCopyService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Destination file appeared during copy; refusing to overwrite it"]
            )
        }

        // Publish only when the final path is still empty. moveItem refuses to
        // replace an existing file, so a race creates a copy error instead of
        // clobbering someone else's destination item.
        try fm.moveItem(at: tempURL, to: destination)
        replaceSucceeded = true

        // Restore original modification time from source file
        // This is critical for quick-mode resume to work correctly (mtime comparison)
        // Using try? so metadata failure doesn't fail an otherwise successful copy
        if let modDate = sourceModificationDate {
            do {
                try fm.setAttributes([.modificationDate: modDate], ofItemAtPath: destination.path)
            } catch {
                SharedLogger.warning("Failed to restore modification date on \(destination.path): \(error)", category: .transfer)
            }
        }

        if shouldLog {
            Self.logMemoryUsage(context: "completed \(destination.lastPathComponent)")
        }
    }

    #if canImport(Darwin)
    private static func copyFileSecurely(
        from source: URL,
        toPinnedParent parentFD: Int32,
        filename: String,
        destinationPath: String,
        durabilityIO: (any TransferDurabilityIO)?,
        durabilityRecorder: (any TransferDurabilityRecorder)?,
        pauseCheck: (@Sendable () async throws -> Void)?
    ) async throws {
        let sourceFD = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard sourceFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to open source read-only"])
        }
        let sourceHandle = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: false)
        defer { closeFileHandle(sourceHandle, context: source.path) }

        let temporaryName = ".bitmatch.tmp." + UUID().uuidString
        let temporaryFD = try PinnedDestinationDirectory.createTemporaryFile(named: temporaryName, relativeTo: parentFD)
        let destinationHandle = FileHandle(fileDescriptor: temporaryFD, closeOnDealloc: false)
        var published = false
        var destinationClosed = false
        var preserveTemporaryForRecovery = false
        defer {
            if !destinationClosed {
                closeFileHandle(destinationHandle, context: temporaryName)
            }
            if !published && !preserveTemporaryForRecovery {
                PinnedDestinationDirectory.removeItem(named: temporaryName, relativeTo: parentFD)
            }
        }

        var sourceInitial = stat()
        guard fstat(sourceFD, &sourceInitial) == 0, (sourceInitial.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to inspect opened source file"])
        }
        let sourceSize = Int64(sourceInitial.st_size)
        let sourceModificationDate: Date? = Date(
            timeIntervalSince1970: TimeInterval(sourceInitial.st_mtimespec.tv_sec)
                + TimeInterval(sourceInitial.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        var reachedEOF = false
        var copiedSourceHasher = SHA256()
        while !reachedEOF {
            try Task.checkCancellation()
            if let pauseCheck { try await pauseCheck() }
            let data = try sourceHandle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty {
                reachedEOF = true
            } else {
                try destinationHandle.write(contentsOf: data)
                if durabilityIO != nil { copiedSourceHasher.update(data: data) }
            }
        }

        // Preserve the requested final-file metadata before synchronization so
        // the ordinary flush and F_FULLFSYNC facts describe the exact temp-file
        // state that will be published, including its modification time.
        if let sourceModificationDate {
            var times = [timespec(tv_sec: Int(sourceModificationDate.timeIntervalSince1970), tv_nsec: 0),
                         timespec(tv_sec: Int(sourceModificationDate.timeIntervalSince1970), tv_nsec: 0)]
            if futimens(temporaryFD, &times) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to preserve destination modification date"])
            }
        }
        #if compiler(>=5.7)
        if #available(iOS 16.0, macOS 13.0, *) {
            try destinationHandle.synchronize()
        } else {
            destinationHandle.synchronizeFile()
        }
        #else
        destinationHandle.synchronizeFile()
        #endif

        var durabilityFacts = TransferCopyDurabilityFacts(ordinaryFlushSucceeded: true)
        if durabilityIO != nil {
            durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
        }
        if durabilityIO != nil {
            guard Darwin.lseek(temporaryFD, 0, SEEK_SET) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to seek temporary destination for pre-publication verification"])
            }
            var temporaryHasher = SHA256()
            var verifiedBytes: Int64 = 0
            while verifiedBytes < sourceSize {
                let data = try readDescriptor(
                    temporaryFD,
                    maximumCount: Int(min(Int64(1024 * 1024), sourceSize - verifiedBytes))
                )
                guard !data.isEmpty else {
                    throw NSError(domain: "BitMatchTransferWorker.Readback", code: -5, userInfo: [NSLocalizedDescriptionKey: "Short temporary destination read before publication"])
                }
                temporaryHasher.update(data: data)
                verifiedBytes += Int64(data.count)
            }
            guard copiedSourceHasher.finalize() == temporaryHasher.finalize() else {
                throw NSError(domain: "BitMatchTransferWorker.Readback", code: -6, userInfo: [NSLocalizedDescriptionKey: "Temporary destination checksum mismatch before publication"])
            }
            durabilityFacts.prePublicationChecksumMatched = true
            durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
        }

        var sourceFinal = stat()
        guard fstat(sourceFD, &sourceFinal) == 0,
              pinnedFileRemainedStable(sourceInitial, sourceFinal) else {
            throw NSError(domain: "FileCopyService", code: -4, userInfo: [NSLocalizedDescriptionKey: "Source file changed during copy; destination was not modified"])
        }
        durabilityFacts.sourceRemainedStable = true
        durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)

        if let durabilityIO {
            // This stronger request follows all file-data and preserved-mtime
            // mutations, so its fact applies to the exact inode state that is
            // about to be published. It is still not proof of physical-media
            // persistence across the complete storage stack.
            let fullSync = durabilityIO.fullSync(fileDescriptor: temporaryFD)
            durabilityFacts.fullSync = fullSync
            durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
            if case .failed = fullSync {
                throw TransferDurabilityError.syscall("F_FULLFSYNC", outcome: fullSync)
            }
        }

        var temporaryInfo = stat()
        guard fstat(temporaryFD, &temporaryInfo) == 0,
              Int64(temporaryInfo.st_size) == sourceSize else {
            throw NSError(domain: "FileCopyService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Size mismatch after copy"])
        }

        let publicationDurabilityIO: any TransferDurabilityIO = durabilityIO ?? DarwinTransferDurabilityIO()
        try publicationDurabilityIO.prepareForPublication(destinationPath: destinationPath)
        let publication: FilePublicationResult
        do {
            publication = try PinnedDestinationDirectory.publishTemporaryFile(
                named: temporaryName,
                temporaryFileDescriptor: temporaryFD,
                expectedTemporaryFile: temporaryInfo,
                as: filename,
                relativeTo: parentFD,
                destinationPath: destinationPath,
                durabilityIO: publicationDurabilityIO
            )
        } catch let failure as DestinationPublicationFailure {
            preserveTemporaryForRecovery = failure.finalNameWasClaimed
            durabilityFacts.publicationInterrupted = failure.finalNameWasClaimed
            durabilityFacts.publicationIdentity = failure.claimedIdentity
            durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
            throw failure
        }
        if let finalFullSync = publication.finalFullSync {
            durabilityFacts.fullSync = finalFullSync
        }
        durabilityFacts.publicationIdentity = publication.identity
        durabilityFacts.publicationSucceeded = true
        if let durabilityIO {
            let directorySync = durabilityIO.syncDirectory(fileDescriptor: parentFD)
            durabilityFacts.directorySync = directorySync
            durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
            if case .failed = directorySync {
                // Publication is now ambiguous. Preserve the final entry rather
                // than racing a concurrent replacement with check-then-unlink.
                durabilityFacts.publicationInterrupted = true
                durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
                throw TransferDurabilityError.syscall("destination directory fsync", outcome: directorySync)
            }
        }
        published = true
        try destinationHandle.close()
        destinationClosed = true
        durabilityRecorder?.recordCopyFacts(durabilityFacts, destinationPath: destinationPath)
    }
    #endif

    private static func createDirectoryTreeSafely(
        from sourceRoot: URL,
        toRoot destinationRoot: URL,
        onError: @escaping (String, Error) async -> Void
    ) async throws {
        let fm = FileManager.default
        let resolver = RelativePathResolver(base: sourceRoot)
        let destinationRootPath = destinationRoot.standardized.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        guard let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else {
                continue
            }
            if enumerator.level == 1,
               FileTreeEnumerator.skippedVolumeMetadataDirectories.contains(item.lastPathComponent) {
                // Mirrors the manifest: root-level volume metadata is neither
                // copied nor recreated as an empty folder on the destination.
                enumerator.skipDescendants()
                continue
            }

            let relPath: String
            do {
                relPath = try resolver.resolve(item)
            } catch {
                await onError(item.path, error)
                continue
            }

            guard !relPath.split(separator: "/").contains("..") else {
                await onError(relPath, NSError(
                    domain: "FileCopyService",
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: "Directory path contains traversal component (..)"]
                ))
                continue
            }

            let destinationDirectory = destinationRoot.appendingPathComponent(relPath, isDirectory: true)
            let resolvedDestination = destinationDirectory.standardized.resolvingSymlinksInPath()
            guard pathIsWithin(resolvedDestination.path, root: destinationRootPath) else {
                await onError(relPath, NSError(
                    domain: "FileCopyService",
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: "Destination directory escapes root directory"]
                ))
                continue
            }

            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    await onError(relPath, existingDestinationConflictError("Existing destination item conflicts with source directory"))
                }
                continue
            }

            do {
                try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                await onError(relPath, error)
            }
        }
    }

    #if canImport(Darwin)
    private static func createDirectoryTreeSafely(
        from sourceRoot: URL,
        in pinnedRoot: PinnedDestinationDirectory,
        onError: @escaping (String, Error) async -> Void
    ) async throws {
        let fm = FileManager.default
        let resolver = RelativePathResolver(base: sourceRoot)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else { continue }
            if enumerator.level == 1,
               FileTreeEnumerator.skippedVolumeMetadataDirectories.contains(item.lastPathComponent) {
                // Mirrors the manifest: root-level volume metadata is neither
                // copied nor recreated as an empty folder on the destination.
                enumerator.skipDescendants()
                continue
            }
            let relative: String
            do {
                relative = try resolver.resolve(item)
            } catch {
                await onError(item.path, error)
                continue
            }
            guard let components = safeRelativeComponents(relative) else {
                await onError(relative, NSError(
                    domain: "FileCopyService",
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: "Directory path contains traversal component"]
                ))
                continue
            }
            do {
                let fd = try pinnedRoot.openOrCreateDirectory(at: components)
                _ = Darwin.close(fd)
            } catch {
                await onError(relative, error)
            }
        }
    }
    #endif

    private static func safeRelativeComponents(_ relativePath: String) -> [String]? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            return nil
        }
        return components
    }

    private static func closeFileHandle(_ handle: FileHandle, context: String) {
        do {
            try handle.close()
        } catch {
            SharedLogger.warning("Failed to close file handle for \(context): \(error)", category: .transfer)
        }
    }

    private static func removeTempItemIfPresent(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            SharedLogger.warning("Failed to remove temp file at \(url.path): \(error)", category: .transfer)
        }
    }

    private static func canReuseExistingDestinationFile(
        source: URL,
        destination: URL,
        sourceSize: Int64,
        verificationMode: VerificationMode
    ) async throws -> Bool {
        let fm = FileManager.default
        let destinationValues = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard destinationValues.isSymbolicLink != true, destinationValues.isRegularFile == true else {
            throw existingDestinationConflictError("Existing destination item is not a regular file")
        }

        let destAttributes = try fm.attributesOfItem(atPath: destination.path)
        let destSize = (destAttributes[.size] as? NSNumber)?.int64Value ?? -1
        guard destSize == sourceSize else {
            throw existingDestinationConflictError("Existing destination file differs in size")
        }

        if verificationMode == .quick {
            throw existingDestinationConflictError(
                "Quick mode cannot prove an existing destination file matches; choose Standard verification or an empty destination"
            )
        }

        guard try await checksumsMatch(
            source: source,
            destination: destination,
            verificationMode: verificationMode
        ) else {
            throw existingDestinationConflictError("Existing destination file checksum differs; refusing to overwrite it")
        }

        return true
    }

    #if canImport(Darwin)
    private static func canReuseExistingDestinationFile(
        source: URL,
        destination: PinnedDestinationFile,
        sourceSize: Int64,
        verificationMode: VerificationMode,
        checksumService: any ChecksumService
    ) async throws -> Bool {
        let destinationInfo = try destination.snapshot()
        guard Int64(destinationInfo.st_size) == sourceSize else {
            throw existingDestinationConflictError("Existing destination file differs in size")
        }

        if verificationMode == .quick {
            throw existingDestinationConflictError(
                "Quick mode cannot prove an existing destination file matches; choose Standard verification or an empty destination"
            )
        }

        guard try await checksumsMatch(
            source: source,
            pinnedDestination: destination,
            verificationMode: verificationMode,
            checksumService: checksumService
        ) else {
            throw existingDestinationConflictError("Existing destination file checksum differs; refusing to overwrite it")
        }

        return true
    }

    /// Verifies a destination file by opening it below `pinnedRoot`. The URL
    /// returned to callers remains presentation metadata; no destination read
    /// follows that URL after the directory has been pinned.
    ///
    /// The destination side of every checksum comparison always reads
    /// through the pinned, descriptor-relative handle (`pinnedDestinationChecksum`),
    /// in every verification mode including `.standard`/`.quick`, so the
    /// TOCTOU protection the pinned-reads hardening added is never bypassed.
    /// Only the SOURCE digest is computed through the caller-supplied
    /// `checksumService`, so the operation's injected checksum dependency is
    /// actually exercised (this is also what lets tests observe and control
    /// verification timing/cancellation) without ever reading the
    /// destination by path.
    static func verifyPinnedDestinationFile(
        source: URL,
        pinnedRoot: PinnedDestinationDirectory,
        relativePath: String,
        verificationMode: VerificationMode,
        checksumService: any ChecksumService,
        durabilityIO: (any TransferDurabilityIO)? = nil,
        durabilityRecorder: (any TransferDurabilityRecorder)? = nil
    ) async throws -> VerificationResult {
        guard let components = safeRelativeComponents(relativePath) else {
            throw FileOperationError.unsafeOperation("Invalid destination file path")
        }
        let destinationPath = pinnedRoot.destinationURL(for: relativePath).path
        let copyFacts = durabilityRecorder?.copyFacts(destinationPath: destinationPath)
        let expectedIdentity: PublishedFileIdentity?
        if copyFacts?.publicationSucceeded == true,
           copyFacts?.reusedExistingDestination == false {
            guard let recordedIdentity = copyFacts?.publicationIdentity else {
                throw NSError(
                    domain: DestinationPublicationFailure.errorDomain,
                    code: DestinationPublicationFailure.Kind.ownershipLost.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Published destination identity is missing"]
                )
            }
            expectedIdentity = recordedIdentity
        } else {
            expectedIdentity = nil
        }
        let destination = try pinnedRoot.openRegularFile(
            at: components,
            expectedIdentity: expectedIdentity
        )
        let startTime = Date()

        if verificationMode == .standard, let durabilityIO {
            return try await durableSHA256Verification(
                source: source,
                destination: destination,
                destinationPath: destinationPath,
                durabilityIO: durabilityIO,
                durabilityRecorder: durabilityRecorder
            )
        }

        if verificationMode == .paranoid {
            let matches = try await byteComparison(source: source, pinnedDestination: destination)
            // Paranoid mode still byte-compares through the pinned handle,
            // and also computes a real SHA-256 digest (source via the
            // injected checksum service, destination via the pinned handle)
            // so MHL files carry a usable checksum instead of a
            // "byte-comparison" placeholder.
            let digest = try await checksumVerification(
                source: source,
                pinnedDestination: destination,
                type: .sha256,
                checksumService: checksumService
            )
            return VerificationResult(
                sourceChecksum: digest.sourceChecksum,
                destinationChecksum: digest.destinationChecksum,
                matches: matches,
                checksumType: .sha256,
                processingTime: Date().timeIntervalSince(startTime),
                fileSize: digest.fileSize
            )
        }

        let checksumTypes = verificationMode.checksumTypes
        guard !checksumTypes.isEmpty else {
            throw FileOperationError.unsafeOperation("Verification mode does not provide a checksum")
        }
        var combinedMatches = true
        var firstResult: VerificationResult?
        var primaryResult: VerificationResult?
        var totalProcessing: TimeInterval = 0
        for type in checksumTypes {
            let result = try await checksumVerification(
                source: source,
                pinnedDestination: destination,
                type: type,
                checksumService: checksumService
            )
            combinedMatches = combinedMatches && result.matches
            totalProcessing += result.processingTime
            if firstResult == nil { firstResult = result }
            if type == .sha256 { primaryResult = result }
        }
        guard let base = primaryResult ?? firstResult else {
            throw FileOperationError.unsafeOperation("Verification mode does not provide a checksum")
        }
        return VerificationResult(
            sourceChecksum: base.sourceChecksum,
            destinationChecksum: base.destinationChecksum,
            matches: combinedMatches,
            checksumType: base.checksumType,
            processingTime: totalProcessing,
            fileSize: base.fileSize
        )
    }

    private static func durableSHA256Verification(
        source: URL,
        destination: PinnedDestinationFile,
        destinationPath: String,
        durabilityIO: any TransferDurabilityIO,
        durabilityRecorder: (any TransferDurabilityRecorder)?
    ) async throws -> VerificationResult {
        let startedAt = Date()
        try durabilityIO.prepareForSourceVerification(sourcePath: source.path)
        let sourceFD = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard sourceFD >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Unable to reopen source read-only for verification"]
            )
        }
        defer { _ = Darwin.close(sourceFD) }

        var sourceInitial = stat()
        guard fstat(sourceFD, &sourceInitial) == 0, (sourceInitial.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "BitMatchTransferWorker.Readback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to inspect opened source file"])
        }

        var sourceHasher = SHA256()
        var sourceBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try readDescriptor(sourceFD, maximumCount: 1024 * 1024)
            if data.isEmpty { break }
            sourceHasher.update(data: data)
            sourceBytes += Int64(data.count)
        }

        var sourceFinal = stat()
        guard fstat(sourceFD, &sourceFinal) == 0,
              sourceBytes == Int64(sourceInitial.st_size),
              pinnedFileRemainedStable(sourceInitial, sourceFinal) else {
            throw NSError(
                domain: "BitMatchTransferWorker.Readback",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Source file changed during verification read"]
            )
        }

        let openedDestination = try destination.independentReadingDescriptor()
        let destinationFD = openedDestination.descriptor
        defer { _ = Darwin.close(destinationFD) }
        var facts = TransferReadbackFacts(sourceRemainedStable: true)
        let cacheBypass = durabilityIO.requestCacheBypass(fileDescriptor: destinationFD)
        facts.cacheBypass = cacheBypass
        durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)
        if case .failed = cacheBypass {
            throw TransferDurabilityError.syscall("F_NOCACHE readback request", outcome: cacheBypass)
        }

        var destinationHasher = SHA256()
        while facts.bytesRead < Int64(openedDestination.expected.st_size) {
            try Task.checkCancellation()
            if let pauseCheck = SharedChecksumService.pauseCheck { try await pauseCheck() }
            let remaining = Int64(openedDestination.expected.st_size) - facts.bytesRead
            let data = try durabilityIO.readDestination(
                fileDescriptor: destinationFD,
                maximumCount: Int(min(Int64(1024 * 1024), remaining))
            )
            guard !data.isEmpty else {
                durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)
                throw NSError(
                    domain: "BitMatchTransferWorker.Readback",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Short destination readback: expected \(openedDestination.expected.st_size) bytes, read \(facts.bytesRead)"]
                )
            }
            destinationHasher.update(data: data)
            facts.bytesRead += Int64(data.count)
        }
        let trailing = try durabilityIO.readDestination(fileDescriptor: destinationFD, maximumCount: 1)
        var destinationFinal = stat()
        guard trailing.isEmpty,
              fstat(destinationFD, &destinationFinal) == 0,
              pinnedFileRemainedStable(openedDestination.expected, destinationFinal) else {
            durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)
            throw NSError(
                domain: "BitMatchTransferWorker.Readback",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Destination changed during full readback"]
            )
        }
        guard destination.nameStillIdentifiesThisFile() else {
            throw DestinationPublicationFailure.ownershipLost(
                identity: PublishedFileIdentity(openedDestination.expected)
            )
        }
        facts.fullReadPerformed = true
        durabilityRecorder?.recordReadbackFacts(facts, destinationPath: destinationPath)

        let sourceChecksum = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let destinationChecksum = destinationHasher.finalize().map { String(format: "%02x", $0) }.joined()
        return VerificationResult(
            sourceChecksum: sourceChecksum,
            destinationChecksum: destinationChecksum,
            matches: sourceChecksum == destinationChecksum,
            checksumType: .sha256,
            processingTime: Date().timeIntervalSince(startedAt),
            fileSize: Int64(sourceInitial.st_size)
        )
    }

    private static func readDescriptor(_ fileDescriptor: Int32, maximumCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = Darwin.read(fileDescriptor, &buffer, maximumCount)
        guard count >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Source read failed: " + String(cString: strerror(errno))]
            )
        }
        return Data(buffer.prefix(count))
    }

    private static func checksumsMatch(
        source: URL,
        pinnedDestination: PinnedDestinationFile,
        verificationMode: VerificationMode,
        checksumService: any ChecksumService
    ) async throws -> Bool {
        let types = verificationMode.checksumTypes
        guard !types.isEmpty else { return false }
        for type in types {
            let result = try await checksumVerification(
                source: source,
                pinnedDestination: pinnedDestination,
                type: type,
                checksumService: checksumService
            )
            if !result.matches { return false }
        }
        return true
    }

    /// Destination digest always comes from the pinned, descriptor-relative
    /// handle. Only the source digest is routed through the injected
    /// `ChecksumService`.
    private static func checksumVerification(
        source: URL,
        pinnedDestination: PinnedDestinationFile,
        type: ChecksumAlgorithm,
        checksumService: any ChecksumService
    ) async throws -> VerificationResult {
        let startTime = Date()
        let sourceChecksum = try await checksumService.generateChecksum(
            for: source,
            type: type,
            useCache: false,
            progressCallback: nil
        )
        let destinationChecksum = try await pinnedDestinationChecksum(pinnedDestination, type: type)
        return VerificationResult(
            sourceChecksum: sourceChecksum,
            destinationChecksum: destinationChecksum,
            matches: sourceChecksum.caseInsensitiveCompare(destinationChecksum) == .orderedSame,
            checksumType: type,
            processingTime: Date().timeIntervalSince(startTime),
            fileSize: try sourceFileSize(source)
        )
    }

    private static func pinnedDestinationChecksum(
        _ destination: PinnedDestinationFile,
        type: ChecksumAlgorithm
    ) async throws -> String {
        switch type {
        case .md5:
            var hasher = Insecure.MD5()
            try await readPinnedDestination(destination) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var hasher = Insecure.SHA1()
            try await readPinnedDestination(destination) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var hasher = SHA256()
            try await readPinnedDestination(destination) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func readPinnedDestination(
        _ destination: PinnedDestinationFile,
        consume: (Data) -> Void
    ) async throws {
        let initial = try destination.snapshot()
        let handle = try destination.readingHandle()
        defer { closeFileHandle(handle, context: "pinned destination") }
        var bytesRead: Int64 = 0
        while true {
            try Task.checkCancellation()
            if let pauseCheck = SharedChecksumService.pauseCheck { try await pauseCheck() }
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            consume(data)
            bytesRead += Int64(data.count)
        }
        let final = try destination.snapshot()
        guard bytesRead == Int64(initial.st_size), pinnedFileRemainedStable(initial, final) else {
            throw NSError(
                domain: "FileCopyService",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Pinned destination file changed while reading"]
            )
        }
    }

    private static func byteComparison(source: URL, pinnedDestination: PinnedDestinationFile) async throws -> Bool {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? -1
        let sourceIdentity = fileIdentity(from: sourceAttributes)
        let sourceModificationDate = sourceAttributes[.modificationDate] as? Date
        let destinationInitial = try pinnedDestination.snapshot()
        guard sourceSize == Int64(destinationInitial.st_size) else { return false }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        let destinationHandle = try pinnedDestination.readingHandle()
        defer {
            closeFileHandle(sourceHandle, context: source.path)
            closeFileHandle(destinationHandle, context: "pinned destination")
        }

        var bytesRead: Int64 = 0
        while bytesRead < sourceSize {
            try Task.checkCancellation()
            if let pauseCheck = SharedChecksumService.pauseCheck { try await pauseCheck() }
            let sourceData = try sourceHandle.read(upToCount: 64 * 1024) ?? Data()
            let destinationData = try destinationHandle.read(upToCount: 64 * 1024) ?? Data()
            guard !sourceData.isEmpty, !destinationData.isEmpty else {
                throw NSError(domain: "FileCopyService", code: -11, userInfo: [NSLocalizedDescriptionKey: "File changed while comparing bytes"])
            }
            if sourceData != destinationData { return false }
            bytesRead += Int64(sourceData.count)
        }

        let sourceTrailingData = try sourceHandle.read(upToCount: 1) ?? Data()
        let destinationTrailingData = try destinationHandle.read(upToCount: 1) ?? Data()
        let destinationFinal = try pinnedDestination.snapshot()
        guard sourceTrailingData.isEmpty,
              destinationTrailingData.isEmpty,
              sourceRemainedStable(
                initialSize: sourceSize,
                initialModificationDate: sourceModificationDate,
                initialIdentity: sourceIdentity,
                finalAttributes: try FileManager.default.attributesOfItem(atPath: source.path)
              ),
              pinnedFileRemainedStable(destinationInitial, destinationFinal) else {
            throw NSError(domain: "FileCopyService", code: -11, userInfo: [NSLocalizedDescriptionKey: "File changed while comparing bytes"])
        }
        return true
    }

    private static func sourceFileSize(_ source: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func pinnedFileRemainedStable(_ initial: stat, _ final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
    }
    #endif

    fileprivate static func existingDestinationConflictError(_ reason: String) -> NSError {
        NSError(
            domain: "FileCopyService",
            code: NSFileWriteFileExistsError,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    /// Security: compare path-components, not raw prefixes, to avoid boundary bypasses.
    private static func pathIsWithin(_ candidatePath: String, root rootPath: String) -> Bool {
        let candidateComponents = URL(fileURLWithPath: candidatePath).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    private static func checksumsMatch(
        source: URL,
        destination: URL,
        verificationMode: VerificationMode
    ) async throws -> Bool {
        let types = verificationMode.checksumTypes
        guard !types.isEmpty else { return false }
        for type in types {
            let srcHash = try await SharedChecksumService.shared.generateChecksum(
                for: source,
                type: type,
                useCache: false,
                progressCallback: nil
            )
            let dstHash = try await SharedChecksumService.shared.generateChecksum(
                for: destination,
                type: type,
                useCache: false,
                progressCallback: nil
            )
            if srcHash.lowercased() != dstHash.lowercased() {
                return false
            }
        }
        return true
    }

    private static func fileIdentity(from attributes: [FileAttributeKey: Any]) -> (volume: UInt64?, file: UInt64?) {
        let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return (volume, file)
    }

    private static func sourceRemainedStable(
        initialSize: Int64,
        initialModificationDate: Date?,
        initialIdentity: (volume: UInt64?, file: UInt64?),
        finalAttributes: [FileAttributeKey: Any]
    ) -> Bool {
        let finalSize = (finalAttributes[.size] as? NSNumber)?.int64Value ?? -1
        guard finalSize == initialSize else { return false }

        let finalIdentity = fileIdentity(from: finalAttributes)
        if let initialVolume = initialIdentity.volume, let finalVolume = finalIdentity.volume, initialVolume != finalVolume {
            return false
        }
        if let initialFile = initialIdentity.file, let finalFile = finalIdentity.file, initialFile != finalFile {
            return false
        }

        let finalModificationDate = finalAttributes[.modificationDate] as? Date
        return initialModificationDate == finalModificationDate
    }
}

#if canImport(Darwin)
extension FileCopyService {
    private static func logMemoryUsage(context: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<Int32>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return }
        let usedMB = Double(info.resident_size) / 1_048_576.0
        let formatted = String(format: "%.2f", usedMB)
        SharedLogger.debug("Memory [\(context)]: \(formatted) MB resident", category: .transfer)
    }
}
#else
extension FileCopyService {
    private static func logMemoryUsage(context: String) {}
}
#endif

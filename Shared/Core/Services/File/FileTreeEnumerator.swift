import Foundation

/// Lightweight entry for cached file enumeration (Perf 1)
struct FileEntry: Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
    let modificationDate: Date?

    init(url: URL, relativePath: String, size: Int64, modificationDate: Date? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// Computes paths relative to a base folder. FileManager's enumerator may report
/// URLs through a different alias than the caller supplied (macOS resolves /var to
/// /private/var, and Foundation strips /private again when resolving), so both forms
/// are compared. It never guesses: an item that cannot be placed below the base
/// throws, because flattening it to a bare filename would misplace or overwrite data.
struct RelativePathResolver: Sendable {
    let base: URL
    private let basePaths: [String]

    init(base: URL) {
        self.base = base
        var paths = [base.path, base.resolvingSymlinksInPath().path, base.standardizedFileURL.path]
        paths = paths.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
        var unique: [String] = []
        for path in paths where !unique.contains(path) { unique.append(path) }
        basePaths = unique
    }

    func resolve(_ item: URL) throws -> String {
        for candidate in [item.path, item.resolvingSymlinksInPath().path] {
            for basePath in basePaths where candidate.hasPrefix(basePath + "/") {
                return String(candidate.dropFirst(basePath.count + 1))
            }
        }
        throw NSError(
            domain: "FileTreeEnumerator",
            code: NSFileReadUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Could not determine the path of \(item.lastPathComponent) relative to \(base.lastPathComponent)"]
        )
    }
}

enum FileTreeEnumerator {
    /// Worker-scoped exact V4 selection. Structured child Tasks inherit this value, so
    /// the existing hardened copy service and its source-stability recheck see the same
    /// frozen subset without adding a second copy implementation. GUI/V3 callers never
    /// bind it and therefore retain whole-source enumeration byte-for-byte.
    @TaskLocal static var exactRelativePaths: [String]?

    /// macOS volume metadata directories written to the root of removable media. They are
    /// not user data and are frequently unreadable without Full Disk Access, so descending
    /// into them would abort the whole transfer with a permission error. Only direct
    /// children of the source root are skipped; a user folder that happens to share one
    /// of these names deeper in the tree is real data and is kept.
    static let skippedVolumeMetadataDirectories: Set<String> = [
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
    ]

    /// Perf 1: Enumerate regular files once and cache the list.
    /// Pass result to both copy and verify phases to eliminate triple filesystem walk.
    /// ~20 bytes per entry overhead for 100K files ≈ 20MB - acceptable.
    static func enumerateRegularFiles(base: URL) throws -> [FileEntry] {
        if let exactRelativePaths {
            return try enumerateExactRegularFiles(base: base, relativePaths: exactRelativePaths)
        }
        return try enumerateWholeSource(base: base)
    }

    /// V4 selection resolves only the explicitly requested source-root-relative files.
    /// It never builds a staging tree, never follows symlinks, and never reads excluded
    /// regular-file metadata or bytes. The same path vocabulary is validated again here
    /// at the filesystem boundary so callers cannot bypass the wire validation helper.
    private static func enumerateExactRegularFiles(base: URL, relativePaths: [String]) throws -> [FileEntry] {
        try Task.checkCancellation()
        if let issue = TransferRelativePathSelection.validationIssue(relativePaths) {
            throw NSError(
                domain: "FileTreeEnumerator",
                code: NSFileReadInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: issue]
            )
        }

        let fileManager = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: base.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw BitMatchError.fileNotFound(base)
        }

        let canonical = TransferRelativePathSelection.canonicalized(relativePaths)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var entries: [FileEntry] = []
        entries.reserveCapacity(canonical.count)

        for relativePath in canonical {
            try Task.checkCancellation()
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let first = components.first, skippedVolumeMetadataDirectories.contains(first) {
                throw NSError(
                    domain: "FileTreeEnumerator",
                    code: NSFileReadNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: "Selected path is inside ignored volume metadata: \(relativePath)"]
                )
            }

            var current = base
            for (index, component) in components.enumerated() {
                current.appendPathComponent(component, isDirectory: index < components.count - 1)
                let values: URLResourceValues
                do {
                    values = try current.resourceValues(forKeys: keys)
                } catch {
                    throw NSError(
                        domain: "FileTreeEnumerator",
                        code: (error as NSError).code,
                        userInfo: [NSLocalizedDescriptionKey: "Selected source file is unavailable: \(relativePath): \(error.localizedDescription)"]
                    )
                }
                guard values.isSymbolicLink != true else {
                    throw NSError(
                        domain: "FileTreeEnumerator",
                        code: NSFileReadInvalidFileNameError,
                        userInfo: [NSLocalizedDescriptionKey: "Selected source path must not traverse a symlink: \(relativePath)"]
                    )
                }
                if index < components.count - 1 {
                    guard values.isDirectory == true else {
                        throw NSError(
                            domain: "FileTreeEnumerator",
                            code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "Selected source parent is not a directory: \(relativePath)"]
                        )
                    }
                } else {
                    guard values.isRegularFile == true else {
                        throw NSError(
                            domain: "FileTreeEnumerator",
                            code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "Selected source path is not a regular file: \(relativePath)"]
                        )
                    }
                    entries.append(FileEntry(
                        url: current,
                        relativePath: relativePath,
                        size: Int64(values.fileSize ?? 0),
                        modificationDate: values.contentModificationDate
                    ))
                }
            }
        }

        guard entries.count == canonical.count else {
            throw NSError(
                domain: "FileTreeEnumerator",
                code: NSFileReadNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: "Exact source selection could not be resolved completely"]
            )
        }
        return entries
    }

    private static func enumerateWholeSource(base: URL) throws -> [FileEntry] {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let resolver = RelativePathResolver(base: base)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var entries: [FileEntry] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BitMatchError.fileNotFound(base)
        }

        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { url, error in
                if traversalError == nil {
                    traversalError = NSError(
                        domain: "FileTreeEnumerator",
                        code: (error as NSError).code,
                        userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.lastPathComponent): \(error.localizedDescription)"]
                    )
                }
                return false
            }
        ) else {
            throw BitMatchError.fileAccessDenied(base)
        }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            if values.isDirectory == true,
               values.isSymbolicLink != true,
               enumerator.level == 1,
               skippedVolumeMetadataDirectories.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if values.isSymbolicLink == true || values.isRegularFile != true {
                continue
            }
            entries.append(FileEntry(
                url: item,
                relativePath: try resolver.resolve(item),
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            ))
        }
        if let traversalError { throw traversalError }
        try Task.checkCancellation()
        return entries
    }
}

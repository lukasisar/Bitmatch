import Foundation

// Foundation-only transfer primitives shared by the apps and the headless worker.
// Keep UI presentation concerns out of this file so the worker does not need SwiftUI.

enum BitMatchError: LocalizedError {
    case fileAccessDenied(URL)
    case fileNotFound(URL)
    case checksumMismatch(String, String)
    case operationCancelled
    case insufficientStorage(Int64, Int64)
    case networkError(String)
    case unknownError(String)

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let url):
            return "Access denied to file: \(url.lastPathComponent)"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - Expected: \(expected), Got: \(actual)"
        case .operationCancelled:
            return "Operation was cancelled"
        case .insufficientStorage(let required, let available):
            return "Insufficient storage - Need: \(ByteCountFormatter().string(fromByteCount: required)), Available: \(ByteCountFormatter().string(fromByteCount: available))"
        case .networkError(let message):
            return "Network error: \(message)"
        case .unknownError(let message):
            return "Unknown error: \(message)"
        }
    }
}

enum ChecksumAlgorithm: String, CaseIterable, Identifiable, Codable {
    case sha256 = "SHA-256"
    case sha1 = "SHA-1"
    case md5 = "MD5"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .sha256: return "SHA-256 (Recommended)"
        case .sha1: return "SHA-1"
        case .md5: return "MD5 (Legacy)"
        }
    }

    /// MD5 and SHA-1 remain only for legacy compatibility.
    var isDeprecated: Bool {
        switch self {
        case .sha256: return false
        case .sha1, .md5: return true
        }
    }
}

struct VerificationResult: Codable {
    let sourceChecksum: String
    let destinationChecksum: String
    let matches: Bool
    let checksumType: ChecksumAlgorithm
    let processingTime: TimeInterval
    let fileSize: Int64

    var isValid: Bool { matches }

    var description: String {
        matches
            ? "✅ Files match - \(checksumType.rawValue) verified"
            : "❌ Files differ - \(checksumType.rawValue) mismatch"
    }
}

enum VerificationMode: String, CaseIterable, Identifiable, Codable {
    case quick = "Quick"
    case standard = "Standard"
    case thorough = "Thorough"
    case paranoid = "Paranoid"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .quick: return "Quick checks file sizes only; file contents are not checksum-verified."
        case .standard: return "Standard compares SHA-256 checksums to verify each copy matches its source."
        case .thorough: return "Thorough verifies each copy with SHA-256 and MD5 checksums."
        case .paranoid: return "Paranoid adds a byte-by-byte comparison to checksum verification."
        }
    }

    var requiresMHL: Bool {
        switch self {
        case .quick, .standard: return false
        case .thorough, .paranoid: return true
        }
    }

    var useChecksum: Bool {
        switch self {
        case .quick: return false
        case .standard, .thorough, .paranoid: return true
        }
    }

    var checksumTypes: [ChecksumAlgorithm] {
        switch self {
        case .quick: return []
        case .standard: return [.sha256]
        case .thorough: return [.sha256, .md5]
        case .paranoid: return [.sha256, .md5, .sha1]
        }
    }

    func estimatedTime(fileCount: Int) -> String {
        let complexityFactor: Double
        switch self {
        case .quick: complexityFactor = 0.5
        case .standard: complexityFactor = 1.0
        case .thorough: complexityFactor = 1.8
        case .paranoid: complexityFactor = 2.5
        }

        let baseTimeMinutes = Double(fileCount) * 0.02 * complexityFactor
        if baseTimeMinutes < 1.0 {
            return "~\(Int(baseTimeMinutes * 60))s"
        } else if baseTimeMinutes < 60.0 {
            return "~\(Int(baseTimeMinutes))m"
        }
        let hours = Int(baseTimeMinutes / 60)
        let minutes = Int(baseTimeMinutes.truncatingRemainder(dividingBy: 60))
        return minutes > 0 ? "~\(hours)h \(minutes)m" : "~\(hours)h"
    }
}

import Foundation

public enum StorageTopologyResolutionStatus: String, Codable, Equatable, Sendable {
    case resolved
    case unknown
}

public struct StorageIdentityEvidence: Codable, Equatable, Sendable {
    public let resolutionStatus: StorageTopologyResolutionStatus
    public let physicalLeafIdentifiers: [String]
    public let basis: String
    public let detail: String?

    public init(
        resolutionStatus: StorageTopologyResolutionStatus,
        physicalLeafIdentifiers: [String],
        basis: String,
        detail: String? = nil
    ) {
        self.resolutionStatus = resolutionStatus
        self.physicalLeafIdentifiers = physicalLeafIdentifiers.sorted()
        self.basis = basis
        self.detail = detail
    }

    public static func unknown(basis: String, detail: String) -> Self {
        Self(
            resolutionStatus: .unknown,
            physicalLeafIdentifiers: [],
            basis: basis,
            detail: detail
        )
    }
}

public enum PhysicalDeviceRelationship: String, Codable, Equatable, Sendable {
    case samePhysicalDevice
    case differentPhysicalDevices
    case unknown
}

public struct DestinationTopologyEvidence: Codable, Equatable, Sendable {
    public let requestID: String
    public let storage: StorageIdentityEvidence
}

public struct DestinationPhysicalRelationshipEvidence: Codable, Equatable, Sendable {
    public let firstRequestID: String
    public let secondRequestID: String
    public let relationship: PhysicalDeviceRelationship
}

public struct StorageTopologyEvidence: Codable, Equatable, Sendable {
    public let source: StorageIdentityEvidence
    public let destinations: [DestinationTopologyEvidence]
    public let destinationRelationships: [DestinationPhysicalRelationshipEvidence]
}

protocol StorageTopologyResolving: Sendable {
    func resolveStorage(for url: URL) -> StorageIdentityEvidence
}

enum StorageTopologyClassifier {
    static func evidence(
        sourceURL: URL,
        destinations: [DestinationRequest],
        resolver: any StorageTopologyResolving
    ) -> StorageTopologyEvidence {
        let source = resolver.resolveStorage(for: sourceURL)
        let resolvedDestinations = destinations.map { destination in
            DestinationTopologyEvidence(
                requestID: destination.requestID,
                storage: resolver.resolveStorage(
                    for: URL(fileURLWithPath: destination.executionRoot, isDirectory: true)
                )
            )
        }
        var relationships: [DestinationPhysicalRelationshipEvidence] = []
        for left in resolvedDestinations.indices {
            for right in resolvedDestinations.indices where left < right {
                relationships.append(DestinationPhysicalRelationshipEvidence(
                    firstRequestID: resolvedDestinations[left].requestID,
                    secondRequestID: resolvedDestinations[right].requestID,
                    relationship: relationship(
                        resolvedDestinations[left].storage,
                        resolvedDestinations[right].storage
                    )
                ))
            }
        }
        return StorageTopologyEvidence(
            source: source,
            destinations: resolvedDestinations,
            destinationRelationships: relationships
        )
    }

    static func relationship(
        _ left: StorageIdentityEvidence,
        _ right: StorageIdentityEvidence
    ) -> PhysicalDeviceRelationship {
        guard left.resolutionStatus == .resolved,
              right.resolutionStatus == .resolved,
              left.physicalLeafIdentifiers.count == 1,
              right.physicalLeafIdentifiers.count == 1 else { return .unknown }
        let leftLeaves = Set(left.physicalLeafIdentifiers)
        let rightLeaves = Set(right.physicalLeafIdentifiers)
        return leftLeaves.isDisjoint(with: rightLeaves)
            ? .differentPhysicalDevices
            : .samePhysicalDevice
    }
}

#if os(macOS)
struct MacOSStorageTopologyResolver: StorageTopologyResolving {
    func resolveStorage(for url: URL) -> StorageIdentityEvidence {
        do {
            let values = try url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey])
            guard values.volumeIsLocal == true else {
                return .unknown(basis: "diskutil-info-plist", detail: "Filesystem is not confirmed local")
            }
            guard let volumeURL = values.volume else {
                return .unknown(basis: "diskutil-info-plist", detail: "Unable to identify mounted volume")
            }
            let volume = try diskInfo(volumeURL.path)
            return classify(volume)
        } catch {
            return .unknown(basis: "diskutil-info-plist", detail: error.localizedDescription)
        }
    }

    private func classify(_ volume: [String: Any]) -> StorageIdentityEvidence {
        if isAmbiguous(volume) {
            return .unknown(basis: "diskutil-info-plist", detail: "Composite, virtual, image, or RAID storage is not proven independent")
        }

        if let stores = volume["APFSPhysicalStores"] as? [[String: Any]], !stores.isEmpty {
            var leaves: [String] = []
            for store in stores {
                guard let storeID = store["APFSPhysicalStore"] as? String else {
                    return .unknown(basis: "diskutil-info-plist", detail: "APFS physical-store identifier is missing")
                }
                do {
                    let storeInfo = try diskInfo("/dev/" + storeID)
                    guard !isAmbiguous(storeInfo),
                          let wholeDisk = storeInfo["ParentWholeDisk"] as? String,
                          !wholeDisk.isEmpty else {
                        return .unknown(basis: "diskutil-info-plist", detail: "APFS backing store cannot be reduced to a physical whole disk")
                    }
                    let wholeInfo = try diskInfo("/dev/" + wholeDisk)
                    guard wholeInfo["WholeDisk"] as? Bool == true,
                          !isAmbiguous(wholeInfo) else {
                        return .unknown(basis: "diskutil-info-plist", detail: "APFS whole-disk backing is ambiguous")
                    }
                    guard let identifier = physicalIdentifier(wholeInfo, wholeDisk: wholeDisk) else {
                        return .unknown(basis: "diskutil-info-plist", detail: "Physical whole disk has no I/O Registry identity")
                    }
                    leaves.append(identifier)
                } catch {
                    return .unknown(basis: "diskutil-info-plist", detail: error.localizedDescription)
                }
            }
            let unique = Array(Set(leaves)).sorted()
            guard unique.count == 1 else {
                return .unknown(basis: "diskutil-info-plist", detail: "Multi-store APFS/composite storage is conservatively unresolved")
            }
            return StorageIdentityEvidence(
                resolutionStatus: .resolved,
                physicalLeafIdentifiers: unique,
                basis: "diskutil-apfs-physical-store-whole-disk"
            )
        }

        guard let wholeDisk = volume["ParentWholeDisk"] as? String, !wholeDisk.isEmpty else {
            return .unknown(basis: "diskutil-info-plist", detail: "No physical whole-disk parent was reported")
        }
        do {
            let wholeInfo = try diskInfo("/dev/" + wholeDisk)
            guard wholeInfo["WholeDisk"] as? Bool == true,
                  !isAmbiguous(wholeInfo) else {
                return .unknown(basis: "diskutil-info-plist", detail: "Whole-disk parent is virtual or composite")
            }
            guard let identifier = physicalIdentifier(wholeInfo, wholeDisk: wholeDisk) else {
                return .unknown(basis: "diskutil-info-plist", detail: "Physical whole disk has no I/O Registry identity")
            }
            return StorageIdentityEvidence(
                resolutionStatus: .resolved,
                physicalLeafIdentifiers: [identifier],
                basis: "diskutil-parent-whole-disk"
            )
        } catch {
            return .unknown(basis: "diskutil-info-plist", detail: error.localizedDescription)
        }
    }

    private func isAmbiguous(_ info: [String: Any]) -> Bool {
        if info["RAIDMaster"] as? Bool == true || info["RAIDSlice"] as? Bool == true { return true }
        if info["SystemImage"] as? Bool == true { return true }
        if (info["VirtualOrPhysical"] as? String)?.caseInsensitiveCompare("Virtual") == .orderedSame { return true }
        if (info["BusProtocol"] as? String)?.localizedCaseInsensitiveContains("Disk Image") == true { return true }
        return false
    }

    private func physicalIdentifier(_ info: [String: Any], wholeDisk: String) -> String? {
        if let registryPath = info["DeviceTreePath"] as? String, !registryPath.isEmpty {
            return "bsd-whole-disk:\(wholeDisk)|ioregistry:" + registryPath
        }
        return nil
    }

    private func diskInfo(_ target: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", target]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Error"] as? Bool != true else {
            let message = String(data: errorData, encoding: .utf8)
                ?? "diskutil could not resolve storage"
            throw NSError(domain: "BitMatchTransferWorker.Topology", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return plist
    }
}
#endif

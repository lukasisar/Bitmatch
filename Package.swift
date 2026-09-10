// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BitMatchTransferWorker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BitMatchTransferCore", targets: ["BitMatchTransferCore"]),
        .executable(name: "bitmatch-transfer-worker", targets: ["BitMatchTransferWorker"]),
    ],
    targets: [
        .target(
            name: "BitMatchTransferCore",
            path: "Shared",
            sources: [
                "Core/Models/CameraModels.swift",
                "Core/Models/OperationModels.swift",
                "Core/Models/TransferPrimitives.swift",
                "Core/Services/AsyncSemaphore.swift",
                "Core/Services/ChecksumCache.swift",
                "Core/Services/File/FileCopyService.swift",
                "Core/Services/File/FileTreeEnumerator.swift",
                "Core/Services/File/SafetyValidator.swift",
                "Core/Services/Logging/SharedLogger.swift",
                "Core/Services/ServiceProtocols.swift",
                "Core/Services/SharedChecksumService.swift",
                "Core/Services/SharedFileOperationsService.swift",
                "Core/Worker/TransferWorkerProtocol.swift",
                "Core/Worker/TransferWorkerRuntime.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BitMatchTransferWorker",
            dependencies: ["BitMatchTransferCore"],
            path: "WorkerCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BitMatchTransferWorkerTests",
            dependencies: ["BitMatchTransferCore"],
            path: "WorkerTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

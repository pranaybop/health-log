// swift-tools-version: 5.10
import PackageDescription

// The Xcode project links the "LogNative" product; every .swift file under Sources/ is compiled
// automatically, so adding a file never touches the project file.
//
//   LogCore    data models, Supabase calls, Central-time dates, core calculations, the shared store
//   LogUI      SwiftUI screens (Shared/, Today/, Meds/, Log/, Trends/); places LogHealth's HealthSyncPanel
//   LogHealth  Apple Health sync in Swift, with background refresh, and its status panel
//   LogLocalAI  runs a downloaded open model (Bonsai 2, Qwen 3.5) on the phone with MLX, for Ask
//   LogActivity  the hunger Live Activity's shared types and its log buttons (also linked by the
//              LogWidgets extension, which draws it on the Lock Screen and in the Dynamic Island)
let package = Package(
    name: "LogNative",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LogNative", targets: ["LogCore", "LogUI", "LogHealth", "LogActivity", "LogLocalAI"]),
        .library(name: "LogActivity", targets: ["LogActivity", "LogCore"]),
    ],
    dependencies: [
        // On-device models for Ask (LogLocalAI). Macro-free: LogLocalAI adapts the downloader and
        // tokenizer itself, so the app build needs no macro approval.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.33.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.4.0"),
    ],
    targets: [
        .target(name: "LogCore"),
        // FoundationModels (Apple Intelligence, iOS 26) is weak-linked so the app still opens on iOS 17-25.
        .target(name: "LogUI", dependencies: ["LogCore", "LogHealth", "LogActivity", "LogLocalAI"],
                linkerSettings: [.linkedFramework("UserNotifications"), .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]),
        .target(name: "LogLocalAI", dependencies: [
            "LogCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "LogActivity", dependencies: ["LogCore"], linkerSettings: [.linkedFramework("ActivityKit"), .linkedFramework("AppIntents")]),
        .target(name: "LogHealth", dependencies: ["LogCore"], linkerSettings: [.linkedFramework("HealthKit")]),
        .testTarget(name: "LogCoreTests", dependencies: ["LogCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LogHealthTests", dependencies: ["LogHealth", "LogCore"]),
    ]
)

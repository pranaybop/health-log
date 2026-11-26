// swift-tools-version: 5.10
import PackageDescription

// The native side of Log (going native in stages, Nov 2026). The Xcode project links the
// "LogNative" product; every .swift file under Sources/ is compiled automatically, so adding a
// file never touches the project file.
//
//   LogCore    data models, Supabase calls, Central-time dates, core calculations, the shared store
//   LogUI      SwiftUI screens (Shared/, Today/, Meds/, Log/, Trends/); places LogHealth's HealthSyncPanel
//   LogHealth  Apple Health sync in Swift, with background refresh, and its status panel
//   LogActivity  the hunger Live Activity's shared types and its log buttons (also linked by the
//              LogWidgets extension, which draws it on the Lock Screen and in the Dynamic Island)
let package = Package(
    name: "LogNative",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LogNative", targets: ["LogCore", "LogUI", "LogHealth", "LogActivity"]),
        .library(name: "LogActivity", targets: ["LogActivity", "LogCore"]),
    ],
    targets: [
        .target(name: "LogCore"),
        // FoundationModels (Apple Intelligence, iOS 26) is weak-linked so the app still opens on iOS 17-25.
        .target(name: "LogUI", dependencies: ["LogCore", "LogHealth", "LogActivity"],
                linkerSettings: [.linkedFramework("UserNotifications"), .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]),
        .target(name: "LogActivity", dependencies: ["LogCore"], linkerSettings: [.linkedFramework("ActivityKit"), .linkedFramework("AppIntents")]),
        .target(name: "LogHealth", dependencies: ["LogCore"], linkerSettings: [.linkedFramework("HealthKit")]),
        .testTarget(name: "LogCoreTests", dependencies: ["LogCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LogHealthTests", dependencies: ["LogHealth", "LogCore"]),
    ]
)

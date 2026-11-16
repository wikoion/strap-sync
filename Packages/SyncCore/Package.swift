// swift-tools-version: 5.9
import PackageDescription

// Everything that can be tested without a strap, Bluetooth or HealthKit: WHOOP 5/MG framing and
// history parsing, the standard heart-rate characteristic, turning beats into Health samples, and
// sleep stages.
let package = Package(
    name: "SyncCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SyncCore", targets: ["SyncCore"])],
    targets: [
        // The sleep-stage model (SleepStages.swift), exported by research/sleep-stages/export_model.py.
        // Optimised even in Debug: staging a night takes ~15 s unoptimised, ~1.5 s with -O.
        .target(name: "SyncCore", resources: [.copy("Resources/SleepModel")], swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"], resources: [.copy("Fixtures")]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

/// Every target runs in Swift 6 language mode. Data-race safety is checked at
/// compile time from day one -- retrofitting it later onto a sampling engine
/// that fans out to the UI is far more painful than living with it now.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Caliper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Caliper", targets: ["CaliperApp"]),
        .executable(name: "caliper-bench", targets: ["CaliperBench"]),
    ],
    dependencies: [
        // The one third-party dependency, and only the app links it: updates
        // are the single place where doing it by hand means doing it worse --
        // an EdDSA-verified download and an in-place replacement of a running,
        // signed bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Layer 1: reading hardware. No UI, no scheduling, no state beyond
        // what a delta-based counter needs.
        .target(name: "SensorKit", swiftSettings: strict),

        // Layer 2: the single scheduler + history storage.
        .target(name: "MetricBus", dependencies: ["SensorKit"], swiftSettings: strict),

        // Layer 3: pure drawing. Deliberately does NOT depend on MetricBus --
        // renderers take plain values so they can be snapshot-tested without
        // spinning up a sampler.
        .target(name: "RenderKit", dependencies: ["SensorKit"], swiftSettings: strict),

        // Layer 4: composing cells into a strip.
        .target(name: "LayoutEngine", dependencies: ["RenderKit", "SensorKit"], swiftSettings: strict),

        // Layer 5: the document format. Depends on the layers it reconstructs,
        // never the other way round -- RenderKit must stay ignorant of how a
        // cell is written down, or the drawing code becomes hostage to the file
        // format's version history.
        .target(
            name: "SchemaKit",
            dependencies: ["LayoutEngine", "RenderKit", "SensorKit"],
            swiftSettings: strict
        ),

        .executableTarget(
            name: "CaliperApp",
            dependencies: [
                "SensorKit", "MetricBus", "RenderKit", "LayoutEngine", "SchemaKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "CaliperBench",
            dependencies: ["SensorKit", "MetricBus", "RenderKit", "LayoutEngine", "SchemaKit"],
            swiftSettings: strict
        ),

        .testTarget(name: "SensorKitTests", dependencies: ["SensorKit"], swiftSettings: strict),
        .testTarget(name: "MetricBusTests", dependencies: ["MetricBus", "SensorKit"], swiftSettings: strict),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit", "SensorKit"], swiftSettings: strict),
        .testTarget(
            name: "SchemaKitTests",
            dependencies: ["SchemaKit", "LayoutEngine", "RenderKit", "SensorKit"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "LayoutEngineTests",
            dependencies: ["LayoutEngine", "RenderKit", "SensorKit"],
            swiftSettings: strict
        ),

        // The app layer: lifecycle, menus, windows, and the alert, import and
        // occlusion plumbing between the libraries and AppKit. It creates real
        // status items and windows, so it needs a logged-in session -- which a
        // Mac, and GitHub's macOS runners, have.
        .testTarget(
            name: "CaliperAppTests",
            dependencies: ["CaliperApp", "MetricBus", "SchemaKit", "LayoutEngine", "RenderKit", "SensorKit"],
            swiftSettings: strict
        ),

        // Reads the source tree and Resources/*.lproj, not any module: the
        // strings it checks are written in every target and looked up in the
        // app's bundle.
        .testTarget(name: "LocalizationTests", swiftSettings: strict),
    ]
)

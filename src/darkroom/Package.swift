// swift-tools-version:5.9
//
// Soup Darkroom: the desktop developer over the C engine. Sources/CSoup/engine
// is a symlink to src/engine, so there is one engine and no copy of it.
import PackageDescription

let package = Package(
    name: "SoupDarkroom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SoupDarkroom", targets: ["SoupDarkroom"]),
        .executable(name: "darkroomctl", targets: ["darkroomctl"]),
    ],
    targets: [
        .target(
            name: "CSoup",
            cSettings: [.define("SE_HOSTED"), .headerSearchPath("engine"),
                        .unsafeFlags(["-Wno-shorten-64-to-32", "-Wno-unused-parameter"])]),
        .target(name: "DarkroomCore", dependencies: ["CSoup"]),
        .target(name: "DarkroomEngine", dependencies: ["CSoup", "DarkroomCore"]),
        .executableTarget(
            name: "SoupDarkroom",
            dependencies: ["DarkroomCore", "DarkroomEngine"],
            path: "Sources/DarkroomApp"),
        .executableTarget(
            name: "darkroomctl",
            dependencies: ["DarkroomCore", "DarkroomEngine"]),
        .testTarget(name: "DarkroomCoreTests", dependencies: ["DarkroomCore"]),
        .testTarget(name: "DarkroomEngineTests", dependencies: ["DarkroomEngine"]),
    ]
)

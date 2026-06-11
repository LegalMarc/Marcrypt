// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Marcrypt",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Marcrypt", targets: ["Marcrypt"]),
        .executable(name: "MarcryptCLI", targets: ["MarcryptCLI"]),
        .executable(name: "DocxHarness", targets: ["DocxHarness"]),
        .executable(name: "CoreE2EHarness", targets: ["CoreE2EHarness"]),
        .executable(name: "CLIHarness", targets: ["CLIHarness"]),
        .library(name: "MarcryptCore", targets: ["MarcryptCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", from: "2.5.5"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "POLEWrapper",
            path: "Sources/POLEWrapper",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PasswordCracker",
            dependencies: [],
            path: "Sources/PasswordCracker",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "MarcryptCore",
            dependencies: ["ZipArchive", "POLEWrapper", "PasswordCracker"],
            path: "Sources/MarcryptCore"
        ),
        .executableTarget(
            name: "Marcrypt",
            dependencies: ["MarcryptCore"],
            path: "Marcrypt/Marcrypt",
            exclude: [
                "Assets.xcassets",
                "Marcrypt.entitlements",
                "Info.plist"
            ],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/help.html")
            ]
        ),
        .executableTarget(
            name: "MarcryptCLI",
            dependencies: [
                "MarcryptCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MarcryptCLI"
        ),
        .executableTarget(
            name: "DocxHarness",
            dependencies: ["MarcryptCore"],
            path: "Tests/DocxHarness",
            exclude: ["verify_compliance.py"]
        ),
        .executableTarget(
            name: "CoreE2EHarness",
            dependencies: ["MarcryptCore"],
            path: "Tests/CoreE2EHarness"
        ),
        .executableTarget(
            name: "CLIHarness",
            dependencies: [],
            path: "Tests/CLIHarness"
        ),
        .testTarget(
            name: "EncryptionTests",
            dependencies: ["MarcryptCore", "POLEWrapper"],
            path: "Tests/EncryptionTests"
        ),
        .testTarget(
            name: "UITests",
            dependencies: ["Marcrypt"],
            path: "Tests/UITests"
        ),
        .testTarget(
            name: "MarcryptTests",
            dependencies: ["MarcryptCore"],
            path: "Tests/MarcryptTests"
        ),
        .executableTarget(
            name: "ComprehensiveTest",
            dependencies: ["MarcryptCore"],
            path: "Tests/ComprehensiveTest"
        ),
        .executableTarget(
            name: "RealWorldBatchTest",
            dependencies: ["MarcryptCore"],
            path: "Tests/RealWorldBatchTest",
            exclude: [
                "verify_deep_docx.py",
                "verify_outputs.sh"
            ]
        ),
        .executableTarget(
            name: "MarcryptDecrypt",
            dependencies: ["MarcryptCore"],
            path: "Tests/MarcryptDecrypt"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StrengthCore",
    platforms: [
        .iOS("27.0"),
        .watchOS("27.0"),
    ],
    products: [
        .library(name: "StrengthCore", targets: ["StrengthCore"]),
        .library(name: "StrengthIntents", targets: ["StrengthIntents"]),
    ],
    targets: [
        .target(name: "StrengthCore"),
        .target(name: "StrengthIntents", dependencies: ["StrengthCore"]),
    ],
    swiftLanguageModes: [.v5]
)

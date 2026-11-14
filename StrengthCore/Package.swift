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
    ],
    targets: [
        .target(name: "StrengthCore"),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FigmaBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FigmaBridge")
    ]
)

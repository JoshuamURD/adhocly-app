// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdhoclyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AdhoclyCore", targets: ["AdhoclyCore"])],
    targets: [
        .target(name: "AdhoclyCore"),
        .testTarget(name: "AdhoclyCoreTests", dependencies: ["AdhoclyCore"])
    ]
)

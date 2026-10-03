// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RedmiMirroring", platforms: [.macOS(.v14)], products: [.executable(name: "RedmiMirroring", targets: ["RedmiMirroring"])], targets: [.executableTarget(name: "RedmiMirroring"), .testTarget(name: "RedmiMirroringTests", dependencies: ["RedmiMirroring"])])

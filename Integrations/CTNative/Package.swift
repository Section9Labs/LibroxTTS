// swift-tools-version: 6.0
import PackageDescription

// A small native parity harness using exactly the sources linked by LibroxTTS.
let package = Package(name: "LibroxCTNative", platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "LibroxCTNative", targets: ["LibroxCTNative"]),
               .executable(name: "ct-native-probe", targets: ["CTProbe"])],
    targets: [
        .target(name: "LibroxCTNative", resources: [.process("Resources")]),
        .executableTarget(name: "CTProbe", dependencies: ["LibroxCTNative"]),
        .testTarget(name: "LibroxCTNativeTests", dependencies: ["LibroxCTNative"])
    ])

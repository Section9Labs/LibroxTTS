// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ApprovedExpressionQualification", platforms: [.macOS(.v15), .iOS(.v18)],
 dependencies: [.package(name: "LibroxTTS", path: "../..")],
 targets: [.executableTarget(name: "ApprovedExpressionQualification", dependencies: [.product(name: "LibroxTTS", package: "LibroxTTS"), .product(name: "KokoroPronunciation", package: "LibroxTTS"), .product(name: "LibroxCTNative", package: "LibroxTTS")], path: "Sources", exclude: ["App.swift"])])

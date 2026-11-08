import Foundation
import MLX

enum PocketTestMetal {
    // The override setter writes a process-global C++ std::string without a
    // lock. Parallel tests must initialize it exactly once, before any MLX use.
    private static let configured: Void = {
        if let path = ProcessInfo.processInfo.environment["POCKET_METALLIB"] {
            GPU.metallib = URL(fileURLWithPath: path)
        }
    }()
    static func configure() { _ = configured }
}

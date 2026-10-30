#if os(macOS)
import Foundation
import MLX

/// Configure once, before any model in the dedicated worker process. Retains the
/// verified shared runtime descriptor; this is not a renderer-readiness receipt.
public final class ChatterboxMacRuntime {
    private let asset: AcousticRuntimeAsset
    public init(metallib: URL) throws {
        asset = try AcousticRuntimeAsset(url: metallib)
        GPU.metallib = asset.url
    }
    public func verify() throws { try asset.verify() }
}
#endif

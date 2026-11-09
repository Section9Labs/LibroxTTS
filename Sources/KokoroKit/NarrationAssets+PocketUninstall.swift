import Foundation
import KokoroCatalog
import PocketTTSMLX

/// Max language packs are independent: every base, voice and delivery-style
/// file of a language lives under `<language>/` in the Max directory, and no
/// file is shared with another language. Hosts own their own receipts beside
/// those folders; these functions never touch anything outside `<language>/`.
extension NarrationAssets {
    private static let uninstallPrefix = ".uninstalling-"

    /// Languages whose base pack is fully present (sizes only; loading verifies hashes).
    public static func installedPocketLanguages(in directory: URL) -> [String] {
        PocketTTSCatalog.languages.filter { isPrepared(directory, model: .pocket, language: $0) }
    }

    /// Bytes on disk under `<language>/`: base pack, voices and delivery styles. Walks files.
    public static func installedPocketBytes(language: String, in directory: URL) -> Int64 {
        guard PocketTTSCatalog.languages.contains(language) else { return 0 }
        return bytes(in: directory.appendingPathComponent(language, isDirectory: true))
    }

    /// Removes one Max language (base pack, voices and delivery styles) and
    /// leaves every other language installed. Returns the bytes freed; a
    /// language that is not installed frees 0. The caller must keep this
    /// language out of any renderer: prefer `NarrationRenderer.uninstallPocketLanguage`.
    @discardableResult
    public static func uninstallPocketLanguage(_ language: String, in directory: URL) throws -> Int64 {
        guard PocketTTSCatalog.languages.contains(language) else { throw PocketTTSError.unsupportedLanguage }
        let fm = FileManager.default
        // An earlier uninstall interrupted after its move left only a hidden folder.
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(uninstallPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        let folder = directory.appendingPathComponent(language, isDirectory: true)
        guard fm.fileExists(atPath: folder.path) else { return 0 }
        let freed = bytes(in: folder)
        // One rename takes the whole pack out of view, so a crash never leaves
        // a partially deleted language that still looks installed.
        let retired = directory.appendingPathComponent(uninstallPrefix + language + "-" + UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: folder, to: retired)
        try fm.removeItem(at: retired)
        return freed
    }

    private static func bytes(in folder: URL) -> Int64 {
        guard let entries = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in entries {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
}

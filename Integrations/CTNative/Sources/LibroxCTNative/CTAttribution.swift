import Foundation

/// The model license is separate from the SDK's Apache-2.0 OR MIT license.
/// Hosts must pass it on and require users to comply with its use restrictions.
public enum CTAttribution {
    public static let notice = "Librox Plus uses a modified Supertone Supertonic 3 model with F1–F5 and M1–M5 presets, licensed under BigScience Open RAIL-M, including its use restrictions. Core ML conversion and CT/DK adaptation by Section9Labs; no Supertone endorsement is implied."
    public static var modelLicense: String { resource("model-LICENSE", extension: nil) }
    public static var modifications: String {
        resource("MODIFICATIONS", extension: "md") + "\n\n" + resource("CTExpressionModifications", extension: "md")
    }
    public static var text: String {
        [notice, modifications, modelLicense, resource("helper-LICENSE", extension: nil)]
            .joined(separator: "\n\n")
    }
    private static func resource(_ name: String, extension ext: String?) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value
    }
}

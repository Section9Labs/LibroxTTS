// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import Foundation
import LibroxCTNative

/// Redistribution notices, bundled so applications can include them in their acknowledgements.
public enum KokoroAttribution {
    public static var text: String {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text + "\n\n" + CTAttribution.text
    }
}

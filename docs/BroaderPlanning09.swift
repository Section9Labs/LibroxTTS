import CryptoKit
import Foundation
import KokoroNarration
import KokoroPronunciation

struct Row: Codable {
    let model: String; let inputScalars: Int; let units: Int
    let medianSeconds: Double; let planSHA256: String
}
let plain = String(repeating:"La puerta estaba abierta y nadie regresaba, ",count:65)
let cases: [(String,String,SpokenTextLexicon)] = [
    ("es", "«" + plain + "fin.»", .init()),
    ("es", "En 2024, Ada volvió.\n\n" + plain + "fin.", .init()),
    ("es", plain + "fin.", .init(entries:[.init(written:"Ada",spoken:"Aída",language:"es")])),
    ("es", "Ada volvió.\n\n" + plain + "fin.", .init(entries:[.init(written:"Ada",spoken:"Aída",language:"es")])),
    ("it", "“" + String(repeating:"La strada era aperta e nessuno tornava, ",count:70) + "fine.”", .init())
]
var rows: [Row] = []
for model in [NarrationModel.plus,.pocket] {
    for (index,item) in cases.enumerated() {
        let (language,text,lexicon) = item
        let voice = model == .plus ? "plus-f1-\(language)-v1" : "pocket-caro_davy-\(language)-v1"
        var times: [Double] = [], signature = "", count = 0
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let plan = try TextNativeNarrationPlanner.plan(text,voiceID:voice,lexicon:lexicon,model:model)
            times.append(ProcessInfo.processInfo.systemUptime-start)
            count = plan.count
            signature = plan.map { "\($0.range.location):\($0.range.length):\($0.voiceID):\($0.synthesisText)" }.joined(separator:"\n")
        }
        rows.append(.init(model:model.rawValue+"-case\(index)",inputScalars:text.unicodeScalars.count,units:count,
            medianSeconds:times.sorted()[1],planSHA256:SHA256.hash(data:Data(signature.utf8)).map{String(format:"%02x",$0)}.joined()))
    }
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
print(String(decoding:try encoder.encode(rows),as:UTF8.self))

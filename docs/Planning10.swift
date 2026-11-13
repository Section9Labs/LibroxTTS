import CryptoKit
import Foundation
import KokoroNarration
import KokoroPronunciation

struct Row: Codable {
    let model: String; let inputScalars: Int; let units: Int
    let medianSeconds: Double; let planSHA256: String
}
let cases: [(String,String,SpokenTextLexicon)] = [
    ("en", String(repeating: "Ada had 21 books, chapter IV was ready; she paid $21.50, ", count: 35) + "the end.", .init(entries:[.init(written:"Ada",spoken:"Aída",language:"en")])),
    ("es", String(repeating: "Ada tenía 21 libros, 31 casas; pagó €21,50, ", count: 40) + "fin.", .init(entries:[.init(written:"Ada",spoken:"Aída",language:"es")])),
    ("en", "Ada paid $21.50 for 21 books.", .init()),
    ("es", String(repeating: "La puerta estaba abierta y nadie regresaba, ", count: 40) + "fin.", .init())
]
var rows: [Row] = []
for model in [NarrationModel.plus,.pocket] {
    for (index,item) in cases.enumerated() {
        let (language,text,lexicon) = item
        let voice = model == .plus ? "plus-f1-\(language)-v1" : "pocket-caro_davy-\(language)-v1"
        var times: [Double] = [], signature = "", count = 0
        let repetitions = index == 2 ? 101 : index == 3 ? 21 : 3
        for _ in 0..<repetitions {
            let start = ProcessInfo.processInfo.systemUptime
            let plan = try TextNativeNarrationPlanner.plan(text, voiceID: voice, lexicon: lexicon, model: model)
            times.append(ProcessInfo.processInfo.systemUptime-start); count = plan.count
            signature = plan.map { "\($0.range.location):\($0.range.length):\($0.voiceID):\($0.synthesisText)" }.joined(separator:"\n")
        }
        rows.append(.init(model:model.rawValue+"-case\(index)",inputScalars:text.unicodeScalars.count,units:count,
            medianSeconds:times.sorted()[times.count / 2],planSHA256:SHA256.hash(data:Data(signature.utf8)).map{String(format:"%02x",$0)}.joined()))
    }
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
print(String(decoding:try encoder.encode(rows),as:UTF8.self))

import Foundation
import CryptoKit
import KokoroPronunciation
let engine = PronunciationEngine()
let texts = [
    "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.",
    "The extraordinary café owner remembered José, André, and the children who had returned yesterday.",
    "She paid $21.50 for three books, then walked through the streets of London toward the railway station."
]
_ = try engine.phonemize(texts[0],language:.english)
var times:[Double] = [], reference = ""
for _ in 0..<31 {
    let start = ProcessInfo.processInfo.systemUptime
    var result = ""
    for text in texts {
        let output = try engine.phonemize(text,language:.english)
        result += output.normalizedText + "\n" + output.rawPhonemes + "\n" + output.phonemes + "\n" + String(reflecting:output.diagnostics)
    }
    times.append(ProcessInfo.processInfo.systemUptime - start)
    if reference.isEmpty { reference = result } else { precondition(result == reference) }
}
let row:[String:Any] = ["seconds":times.sorted()[15],"sha256":SHA256.hash(data:Data(reference.utf8)).map{String(format:"%02x",$0)}.joined()]
print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))

// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import Foundation

/// Explicit syntax only: currency symbols, percentages, 24-hour times and ISO
/// dates. Ambiguous slashed dates/identifiers are deliberately left unresolved.
enum StructuredNumbers {
    static func expand(_ text: String, language: PronunciationLanguage) -> String {
        // Every numeric production requires a decimal digit. Italian's lexical
        // hour correction is the one unconditional rule and must still run.
        guard text.unicodeScalars.contains(where: {
            $0.properties.numericType != nil || CharacterSet.decimalDigits.contains($0)
        }) else { return italianHours(text, language: language) }
        var text = text.map { c -> String in
            if c.unicodeScalars.count == 1, c.unicodeScalars.first?.properties.numericType == .decimal,
               let n = c.wholeNumberValue { return String(n) }
            return String(c)
        }.joined()
        text = NumberReadings.contextual(text, language: language)
        let formatter = NumberFormatter(); formatter.numberStyle = .spellOut; formatter.locale = language.locale
        func spell(_ s: String) -> String { (formatter.string(from: NSDecimalNumber(string: s, locale: Locale(identifier: "en_US_POSIX"))) ?? s).replacingOccurrences(of: "\u{00AD}", with: "").replacingOccurrences(of: "〇", with: language == .chinese ? "零" : "ゼロ") }
        let cjk = language == .japanese || language == .chinese
        let left = cjk ? #"(?<![A-Za-z\d/−-])"# : #"(?<![\p{L}\d/−-])"#
        let right = cjk ? #"(?![A-Za-z\d/−-])"# : #"(?![\p{L}\d/−-])"#
        text = replace(text, left + #"(\d{4})-(\d{2})-(\d{2})"# + right) { g in
            guard let y = Int(g[1]), let m = Int(g[2]), let d = Int(g[3]), y >= 1600 else { return g[0] }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = DateComponents(year: y, month: m, day: d)
            guard let date = calendar.date(from: parts), calendar.dateComponents([.year,.month,.day], from: date) == parts else { return g[0] }
            if language == .japanese {
                let month = [4:"し",7:"しち",9:"く"][m] ?? NumberReadings.japaneseInteger(m)
                return NumberReadings.japaneseInteger(y) + "ねん" + month + "がつ" + NumberReadings.japaneseDay(d)
            }
            if language == .chinese {
                let digits = Array("零一二三四五六七八九")
                return g[1].map { String(digits[$0.wholeNumberValue!]) }.joined() + "年" + spell(g[2]) + "月" + spell(g[3]) + "日"
            }
            let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone; format.locale = language.locale
            format.dateStyle = .long; format.timeStyle = .none
            var result = format.string(from: date)
            if language == .french, d == 1 { result = result.replacingOccurrences(of: #"^1\b"#, with: "premier", options: .regularExpression) }
            if language == .english, let ordinal = NumberReadings.englishOrdinal(d) {
                result = result.replacingOccurrences(of: "\\b" + String(d) + ",", with: ordinal + ",", options: .regularExpression)
            }
            return result
        }
        let repeatedUnit = language == .hindi ? #"(?:[ \t]+बजे)?"# : ""
        text = replace(text, #"(?<!:)"# + left + #"([0-2]?\d):([0-5]\d)"# + right + #"(?!:)"# + repeatedUnit) { g in
            guard let h = Int(g[1]), h < 24, let m = Int(g[2]) else { return g[0] }
            let hour = spell(String(h)), minute = spell(String(m))
            switch language {
            case .english: return hour + (m == 0 ? " o'clock" : m < 10 ? " oh " + minute : " " + minute)
            case .spanish: return (h == 1 ? "una hora" : (h == 21 ? "veintiuna" : hour) + " horas") + (m == 0 ? "" : " y " + apocopate(minute) + (m == 1 ? " minuto" : " minutos"))
            case .french: return (h == 1 ? "une heure" : hour + " heures") + (m == 0 ? "" : m == 1 ? " une minute" : " " + minute)
            case .italian: return (h == 1 ? "una" : hour) + (m == 0 ? "" : " e " + (m == 1 ? "un minuto" : minute))
            case .portuguese: return (h == 1 ? "uma hora" : NumberReadings.portugueseFeminine(hour) + " horas") + (m == 0 ? "" : " e " + minute + (m == 1 ? " minuto" : " minutos"))
            case .hindi: return hour + (m == 0 ? " बजे" : " बजकर " + minute + " मिनट" + (g[0].hasSuffix("बजे") ? " पर" : ""))
            case .japanese: return NumberReadings.japaneseCounter(h, unit: "時") + (m == 0 ? "" : NumberReadings.japaneseCounter(m, unit: "分"))
            case .chinese: return (h == 2 ? "两" : hour) + "点" + (m == 0 ? "" : (m < 10 ? "零" : "") + minute + "分")
            }
        }
        text = italianHours(text, language: language)
        let numeric = #"[−-]?\d+(?:[.,\x{00A0}\x{202F}]\d+)*"#
        text = replace(text, left + "(" + numeric + #")\s*[%％]"#) { g in
            let words = TextNormalizer.normalize(g[1], language: language)
            let suffix = ["en":" percent","es":" por ciento","fr":" pour cent","it":" per cento","pt":" por cento","hi":" प्रतिशत","ja":"パーセント","zh":"百分之"][language.rawValue]!
            return language == .chinese ? suffix + words : words + suffix
        }
        // Major/minor names for common explicit currencies. Unsupported currency
        // forms remain visible rather than receiving an invented unit name.
        let names: [String: [String]] = [
            "en":["euro","euros","cent","cents","dollar","dollars"],
            "es":["euro","euros","céntimo","céntimos","dólar","dólares"],
            "fr":["euro","euros","centime","centimes","dollar","dollars"],
            "it":["euro","euro","centesimo","centesimi","dollaro","dollari"],
            "pt":["euro","euros","centavo","centavos","dólar","dólares"],
            "hi":["रुपया","रुपये","पैसा","पैसे","डॉलर","डॉलर"],
            "ja":["円","円","セント","セント","ドル","ドル"],
            "zh":["元","元","分","分","美元","美元"]]
        let allowed: String = language == .hindi ? #"₹|INR|\$|USD"# : language == .japanese ? #"¥|￥|JPY|\$|USD"# : language == .chinese ? #"¥|￥|CNY|元|\$|USD"# : language == .portuguese ? #"R\$|BRL|€|EUR|euros?|\$|USD"# : language == .english ? #"£|GBP|€|EUR|euros?|\$|USD"# : #"€|EUR|euros?|\$|USD"#
        func money(_ amount: String, _ unit: String) -> String? {
            let comma = [.spanish,.french,.italian,.portuguese].contains(language)
            let parts = amount.split(separator: comma ? "," : ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, !parts[0].isEmpty else { return nil }
            let integer = String(parts[0]); let fraction = parts.count == 2 ? String(parts[1]) : ""
            if language == .english, integer.contains(",") {
                let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
                guard (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            }
            guard integer.filter(\.isNumber).count <= 15, fraction.count <= 2, fraction.allSatisfy(\.isNumber) else { return nil }
            let cents = Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
            let dollars = unit == "$" || unit == "USD"
            guard language != .japanese || dollars || cents == 0 else { return nil }
            var major = language == .english ? spell(integer.replacingOccurrences(of: ",", with: "")) : TextNormalizer.normalize(integer, language: language)
            guard !major.unicodeScalars.contains(where: { $0.properties.numericType == .decimal }) else { return nil }
            if language == .spanish { major = apocopate(major) }
            var units = names[language.rawValue]!
            if language == .portuguese, unit == "R$" || unit == "BRL" { units = ["real","reais","centavo","centavos","dólar","dólares"] }
            if language == .english, unit == "£" || unit == "GBP" { units = ["pound","pounds","penny","pence","dollar","dollars"] }
            if language == .italian, major == "uno" { major = "un" }
            let one = Int(integer) == 1 || Int(integer) == -1
            let space = cjk ? "" : " "
            var value = major + space + units[(dollars ? 4 : 0) + (one ? 0 : 1)]
            if cents > 0 {
                if language == .chinese && !dollars {
                    let jiao = cents / 10, fen = cents % 10
                    value += jiao > 0 ? spell(String(jiao)) + "角" : "零"
                    if fen > 0 { value += spell(String(fen)) + "分" }
                    return value
                }
                let join = ["en":" and ","es":" con ","fr":" et ","it":" e ","pt":" e ","hi":" और ","ja":"","zh":""][language.rawValue]!
                var minor = spell(String(cents)); if language == .spanish { minor = apocopate(minor) }
                var minorUnit = units[cents == 1 ? 2 : 3]
                if dollars && language == .spanish { minorUnit = cents == 1 ? "centavo" : "centavos" }
                if dollars && language == .hindi { minorUnit = "सेंट" }
                if !dollars && language == .portuguese && unit != "R$" && unit != "BRL" { minorUnit = cents == 1 ? "cêntimo" : "cêntimos" }
                if language == .italian, cents == 1 { minor = "un" }
                value += join + minor + space + minorUnit
            }
            return value
        }
        text = replace(text, left + "(" + allowed + #")\s*("# + numeric + ")" + right) { g in money(g[2],g[1]) ?? g[0] }
        text = replace(text, left + "(" + numeric + #")\s*("# + allowed + ")" + right) { g in money(g[1],g[2]) ?? g[0] }
        return NumberReadings.countedNouns(text, language: language)
    }

    static func apocopate(_ text: String) -> String {
        if text.hasSuffix("veintiuno") { return String(text.dropLast(9)) + "veintiún" }
        if text.hasSuffix("uno") { return String(text.dropLast(3)) + "un" }
        return text
    }

    private static func italianHours(_ text: String, language: PronunciationLanguage) -> String {
        guard language == .italian else { return text }
        return text.replacingOccurrences(of: #"\balle una\b"#, with: "all'una", options: .regularExpression)
            .replacingOccurrences(of: #"\bAlle una\b"#, with: "All'una", options: .regularExpression)
    }

    private static func replace(_ text: String, _ pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = CompiledTextRules.expression(pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: transform(groups)) }
        }
        return result
    }
}

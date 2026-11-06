// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import Foundation

/// Broad pronunciation profiles, not a claim to cover every regional variety.
public enum SpanishDialect: String, CaseIterable, Sendable, Codable {
    case spain
    case latinAmerica
    /// Rioplatense broad profile: seseo and voiceless /ʃ/ for consonantal y/ll.
    /// Argentina also has voiced /ʒ/ and other regional varieties; this is not
    /// a claim to model every Argentine accent or the voice's pitch contours.
    case argentina

    /// Resolve regional book metadata without treating bare `es` as a country.
    /// A user's explicit pronunciation selection should take precedence.
    public init?(languageTag: String) {
        let parts = languageTag.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard parts.first == "es", parts.count >= 2 else { return nil }
        let subtags = parts.dropFirst().prefix { $0.count != 1 }
        guard let region = subtags.first(where: { $0.count == 2 || $0 == "419" }).map(String.init) else { return nil }
        if region == "es" { self = .spain }
        else if region == "ar" { self = .argentina }
        else if ["419", "mx", "co", "cl", "pe", "uy", "ve", "ec", "bo", "py", "cr", "cu", "do", "gt", "hn", "ni", "pa", "pr", "sv"].contains(region) { self = .latinAmerica }
        else { return nil }
    }
    public var languageTag: String {
        switch self {
        case .spain: "es-ES"
        case .latinAmerica: "es-419"
        case .argentina: "es-AR"
        }
    }
}

/// Independently authored, deterministic Spanish spelling-to-pronunciation rules.
/// See docs/SPANISH-POLISH-2026-10.md for linguistic sources and lexical limits.
public struct SpanishPhonemizer: Sendable {
    public init() {}

    public func phonemize(_ text: String, dialect: SpanishDialect = .spain, adverbDoubleStress: Bool = false) -> String {
        let tokens = expandHonorifics(in: tokenize(text.precomposedStringWithCanonicalMapping))
        var output = ""
        var previousSound: String?
        for index in tokens.indices {
            let token = tokens[index]
            guard token.isWord else {
                output += token.text
                // Horizontal spacing joins a phrase; punctuation and line breaks reset it.
                if !isJoiningSpace(token.text) { previousSound = nil }
                continue
            }
            let word = token.text.lowercased()
            let hasNeighbor = (index >= 2 && tokens[index - 2].isWord && isJoiningSpace(tokens[index - 1].text))
                || (index + 2 < tokens.count && tokens[index + 2].isWord && isJoiningSpace(tokens[index + 1].text))
            let spelling = SpanishLexicon.spelling(for: word, dialect: dialect)
            var sounds = spell(spelling, dialect: dialect)
            let nuclei = vowelNuclei(sounds)
            let stress = stressPosition(word: spelling, sounds: sounds, nuclei: nuclei,
                                        unstressed: hasNeighbor && isUnstressed(word, at: index, in: tokens), dialect: dialect)
            // Opt-in: derived -mente adverbs retain the adjective's lexical stress.
            // Both tonic syllables are explicit; relative acoustic prominence is
            // model-dependent and must be evaluated with native listeners.
            var stresses = Set(stress.map { [$0] } ?? [])
            if adverbDoubleStress, let base = adverbBase(word) {
                let baseSounds = spell(base, dialect: dialect)
                if let baseStress = stressPosition(word: base, sounds: baseSounds,
                    nuclei: vowelNuclei(baseSounds), unstressed: false, dialect: dialect) {
                    stresses = [baseStress, baseSounds.count] // /men/ starts at suffix onset.
                }
            }
            makeGlides(&sounds, nuclei: nuclei)
            for position in sounds.indices {
                if stresses.contains(position) { output += "ˈ" }
                let underlying = sounds[position].ipa
                var realized = underlying
                switch underlying {
                case "b": if previousSound != nil && !Self.nasals.contains(previousSound ?? "") { realized = "β" }
                case "d": if previousSound != nil && !Self.nasals.contains(previousSound ?? "") && previousSound != "l" { realized = "ð" }
                case "g": if previousSound != nil && !Self.nasals.contains(previousSound ?? "") { realized = "ɣ" }
                case "n":
                    if position + 1 < sounds.count {
                        let next = sounds[position + 1].ipa
                        if ["p", "b", "m"].contains(next) { realized = "m" }
                        else if ["k", "g", "x"].contains(next) { realized = "ŋ" }
                    }
                default: break
                }
                output += realized
                previousSound = underlying
            }
        }
        return output
    }

    private func adverbBase(_ word: String) -> String? {
        guard word.hasSuffix("mente"), word.count > 6,
              !Self.nonAdverbMenteForms.contains(word) else { return nil }
        let base = String(word.dropLast(5))
        // Productive feminine -a, invariant -al/-ble bases plus a conservative set of other
        // adjectives. Never interpret comente/aumente/vehemente as adverbs.
        if base.hasSuffix("a") || base.hasSuffix("al") || base.hasSuffix("ble")
            || Self.invariantAdverbBases.contains(base) { return base }
        return nil
    }

    // Verb forms ending in the same letters as derived adverbs. A suffix alone
    // is not sufficient evidence; retain their ordinary lexical stress.
    private static let nonAdverbMenteForms: Set<String> = [
        "lamente", "ornamente", "desornamente", "fundamente", "reglamente",
        "parlamente", "juramente", "testamente", "sacramente"
    ]

    private static let invariantAdverbBases: Set<String> = [
        "grande", "feliz", "infeliz", "fácil", "difícil", "ágil", "débil", "hábil",
        "cortés", "descortés", "común", "tenaz", "veloz", "útil", "inútil", "igual", "normal", "natural", "general", "real", "especial",
        "total", "formal", "fiel", "cruel", "cordial", "amable", "probable", "posible",
        "imposible", "simple", "breve", "leve", "suave", "fuerte", "libre"
    ]

    private struct Token {
        var text: String
        var isWord: Bool
    }

    private struct Sound {
        var ipa: String
        var vowel: Character? = nil
        var accented = false
        var beginsHiatus = false
        var finalY = false
    }

    private static let nasals: Set<String> = ["m", "n", "ɲ", "ŋ"]
    // Grammatical classes, not a pronunciation exception dictionary. Ambiguous
    // tonic uses (e.g. quotation or contrastive emphasis) require syntax/prosody.
    private static let functionWords: Set<String> = [
        "el", "la", "los", "las", "lo", "un", "una", "unos", "unas",
        "me", "te", "se", "nos", "os", "le", "les", "mi", "mis", "tu", "tus", "su", "sus",
        "a", "ante", "bajo", "con", "contra", "de", "desde", "durante", "en", "entre", "hacia", "hasta", "mediante",
        "para", "por", "sin", "sobre", "tras", "al", "del", "y", "e", "o", "u", "ni", "que", "si", "pero", "porque", "aunque", "sino",
        // Unaccented relative/conjunction; interrogative cuándo keeps its stress.
        "cuando", "donde", "adonde", "quien", "quienes", "cuyo", "cuya", "cuyos", "cuyas",
        // Literary adversative conjunction; accented más remains tonic.
        "mas", "tan"
    ]

    private func isUnstressed(_ word: String, at index: Int, in tokens: [Token]) -> Bool {
        func neighbor(_ offset: Int) -> String? {
            let target = index + offset * 2
            guard tokens.indices.contains(target), tokens[target].isWord else { return nil }
            // Every intervening separator must join the same phrase.
            let lower = min(index, target), upper = max(index, target)
            guard stride(from: lower + 1, to: upper, by: 2).allSatisfy({ isJoiningSpace(tokens[$0].text) }) else { return nil }
            return tokens[target].text.lowercased()
        }
        let preceding = neighbor(-1), following = neighbor(1)
        // With no following nominal, these are tonic pronouns/numerals, not articles:
        // oír una; una a casar; una de ellas. Do not change una casa/una vez.
        if ["una", "unos", "unas"].contains(word),
           following == nil || ["a", "de", "con", "sin", "por", "para", "en"].contains(following ?? "") {
            return false
        }
        if word == "como", following != "y", following != "o" {
            // Restricted syntactic evidence; bare como remains tonic because it can
            // be the first-person verb. Accented cómo never enters this branch.
            if ["es", "son", "era", "eran", "fue", "fueron", "será", "serán", "sería", "serían",
                "sea", "sean", "fuera", "fueran", "tanto", "tanta", "tantos", "tantas"].contains(preceding ?? "")
                || neighbor(-2) == "tan"
                || ["él", "ella", "ellos", "ellas", "tú", "usted", "ustedes", "vosotros", "vosotras"].contains(following ?? "")
                // Nadie supplies a subject/comparison, not an edible nominal object.
                // Do not generalize this to nada, alguien, or bare infinitives.
                || following == "nadie"
                || preceding == "tal"
                || (preceding == "así" && ["es", "era", "está", "estaba", "son", "están"].contains(following ?? ""))
                || comparativeNominal(preceding, before: neighbor(-2), following: following) {
                return true
            }
        }
        // Treatment titles attach to a following capitalized name. Nouns such as
        // un don divino, and citation forms, keep their own lexical stress.
        if ["don", "doña", "fray", "sor"].contains(word), following != nil,
           tokens[index + 2].text.first?.isUppercase == true,
           !["el", "la", "un", "una", "mi", "tu", "su"].contains(preceding ?? "") {
            return true
        }
        if word == "aun", ["y", "ni"].contains(preceding ?? "") { return true }
        return Self.functionWords.contains(word)
    }

    /// Restricted evidence for nominal comparisons. Do not remove stress from
    /// the first-person verb merely because an article follows it ("como la sopa").
    /// A reviewed nominal antecedent plus a following comparison argument keeps
    /// this bounded and independent of platform-dependent POS guesses.
    private func comparativeNominal(_ preceding: String?, before: String?, following: String?) -> Bool {
        guard let preceding, Self.comparisonAntecedents.contains(preceding),
              let following, !Self.verbalComoGuards.contains(before ?? ""),
              !Self.comparisonTailGuards.contains(following) else { return false }
        return true
    }

    private static let comparisonAntecedents: Set<String> = [
        "codo", "codos", "alfiler", "alfileres", "corbata", "corbatas",
        "ojos", "manos", "dedos", "labios", "dientes", "cabellos",
        "rostro", "rostros", "mirada", "miradas", "voz", "voces",
        "sonrisa", "sonrisas", "lágrima", "lágrimas", "palabra", "palabras",
        "silencio", "silencios", "sombra", "sombras", "luz", "luces",
        "piedra", "piedras", "espejo", "espejos", "flecha", "flechas",
        "casa", "casas", "libro", "libros", "espada", "espadas",
        "modo", "manera", "forma", "ejemplo", "ejemplos"
    ]
    private static let verbalComoGuards: Set<String> = [
        "yo", "me", "no", "nunca", "jamás", "siempre", "también", "solo", "sólo"
    ]
    private static let comparisonTailGuards: Set<String> = [
        "y", "o", "pero", "porque", "cuando", "donde", "si", "aunque"
    ]

    // Expansion is confined to temporary G2P tokens: callers retain the written
    // abbreviation and its original UTF-16 ranges. The period is not a pause.
    // Treatment conventions: https://www.fundeu.es/consulta/tratamiento-abreviatura-15/
    private func expandHonorifics(in original: [Token]) -> [Token] {
        var tokens = original
        func name(at index: Int) -> Bool {
            guard original.indices.contains(index), original[index].isWord else { return false }
            let text = original[index].text
            guard text.count > 1, text.first?.isUppercase == true,
                  text.dropFirst().contains(where: \.isLowercase) else { return false }
            // Do not expand title-looking portions of filenames or paths.
            if original.indices.contains(index + 1) {
                let separator = original[index + 1].text
                if separator.contains("/") || separator.contains("\\") || separator.contains("_") { return false }
                if separator == ".", original.indices.contains(index + 2), original[index + 2].isWord { return false }
            }
            return true
        }
        for index in original.indices where original[index].isWord {
            let title = original[index].text
            guard ["D", "Sr"].contains(title), original.indices.contains(index + 2) else { continue }
            let separator = original[index + 1].text
            guard separator.first == ".", isJoiningSpace(String(separator.dropFirst())) else { continue }
            if index > 0 {
                let before = original[index - 1].text
                if before.contains("/") || before.contains("\\") || before.contains("_") || before.contains("@") { continue }
                // A chain of personal initials, or an explicitly named letter/section.
                if index >= 2 {
                    let preceding = original[index - 2].text
                    if preceding.count == 1 && before.contains(".") { continue }
                    if isJoiningSpace(before), Self.literalInitialContexts.contains(preceding.lowercased()) { continue }
                }
            }
            var nameIndex = index + 2
            if title == "D" {
                // Capitalization alone would incorrectly expand D. García/Smith.
                guard name(at: nameIndex), Self.donGivenNames.contains(original[nameIndex].text) else { continue }
            } else {
                // Surnames can begin with de, del, or de + a definite article.
                if ["de", "del"].contains(original[nameIndex].text) {
                    guard original.indices.contains(nameIndex + 2), isJoiningSpace(original[nameIndex + 1].text) else { continue }
                    let usesDe = original[nameIndex].text == "de"
                    nameIndex += 2
                    if usesDe, ["la", "las", "los"].contains(original[nameIndex].text) {
                        guard original.indices.contains(nameIndex + 2), isJoiningSpace(original[nameIndex + 1].text) else { continue }
                        nameIndex += 2
                    }
                }
                guard name(at: nameIndex) else { continue }
            }
            tokens[index].text = title == "D" ? "Don" : "Señor"
            tokens[index + 1].text = String(separator.dropFirst())
        }
        return tokens
    }

    // Reviewed given-name evidence, not a claim to identify every personal name.
    // Unknown D. names stay unchanged rather than guessing that an initial is a title.
    private static let donGivenNames: Set<String> = [
        "José", "Alejandro", "Juan", "Pedro", "Francisco", "Antonio", "Manuel", "Luis",
        "Carlos", "Fernando", "Alfonso", "Diego", "Ramón", "Rafael", "Miguel", "Joaquín",
        "Enrique", "Vicente", "Andrés", "Javier", "Pablo", "Tomás", "Ángel", "Federico"
    ]
    private static let literalInitialContexts: Set<String> = [
        "letra", "inicial", "apartado", "sección", "capítulo", "romano", "numeral", "archivo", "ruta"
    ]

    private func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for character in text {
            let isWord = character.isLetter
            if let last = tokens.indices.last, tokens[last].isWord == isWord {
                tokens[last].text.append(character)
            } else {
                tokens.append(Token(text: String(character), isWord: isWord))
            }
        }
        return tokens
    }

    private func isJoiningSpace(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isWhitespace && !$0.isNewline }
    }

    private func baseVowel(_ character: Character) -> Character? {
        switch character {
        case "a", "á": return "a"
        case "e", "é": return "e"
        case "i", "í": return "i"
        case "o", "ó": return "o"
        case "u", "ú", "ü": return "u"
        default: return nil
        }
    }

    private func spell(_ word: String, dialect: SpanishDialect) -> [Sound] {
        let letters = Array(word)
        var sounds: [Sound] = []
        var index = 0
        let softC = dialect == .spain ? "θ" : "s"
        while index < letters.count {
            let letter = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            let after: Character? = index + 2 < letters.count ? letters[index + 2] : nil
            let frontVowel = next.flatMap(baseVowel).map { $0 == "e" || $0 == "i" } ?? false
            if let vowel = baseVowel(letter) {
                sounds.append(Sound(ipa: String(vowel), vowel: vowel, accented: "áéíóú".contains(letter),
                                    beginsHiatus: index > 0 && letters[index - 1] == "·"))
                index += 1
                continue
            }
            var ipa: String
            switch letter {
            case "h", "·": index += 1; continue
            case "c":
                if next == "h" { ipa = "ʧ"; index += 1 }
                else { ipa = frontVowel ? softC : "k" }
            case "q":
                ipa = "k"
                if next == "u", let after, let vowel = baseVowel(after), vowel == "e" || vowel == "i" { index += 1 }
            case "g":
                ipa = frontVowel ? "x" : "g"
                if next == "u", let after, let vowel = baseVowel(after), vowel == "e" || vowel == "i" { index += 1 }
            case "j": ipa = "x"
            case "z": ipa = softC
            case "b", "v": ipa = "b"
            case "ñ": ipa = "ɲ"
            case "l":
                if next == "l" { ipa = dialect == .argentina ? "ʃ" : "ʝ"; index += 1 }
                else { ipa = "l" }
            case "r":
                if next == "r" { ipa = "r"; index += 1 }
                else if index == 0 || "lns".contains(letters[index - 1])
                    || hasTrilledPrefixBoundary(word, at: index) { ipa = "r" }
                else { ipa = "ɾ" }
            case "y":
                if letters.count == 1 || index == letters.count - 1 {
                    sounds.append(Sound(ipa: "i", vowel: "i", finalY: letters.count > 1))
                    index += 1; continue
                }
                ipa = dialect == .argentina ? "ʃ" : "ʝ"
            case "x":
                // Initial x is normally /s/ in adapted Greek-derived vocabulary.
                if index != 0 && !hasInitialXBase(word, at: index) { sounds.append(Sound(ipa: "k")) }
                ipa = "s"
            case "w": ipa = "w"
            case "k", "p", "t", "d", "f", "s", "m", "n": ipa = String(letter)
            default:
                // Foreign letters are retained, not silently deleted or mapped
                // through an English pronunciation guess.
                ipa = String(letter)
            }
            sounds.append(Sound(ipa: ipa))
            index += 1
        }
        return sounds
    }

    private func hasInitialXBase(_ word: String, at index: Int) -> Bool {
        // Productive compounds preserve initial /s/: anti-xenófobo, mega-xilófono.
        // Do not change intervocalic x in unrelated words such as antioxidante.
        let prefix = String(word.prefix(index))
        let base = word.dropFirst(index)
        return ["anti", "mega", "mini"].contains(prefix)
            && ["xen", "xil", "xer"].contains(where: { base.hasPrefix($0) })
    }

    private func hasTrilledPrefixBoundary(_ word: String, at index: Int) -> Bool {
        // These boundaries are lexical/morphological, unlike the tap in brazo/abrir.
        (index == 3 && word.hasPrefix("subr"))
            || (index == 2 && word.hasPrefix("abrog"))
            || (index == 6 && word.hasPrefix("ciudadreal"))
    }

    private func isOpen(_ vowel: Character) -> Bool { "aeo".contains(vowel) }

    private func canShareNucleus(_ group: [Int], adding next: Int, sounds: [Sound]) -> Bool {
        let candidate = group + [next]
        let vowels = candidate.compactMap { sounds[$0].vowel }
        guard vowels.count <= 3 else { return false }
        guard zip(vowels, vowels.dropFirst()).allSatisfy({ $0 != $1 }) else { return false }
        let openCount = vowels.filter(isOpen).count
        guard openCount <= 1 else { return false }
        if openCount > 0 && candidate.contains(where: { sounds[$0].accented && !isOpen(sounds[$0].vowel ?? "a") }) {
            return false
        }
        // A triphthong has a central open vowel and two unstressed closed vowels.
        if vowels.count == 3 { return isOpen(vowels[1]) && !isOpen(vowels[0]) && !isOpen(vowels[2]) }
        return true
    }

    private func vowelNuclei(_ sounds: [Sound]) -> [[Int]] {
        var nuclei: [[Int]] = []
        for index in sounds.indices where sounds[index].vowel != nil {
            if let last = nuclei.indices.last, let preceding = nuclei[last].last,
               preceding == index - 1, !sounds[index].beginsHiatus, canShareNucleus(nuclei[last], adding: index, sounds: sounds) {
                nuclei[last].append(index)
            } else {
                nuclei.append([index])
            }
        }
        return nuclei
    }

    private func nucleusHead(_ nucleus: [Int], sounds: [Sound]) -> Int {
        // The second of two closed vowels is the nucleus unless an accent says otherwise.
        nucleus.first(where: { sounds[$0].accented })
            ?? nucleus.first(where: { isOpen(sounds[$0].vowel ?? "i") })
            ?? nucleus.last(where: { !sounds[$0].finalY })
            ?? nucleus[nucleus.count - 1]
    }

    private func makeGlides(_ sounds: inout [Sound], nuclei: [[Int]]) {
        for nucleus in nuclei where nucleus.count > 1 {
            let head = nucleusHead(nucleus, sounds: sounds)
            for index in nucleus where index != head {
                sounds[index].ipa = sounds[index].vowel == "i" ? "j" : "w"
            }
        }
    }

    private func stressPosition(word: String, sounds: [Sound], nuclei: [[Int]],
                                unstressed: Bool, dialect: SpanishDialect) -> Int? {
        guard !unstressed, !nuclei.isEmpty else { return nil }
        let stressedNucleus: Int
        if let accented = nuclei.firstIndex(where: { $0.contains(where: { sounds[$0].accented }) }) {
            stressedNucleus = accented
        } else {
            let letters = Array(word)
            let last = letters.last ?? " "
            let endsInVowel = baseVowel(last) != nil
            let endsInVowelNS = (last == "n" || last == "s") && letters.count >= 2 && baseVowel(letters[letters.count - 2]) != nil
            stressedNucleus = max(0, nuclei.count - ((endsInVowel || endsInVowelNS) ? 2 : 1))
        }
        if stressedNucleus == 0 { return 0 }
        let start = nuclei[stressedNucleus][0]
        let previousEnd = nuclei[stressedNucleus - 1].last ?? 0
        let consonantCount = start - previousEnd - 1
        if consonantCount == 0 { return start }
        if consonantCount == 1 { return start - 1 }
        let pair = sounds[start - 2].ipa + sounds[start - 1].ipa
        let onsets: Set<String> = ["pɾ", "bɾ", "tɾ", "dɾ", "kɾ", "gɾ", "fɾ", "pl", "bl", "kl", "gl", "fl"]
        if onsets.contains(pair) || (pair == "tl" && dialect != .spain) { return start - 2 }
        return start - 1
    }
}

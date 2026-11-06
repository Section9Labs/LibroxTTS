import Foundation
import NaturalLanguage

/// Language identity is independent of a voice or inference backend.
public enum NarrationLanguage {
    /// Pinned Supertonic 3 helper's languages. `na` is inference, not a language.
    public static let textNativeCodes = ["en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es",
        "et", "fi", "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "tr", "uk", "vi"]
    public static func normalize(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = Language(identifier: value) { return existing.rawValue }
        let base = String(value.replacingOccurrences(of: "_", with: "-").split(separator: "-").first ?? "")
        let aliases = ["eng":"en", "spa":"es", "fra":"fr", "fre":"fr", "ita":"it", "por":"pt",
            "jpn":"ja", "zho":"zh", "chi":"zh", "hin":"hi", "deu":"de", "ger":"de", "rus":"ru",
            "kor":"ko", "ara":"ar", "bul":"bg", "ces":"cs", "cze":"cs", "dan":"da", "ell":"el",
            "gre":"el", "est":"et", "fin":"fi", "hrv":"hr", "hun":"hu", "ind":"id", "lit":"lt",
            "lav":"lv", "nld":"nl", "dut":"nl", "pol":"pl", "ron":"ro", "rum":"ro", "slk":"sk",
            "slo":"sk", "slv":"sl", "swe":"sv", "tur":"tr", "ukr":"uk", "vie":"vi",
            "english":"en", "spanish":"es", "german":"de", "russian":"ru", "korean":"ko"]
        if let alias = aliases[base] { return alias }
        guard base.count == 2, base.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { return nil }
        return base
    }
    public static func detect(metadata: String?, sample: String) -> String? {
        if let declared = normalize(metadata) { return declared }
        let excerpt = String(sample.prefix(4_000))
        guard excerpt.filter(\.isLetter).count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(excerpt)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.75 else { return nil }
        return normalize(best.key.rawValue)
    }
    public static func name(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }
    public static func sampleText(_ code: String) -> String? {
        if let language = Language(rawValue: code) { return language.sampleText }
        return [
            "ko":"저녁 햇살이 조용한 방으로 들어오고 이야기가 시작되었습니다.",
            "ar":"دخل ضوء المساء إلى الغرفة الهادئة، وبدأت الحكاية.",
            "bg":"Вечерната светлина изпълни тихата стая и историята започна.",
            "cs":"Večerní světlo pronikalo do tichého pokoje a příběh začal.",
            "da":"Aftenlyset faldt ind i det stille rum, og historien begyndte.",
            "de":"Das Abendlicht fiel in das stille Zimmer, und die Geschichte begann.",
            "el":"Το φως του δειλινού μπήκε στο ήσυχο δωμάτιο και η ιστορία άρχισε.",
            "et":"Õhtuvalgus langes vaiksesse tuppa ja lugu algas.",
            "fi":"Iltavalo täytti hiljaisen huoneen, ja tarina alkoi.",
            "hr":"Večernje svjetlo ispunilo je tihu sobu i priča je počela.",
            "hu":"Az esti fény betöltötte a csendes szobát, és elkezdődött a történet.",
            "id":"Cahaya senja memasuki ruangan yang tenang, dan cerita pun dimulai.",
            "lt":"Vakaro šviesa užliejo tylų kambarį, ir istorija prasidėjo.",
            "lv":"Vakara gaisma piepildīja kluso istabu, un stāsts sākās.",
            "nl":"Het avondlicht viel in de stille kamer en het verhaal begon.",
            "pl":"Wieczorne światło wypełniło cichy pokój i rozpoczęła się opowieść.",
            "ro":"Lumina serii a umplut camera liniștită și povestea a început.",
            "ru":"Вечерний свет наполнил тихую комнату, и началась история.",
            "sk":"Večerné svetlo preniklo do tichej izby a príbeh sa začal.",
            "sl":"Večerna svetloba je napolnila tiho sobo in zgodba se je začela.",
            "sv":"Kvällsljuset föll in i det tysta rummet och berättelsen började.",
            "tr":"Akşam ışığı sessiz odayı doldurdu ve hikâye başladı.",
            "uk":"Вечірнє світло наповнило тиху кімнату, і почалася історія.",
            "vi":"Ánh chiều tràn vào căn phòng yên tĩnh, và câu chuyện bắt đầu."
        ][code]
    }
}

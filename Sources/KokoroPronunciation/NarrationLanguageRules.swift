import Foundation

/// Bounded literal reporting cues. These establish explicit speakers, not general
/// coreference, sentiment, or gender from a person's name. All model languages
/// have a profile; each profile is exercised by source-range/cast fixtures.
public enum NarrationLanguageRules {
    /// Reuse literal attribution grammar for seam timing without inventing a
    /// speaker or changing the cast. The caller still decides whether the source
    /// actually borders quoted speech.
    public static func beginsWithNamedSpeechTag(_ text: String, language: String) -> Bool {
        (try? MultilingualSpeakerAttribution.Matcher(language: language).suffix(text)) != nil
    }
    public static func endsWithNamedSpeechTag(_ text: String, language: String) -> Bool {
        (try? MultilingualSpeakerAttribution.Matcher(language: language).prefix(text)) != nil
    }
    public struct Profile: Sendable {
        public let reportingVerbs: [String]
        public let excludedNames: Set<String>
        public let directionCues: [String]
        public let conjunctions: Set<String>
    }
    private static func p(_ verbs: String, _ excluded: String, _ directions: String, _ conjunctions: String) -> Profile {
        .init(reportingVerbs: verbs.components(separatedBy: "|"),
              excludedNames: Set(excluded.components(separatedBy: "|")),
              directionCues: directions.components(separatedBy: "|"),
              conjunctions: Set(conjunctions.components(separatedBy: "|")))
    }
    public static let profiles: [String: Profile] = [
        "en": p("said|asked|replied|whispered", "he|she|they|we|i|you|someone|nobody|not|never|thought|wondered|imagined|the", "whispering|shouting|laughing|crying|quietly|aside", "and|or|but"),
        "es": p("dijo|preguntó|respondió|susurró", "él|ella|ellos|ellas|yo|tú|alguien|nadie|no|nunca|pensó|pensaba|imaginó|soñó|el|la", "susurrando|gritando|riendo|llorando|aparte", "y|o|pero"),
        "fr": p("dit|demanda|répondit|murmura|cria|ajouta", "il|elle|ils|elles|je|tu|nous|vous|on|quelqu’un|personne|pas|jamais|le|la|les", "en chuchotant|en criant|en riant|en pleurant|à part", "et|ou|mais"),
        "de": p("sagte|fragte|antwortete|flüsterte|rief|erwiderte", "er|sie|es|ich|du|wir|ihr|jemand|niemand|nicht|nie|der|die|das", "flüsternd|schreiend|lachend|weinend|beiseite", "und|oder|aber"),
        "it": p("disse|chiese|rispose|sussurrò|gridò|aggiunse", "lui|lei|loro|io|tu|noi|voi|qualcuno|nessuno|non|mai|il|la", "sussurrando|gridando|ridendo|piangendo|a parte", "e|o|ma"),
        "pt": p("disse|perguntou|respondeu|sussurrou|gritou|acrescentou", "ele|ela|eles|elas|eu|tu|nós|vós|você|alguém|ninguém|não|nunca|o|a", "sussurrando|gritando|rindo|chorando|à parte", "e|ou|mas"),
        "nl": p("zei|vroeg|antwoordde|fluisterde|riep", "hij|zij|ze|ik|jij|wij|we|jullie|iemand|niemand|niet|nooit|de|het", "fluisterend|schreeuwend|lachend|huilend|terzijde", "en|of|maar"),
        "da": p("sagde|spurgte|svarede|hviskede|råbte", "han|hun|de|jeg|du|vi|i|nogen|ingen|ikke|inte|aldrig|den|det", "hviskende|råbende|leende|grædende|afsides", "og|eller|men"),
        "sv": p("sade|sa|frågade|svarade|viskade|ropade", "han|hon|de|jag|du|vi|ni|någon|ingen|ikke|inte|aldrig|den|det", "viskande|skrikande|skrattande|gråtande|avsides", "och|eller|men"),
        "fi": p("sanoi|kysyi|vastasi|kuiskasi|huusi", "hän|he|minä|sinä|me|te|joku|kukaan|ei|se", "kuiskaten|huutaen|nauraen|itkien|sivuun", "ja|tai|mutta"),
        "et": p("ütles|küsis|vastas|sosistas|hüüdis", "ta|tema|nad|mina|sina|meie|teie|keegi|ei|see", "sosistades|hüüdes|naerdes|nuttes|kõrvale", "ja|või|aga"),
        "lv": p("teica|jautāja|atbildēja|čukstēja|kliedza", "viņš|viņa|viņi|viņas|es|tu|mēs|jūs|kāds|neviens|ne", "čukstot|kliedzot|smejoties|raudot|sāņus", "un|vai|bet"),
        "lt": p("pasakė|paklausė|atsakė|sušnabždėjo|sušuko", "jis|ji|jie|jos|aš|tu|mes|jūs|kažkas|niekas|ne", "šnabždėdamas|šnabždėdama|šaukdamas|juokdamasis|verkdamas", "ir|ar|bet"),
        "pl": p("powiedział|powiedziała|zapytał|zapytała|odpowiedział|odpowiedziała|szepnął|szepnęła", "on|ona|oni|one|ja|ty|my|wy|ktoś|nikt|nie|ten|ta", "szeptem|krzycząc|śmiejąc się|płacząc|na stronie", "i|lub|ale"),
        "cs": p("řekl|řekla|zeptal se|zeptala se|odpověděl|odpověděla|zašeptal|zašeptala", "on|ona|oni|ony|já|ty|my|vy|někdo|nikdo|ne|ten|ta", "šeptem|křičíc|se smíchem|s pláčem|stranou", "a|nebo|ale"),
        "sk": p("povedal|povedala|spýtal sa|spýtala sa|odpovedal|odpovedala|zašepkal|zašepkala", "on|ona|oni|ony|ja|ty|my|vy|niekto|nikto|nie|ten|tá", "šepotom|kričiac|so smiechom|s plačom|bokom", "a|alebo|ale"),
        "sl": p("je rekel|je rekla|rekel je|rekla je|rekel|rekla|vprašal|vprašala|odgovoril|odgovorila|zašepetal|zašepetala", "on|ona|oni|one|jaz|ti|mi|vi|nekdo|nihče|ne|ta", "šepetaje|kriče|s smehom|jokaje|zase", "in|ali|ampak"),
        "hr": p("je rekao|je rekla|rekao je|rekla je|rekao|rekla|upitao|upitala|odgovorio|odgovorila|šapnuo|šapnula", "on|ona|oni|one|ja|ti|mi|vi|netko|nitko|ne|taj|ta", "šapćući|vičući|smijući se|plačući|u stranu", "i|ili|ali"),
        "bg": p("каза|попита|отговори|прошепна|извика", "той|тя|те|аз|ти|ние|вие|някой|никой|не|този|тази", "шепнешком|крещейки|смеейки се|плачейки|настрани", "и|или|но"),
        "ru": p("сказал|сказала|спросил|спросила|ответил|ответила|прошептал|прошептала", "он|она|они|я|ты|мы|вы|кто-то|никто|не|этот|эта", "шёпотом|шепотом|крича|смеясь|плача|в сторону", "и|или|но"),
        "uk": p("сказав|сказала|запитав|запитала|відповів|відповіла|прошепотів|прошепотіла", "він|вона|вони|я|ти|ми|ви|хтось|ніхто|не|цей|ця", "пошепки|кричачи|сміючись|плачучи|убік", "і|й|або|але"),
        "ro": p("spuse|zise|întrebă|răspunse|șopti|strigă", "el|ea|ei|ele|eu|tu|noi|voi|cineva|nimeni|nu|acest|această", "în șoaptă|strigând|râzând|plângând|aparte", "și|sau|dar"),
        "hu": p("azt mondta|mondta|kérdezte|válaszolta|suttogta|kiáltotta", "ő|ők|én|te|mi|ti|valaki|senki|nem|ez|az", "suttogva|kiáltva|nevetve|sírva|félre", "és|vagy|de"),
        "el": p("είπε|ρώτησε|απάντησε|ψιθύρισε|φώναξε", "αυτός|αυτή|αυτοί|εγώ|εσύ|εμείς|εσείς|κάποιος|κανείς|δεν|ο|η", "ψιθυριστά|φωνάζοντας|γελώντας|κλαίγοντας|κατά μέρος", "και|ή|αλλά"),
        "tr": p("dedi|sordu|yanıtladı|cevap verdi|fısıldadı|bağırdı", "o|onlar|ben|sen|biz|siz|biri|kimse|değil|bu|şu", "fısıldayarak|bağırarak|gülerek|ağlayarak|kendi kendine", "ve|veya|ama"),
        "id": p("berkata|bertanya|menjawab|berbisik|berseru", "dia|ia|mereka|aku|saya|kamu|kami|kita|seseorang|siapa|tidak|sang", "berbisik|berteriak|tertawa|menangis|menyamping", "dan|atau|tetapi"),
        "vi": p("nói|hỏi|đáp|trả lời|thì thầm|kêu lên", "anh|cô|ông|bà|họ|tôi|bạn|chúng|ai|người|không", "thì thầm|hét lên|cười|khóc|nói riêng", "và|hoặc|nhưng"),
        "ar": p("قال|قالت|سأل|سألت|أجاب|أجابت|همس|همست", "هو|هي|هم|هن|أنا|أنت|نحن|أحد|لم|ليس|لا|الرجل|المرأة", "بهمس|بصوت خافت|صارخا|ضاحكا|باكيا|جانبا", "و|أو|لكن"),
        "hi": p("कहा|पूछा|जवाब दिया|फुसफुसाया|चिल्लाया", "वह|वे|मैं|तुम|हम|आप|उसने|उन्होंने|कोई|नहीं", "फुसफुसाते हुए|चिल्लाते हुए|हँसते हुए|रोते हुए|एक ओर", "और|या|लेकिन"),
        "ja": p("言った|尋ねた|答えた|ささやいた|叫んだ", "彼|彼女|私|あなた|彼ら|誰か", "小声で|ささやいて|叫んで|笑って|泣いて|傍白", "と|または|しかし"),
        "ko": p("말했다|물었다|대답했다|속삭였다|외쳤다", "그|그녀|나|너|우리|그들|누군가", "속삭이며|소리치며|웃으며|울며|방백", "그리고|또는|하지만"),
        "zh": p("说|说道|问|回答|低声说", "他|她|他们|我|你|我们|有人", "低声|喊着|笑着|哭着|旁白", "和|或|但是")
    ]
}

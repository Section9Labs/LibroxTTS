// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors

/// Small, independently authored spelling aids, not pre-realized IPA recordings.
/// Passing these through the ordinary rules preserves dialect and phrase allophones.
/// Sources and deliberate variant choices: docs/SPANISH-POLISH-2026-10.md.
enum SpanishLexicon {
    static func spelling(for word: String, dialect: SpanishDialect) -> String {
        if dialect == .spain, let spelling = peninsularHiatus[word] { return spelling }
        if dialect != .spain, let spelling = latinAmericanLoans[word] { return spelling }
        return spellings[word] ?? word
    }

    // The middle dot is an internal hiatus boundary, never emitted as a sound.
    // Latin American pronunciation varies; keep the existing diphthong profile there.
    static let peninsularHiatus: [String: String] = [
        "guion": "gui·ón", "guión": "gui·ón", "guiones": "gui·ónes",
        "truhan": "tru·án", "truhán": "tru·án", "truhanes": "tru·ánes"
    ]

    // Documented regional preferences, not a claim of uniformity across America.
    // RAE DPD entries: búngalo, búmeran, pudin. Both stress variants are valid.
    static let latinAmericanLoans: [String: String] = [
        "bungalow": "búngalo", "bungalows": "búngalos",
        "boomerang": "búmeran", "boomerangs": "búmerans",
        "pudding": "pudín"
    ]

    static let spellings: [String: String] = [
        // Historical x = /x/, including common inflections and place names.
        "méxico": "méjico",
        "mexicano": "mejicano", "mexicana": "mejicana",
        "mexicanos": "mejicanos", "mexicanas": "mejicanas",
        "mexicanismo": "mejicanismo", "mexicanismos": "mejicanismos",
        "mexicanista": "mejicanista", "mexicanistas": "mejicanistas",
        "oaxaca": "oajaca", "oaxaqueño": "oajaqueño", "oaxaqueña": "oajaqueña",
        "oaxaqueños": "oajaqueños", "oaxaqueñas": "oajaqueñas",
        "texas": "tejas", "texano": "tejano", "texana": "tejana",
        "texanos": "tejanos", "texanas": "tejanas",
        "ximena": "jimena", "ximeno": "jimeno", "ximénez": "jiménez", "mexía": "mejía",
        "xiote": "jiote", "xiotes": "jiotes",
        // Indigenous x does not have one universal pronunciation.
        "tlaxcala": "tlascala", "tlaxcalteca": "tlascalteca", "tlaxcaltecas": "tlascaltecas",
        "xola": "ʃola", "mixiote": "miʃiote", "mixiotes": "miʃiotes",

        // Pronounced h: /x/ is the existing broad-profile realization, not /h/ deletion.
        "hachís": "jachís", "hachises": "jachises",
        "haiku": "jaiku", "haikus": "jaikus", "haikú": "jaikú", "haikús": "jaikús",
        "hámster": "jámster", "hámsteres": "jámsteres",
        "hándicap": "jándicap", "hándicaps": "jándicaps",
        "hawái": "jawái", "hawaiano": "jawaiano", "hawaiana": "jawaiana",
        "hawaianos": "jawaianos", "hawaianas": "jawaianas",
        "hegel": "jéguel", "hegeliano": "jegueliano", "hegeliana": "jegueliana",
        "hegelianos": "jeguelianos", "hegelianas": "jeguelianas",
        "dírham": "dírjam", "dírhams": "dírjams",

        // Germanic w = /b/. Accents encode stress absent in the source spelling.
        "wagner": "bágner", "wagneriano": "bagneriano", "wagneriana": "bagneriana",
        "wagnerianos": "bagnerianos", "wagnerianas": "bagnerianas",
        "weimar": "béimar", "weimarés": "beimarés", "weimaresa": "beimaresa",
        "wolframio": "bolframio", "wamba": "bamba", "witiza": "bitiza",
        "kowalski": "kobalski", "kuwait": "kubáit", "kuwaití": "kubaití", "kuwaitíes": "kubaitíes",

        // Established loans whose spelling misleads ordinary Spanish rules.
        "jazz": "yas", "jazzista": "yasista", "jazzistas": "yasistas",
        "jazzístico": "yasístico", "jazzística": "yasística",
        "jazzísticos": "yasísticos", "jazzísticas": "yasísticas",
        "ballet": "balé", "ballets": "balés",
        "whisky": "wiski", "whiskys": "wiskis", "whiskies": "wiskis",
        "whiskey": "wiski", "whiskeys": "wiskis",
        "hobby": "jóbi", "hobbies": "jóbis",
        "software": "sóftgüer", "quorum": "cuórum",

        // Further individually authored exceptions, checked 2026-10-21. Each key
        // changes the ordinary rule output; regular adapted spellings are omitted.
        // RAE DPD y §§2.2c-d, 2.1: https://www.rae.es/dpd/y
        // These historical y spellings are vowels, not the consonant in Yáñez.
        "ayllón": "aillón", "goytisolo": "goitisolo", "guaymas": "guaimas",
        "guaymeño": "guaimeño", "guaymeña": "guaimeña",
        "guaymeños": "guaimeños", "guaymeñas": "guaimeñas",
        "ynduráin": "induráin", "yrigoyen": "irigoyen",
        "taylor": "téilor", "taylorismo": "teilorismo",
        "pyme": "pime", "pymes": "pimes", "haylas": "hailas", "voyme": "voime",

        // RAE DPD Hollywood: https://www.rae.es/dpd/Hollywood
        "hollywood": "jólibud", "hollywoodense": "jolibudense", "hollywoodenses": "jolibudenses",
        "hollywoodiense": "jolibudiense", "hollywoodienses": "jolibudienses",
        "hollywoodiano": "jolibudiano", "hollywoodiana": "jolibudiana",
        "hollywoodianos": "jolibudianos", "hollywoodianas": "jolibudianas",

        // The corresponding RAE DPD adaptations document stress and consonants:
        // https://www.rae.es/dpd/curri ; /ferri ; /sexi ; /rugbi ; /brandi ; /dandi
        "curry": "curri", "curries": "curris", "ferry": "ferri", "ferries": "ferris",
        "sexy": "sexi", "rugby": "rugbi", "brandy": "brandi", "brandies": "brandis",
        "dandy": "dandi", "dandies": "dandis",
        // https://www.rae.es/dpd/lady (including its explicitly documented plural).
        "lady": "leidi", "ladies": "leidis",

        // RAE DPD campin, márquetin, parquin, ranquin, cáterin, holding,
        // lifting, puentismo, esmoquin, mitin: https://www.rae.es/dpd/campin etc.
        // Keep the documented Spanish -in adaptation instead of sounding a final g.
        "camping": "campin", "campings": "cámpins",
        "marketing": "márquetin", "marketings": "márquetins",
        "parking": "parquin", "parkings": "párquins",
        "ranking": "ranquin", "rankings": "ránquins",
        "catering": "cáterin", "caterings": "cáterins",
        "holding": "jóldin", "holdings": "jóldins",
        "lifting": "liftin", "liftings": "líftins",
        "puenting": "puentin", "smoking": "esmoquin", "meeting": "mitin",
        // https://www.rae.es/dpd/pudin ; /búngalo ; /búmeran
        "pudding": "pudin", "bungalow": "bungaló", "bungalows": "bungalós",
        "boomerang": "bumerán", "boomerangs": "bumeranes",

        // RAE DPD yóquey/jóquey distinguishes the jockey from the sport hockey.
        // https://www.rae.es/dpd/yóquey ; https://www.rae.es/dpd/jóquey
        "jockey": "yóquey", "jockeys": "yoqueis", "hockey": "jóquey",
        // https://www.rae.es/dpd/rock ; /blues ; /góspel ; /wéstern
        "rock": "rok", "blues": "blus", "gospel": "góspel", "gospels": "góspels",
        "western": "güéstern", "westerns": "güésterns",
        // Direct pronunciations: https://www.rae.es/dpd/sheriff ; /thriller ; /show ; /flash
        // Literal θ retains the foreign th sound even in the seseo profile.
        "sheriff": "ʃérif", "sheriffs": "ʃérifs", "thriller": "θríler", "thrillers": "θrílers",
        "show": "ʃou", "shows": "ʃous", "flash": "flaʃ", "flashes": "fláʃes",

        // https://www.rae.es/dpd/copyright ; /feedback ; /hardware ; /leitmotiv
        "copyright": "kópirrait", "copyrights": "kópirraits",
        "feedback": "fídbak", "hardware": "járgüer",
        "leitmotiv": "leitmotif", "leitmotivs": "leitmotifs",
        // https://www.rae.es/dpd/baipás
        "bypass": "baipás", "bypasses": "baipases",

        // French-origin vocabulary used in Spanish prose. These are Spanish
        // readings/adaptations; explicitly French spans belong to the French engine.
        // Direct pronunciations: https://www.rae.es/dpd/affaire ; /suite ; /garaje ; /beis
        "affaire": "afér", "suite": "suit", "suites": "suits",
        "garage": "garáʒ", "beige": "beʒ",
        // Documented adaptations: https://www.rae.es/dpd/suflé ; /buqué ; /bulevar ;
        // /cruasán ; /champán ; /colaje
        "soufflé": "suflé", "soufflés": "suflés",
        "bouquet": "buqué", "bouquets": "buqués", "boulevard": "bulevar",
        "croissant": "cruasán", "champagne": "champán",
        "collage": "colaje", "collages": "colajes"
    ]
}

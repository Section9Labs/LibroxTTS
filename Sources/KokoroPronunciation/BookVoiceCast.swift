// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation

/// Small, book-scoped identity store. Persist with encoded()/restore(); never
/// rebuild it at a chapter boundary. Voice IDs are validated by the host catalog.
public struct BookVoiceCast: Codable, Sendable, Equatable {
    public enum Gender: String, Codable, Sendable { case unknown, female, male, conflicting }
    public enum VoiceSharing: String, Codable, Sendable { case narratorFallback, reuseCompatible }
    public enum VoiceAssignment: String, Codable, Sendable { case automatic, manual }
    public struct GenderEvidence: Codable, Sendable, Equatable {
        public let gender: Gender
        public let quote: String
        public let chapterID: String
    }
    public struct Character: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let firstChapter: String
        public fileprivate(set) var voiceID: String?
        /// Missing in older saves, where nil could mean either no suitable voice
        /// or an explicit user disable. Preserve those ambiguous legacy choices.
        public fileprivate(set) var voiceAssignment: VoiceAssignment? = .automatic
        /// At most one explicit source observation for each gender. Never inferred from a name alone.
        public fileprivate(set) var genderEvidence: [GenderEvidence] = []
        public var gender: Gender {
            let values = Set(genderEvidence.map(\.gender))
            return values.count > 1 ? .conflicting : values.first ?? .unknown
        }
    }
    public enum CastError: Error { case invalidState, wrongBook, aliasConflict, unknownCharacter, limitExceeded }
    public static let maximumCharacters = 64
    public static let maximumAliases = 192
    public static let maximumEncodedBytes = 131_072
    public private(set) var schemaVersion = 1
    public let bookID: String
    public let language: PronunciationLanguage
    public let narratorVoiceID: String
    public let voicePool: [String]
    /// Host-supplied voice catalog metadata, including the narrator if known.
    public let voiceGenders: [String: Gender]
    public let voiceSharing: VoiceSharing
    /// Optional host renderer profile: stable across chapter and text-length changes.
    public let styleRow: Int
    public private(set) var characters: [Character] = []
    public private(set) var aliases: [String: String] = [:]

    public init(bookID: String, language: PronunciationLanguage, narratorVoiceID: String,
                voicePool: [String], styleRow: Int = 158,
                voiceGenders: [String: Gender] = [:], voiceSharing: VoiceSharing = .narratorFallback) throws {
        self.bookID = bookID; self.language = language
        self.narratorVoiceID = narratorVoiceID; self.voicePool = voicePool; self.styleRow = styleRow
        self.voiceGenders = voiceGenders; self.voiceSharing = voiceSharing
        try validate()
    }

    /// Explicit narrator correction preserves every character and alias. The old
    /// narrator becomes an available character voice; nobody is silently recast.
    public func replacingNarrator(with voiceID: String) throws -> Self {
        guard voiceID == narratorVoiceID || voicePool.contains(voiceID) else { throw CastError.invalidState }
        var replacement = try Self(bookID: bookID, language: language, narratorVoiceID: voiceID,
            voicePool: (voicePool + [narratorVoiceID]).filter { $0 != voiceID }, styleRow: styleRow,
            voiceGenders: voiceGenders, voiceSharing: voiceSharing)
        replacement.characters = characters; replacement.aliases = aliases
        for index in replacement.characters.indices {
            replacement.assignAvailableVoice(at: index)
        }
        try replacement.validate()
        return replacement
    }

    public var characterVoices: [String: String] {
        Dictionary(uniqueKeysWithValues: characters.compactMap { c in c.voiceID.map { (c.id, $0) } })
    }

    /// Expand an installed catalog without recasting anyone. Previously manual
    /// nil choices remain manual, and aliases/character IDs remain byte-stable.
    public func addingVoices(_ voices: [String], genders: [String: Gender]) throws -> Self {
        try validate()
        var pool = voicePool
        for voice in voices where voice != narratorVoiceID && !pool.contains(voice) { pool.append(voice) }
        let metadata = voiceGenders.merging(genders) { _, latest in latest }
        var result = try Self(bookID: bookID, language: language, narratorVoiceID: narratorVoiceID,
            voicePool: pool, styleRow: styleRow, voiceGenders: metadata, voiceSharing: voiceSharing)
        result.characters = characters; result.aliases = aliases
        try result.validate()
        return result
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw CastError.limitExceeded }
        return data
    }

    public static func restore(_ data: Data, bookID: String) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw CastError.limitExceeded }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.bookID == bookID else { throw CastError.wrongBook }
        try value.validate()
        return value
    }

    /// Character IDs whose stable voice disagrees with later explicit evidence.
    /// Review these; never silently recast an already heard character.
    public var voiceReviewIDs: [String] {
        characters.filter { c in
            guard c.gender == .female || c.gender == .male,
                  let voice = c.voiceID, let gender = voiceGenders[voice], gender != .unknown else { return false }
            return gender != c.gender
        }.map(\.id)
    }

    /// Explicit user/editor correction. No fuzzy name merging.
    public mutating func addAlias(_ name: String, to characterID: String) throws {
        try validate()
        let key = Self.nameKey(name)
        guard !key.isEmpty, key.utf8.count <= 256 else { throw CastError.invalidState }
        guard characters.contains(where: { $0.id == characterID }) else { throw CastError.unknownCharacter }
        if let existing = aliases[key], existing != characterID { throw CastError.aliasConflict }
        guard aliases[key] != nil || aliases.count < Self.maximumAliases else { throw CastError.limitExceeded }
        aliases[key] = characterID
    }

    public mutating func setVoice(_ voiceID: String?, for characterID: String) throws {
        try validate()
        guard voiceID == nil || voicePool.contains(voiceID!) || voiceID == narratorVoiceID else { throw CastError.invalidState }
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { throw CastError.unknownCharacter }
        characters[index].voiceID = voiceID
        characters[index].voiceAssignment = .manual
    }

    func validate() throws {
        func valid(_ text: String, limit: Int) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= limit
        }
        guard schemaVersion == 1, (0...510).contains(styleRow), valid(bookID, limit: 256), valid(narratorVoiceID, limit: 64),
              voicePool.count <= 64, Set(voicePool).count == voicePool.count,
              voicePool.allSatisfy({ valid($0, limit: 64) && $0 != narratorVoiceID }),
              voiceGenders.count <= 65,
              voiceGenders.allSatisfy({ (voicePool.contains($0.key) || $0.key == narratorVoiceID) && $0.value != .conflicting }),
              characters.count <= Self.maximumCharacters, aliases.count <= Self.maximumAliases,
              Set(characters.map(\.id)).count == characters.count,
              characters.enumerated().allSatisfy({ $0.element.id == "c\($0.offset + 1)" }),
              characters.allSatisfy({ valid($0.id, limit: 64) && valid($0.name, limit: 256)
                  && valid($0.firstChapter, limit: 128)
                  && $0.genderEvidence.count <= 2
                  && Set($0.genderEvidence.map(\.gender)).count == $0.genderEvidence.count
                  && $0.genderEvidence.allSatisfy({ e in (e.gender == .female || e.gender == .male)
                      && valid(e.quote, limit: 512) && valid(e.chapterID, limit: 128) })
                  && ($0.voiceID == nil || voicePool.contains($0.voiceID!) || $0.voiceID == narratorVoiceID) }),
              aliases.allSatisfy({ valid($0.key, limit: 256) && $0.key == Self.nameKey($0.key) }) else { throw CastError.invalidState }
        let ids = Set(characters.map(\.id))
        guard aliases.values.allSatisfy(ids.contains),
              characters.allSatisfy({ aliases[Self.nameKey($0.name)] == $0.id }) else { throw CastError.invalidState }
    }

    static func cleanName(_ name: String) -> String {
        let words = name.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let titles: Set<String> = ["don", "doña", "señor", "señora", "sr.", "sra.", "mr.", "mrs.", "miss", "ms."]
        return (words.first.map { titles.contains($0.lowercased()) } == true ? Array(words.dropFirst()) : words).joined(separator: " ")
    }
    static func nameKey(_ name: String) -> String { cleanName(name).lowercased() }

    func identity(for name: String) -> String { aliases[Self.nameKey(name)] ?? "name:" + Self.nameKey(name) }

    mutating func discover(_ name: String, chapterID: String, evidence: [GenderEvidence] = []) -> Character? {
        let clean = Self.cleanName(name), key = Self.nameKey(name)
        if let id = aliases[key], let index = characters.firstIndex(where: { $0.id == id }) {
            for item in evidence where !characters[index].genderEvidence.contains(where: { $0.gender == item.gender }) {
                characters[index].genderEvidence.append(item)
            }
            assignAvailableVoice(at: index)
            return characters[index] // Never replace an assigned or manually disabled voice.
        }
        guard characters.count < Self.maximumCharacters, aliases.count < Self.maximumAliases,
              !key.isEmpty, key.utf8.count <= 256 else { return nil }
        let character = Character(id: "c\(characters.count + 1)", name: clean, firstChapter: chapterID,
                                  voiceID: nil, genderEvidence: evidence)
        characters.append(character); aliases[key] = character.id
        assignAvailableVoice(at: characters.count - 1)
        return characters.last
    }

    private mutating func assignAvailableVoice(at index: Int) {
        guard characters[index].voiceID == nil, characters[index].voiceAssignment == .automatic else { return }
        var character = characters[index]
        // Conflicting source evidence must not select a new gendered voice.
        guard character.gender != .conflicting else { return }
        let used = Set(characters.compactMap(\.voiceID))
        let gender = character.gender
        let known = gender == .female || gender == .male
        let compatible = known && !voiceGenders.isEmpty ? voicePool.filter { voiceGenders[$0] == gender } : voicePool
        if let unused = compatible.first(where: { !used.contains($0) }) { character.voiceID = unused }
        else if voiceSharing == .reuseCompatible, known, !compatible.isEmpty {
            // Stable least-used compatible voice; palette order breaks ties.
            character.voiceID = compatible.enumerated().min { a, b in
                let x = characters.filter { $0.voiceID == a.element }.count
                let y = characters.filter { $0.voiceID == b.element }.count
                return x == y ? a.offset < b.offset : x < y
            }?.element
        } else if voiceSharing == .reuseCompatible, known, voiceGenders[narratorVoiceID] == gender {
            character.voiceID = narratorVoiceID
        }
        characters[index] = character
    }
}

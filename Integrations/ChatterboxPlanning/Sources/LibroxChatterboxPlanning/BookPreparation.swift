import Foundation
import LibroxChapterWorker
import LibroxChatterbox
import KokoroNarration

/// Explicit source-independent defaults for one book preparation. Authored
/// per-chapter directions remain in each exact portable plan, not these defaults.
public struct ChatterboxBookRenderSettings: Sendable {
    public let language: String
    public let delivery: ChapterAudioDelivery
    public let direction: ChatterboxBookDirector.Direction
    public let grouping: ChatterboxBookDirector.Grouping
    public let seed: UInt64
    public init(language: String, delivery: ChapterAudioDelivery, direction: ChatterboxBookDirector.Direction,
                grouping: ChatterboxBookDirector.Grouping, seed: UInt64) throws {
        guard ["en", "es"].contains(language) else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        if case .compatibleNarration(let count) = grouping, !(50...300).contains(count) { throw ChatterboxChapterRenderPlanError.invalidPlan }
        self.language = language; self.delivery = delivery; self.direction = direction; self.grouping = grouping; self.seed = seed
    }
}
public enum ChatterboxPreparedBookEntry: Sendable {
    case chapter(ChatterboxPreparedChapterSubmission)
    case silent(ChapterBookSilentSource)
}

/// Pure SDK-owned metadata, not available/approved catalog or authority. Persist
/// the complete scope in the SDK outbox; recover typed settings through restore.
public struct ChatterboxPreparedBookSubmission: Sendable {
    public let scope: ChapterBookPreparationScope
    public let settings: ChatterboxBookRenderSettings
    private let descriptor: ChatterboxStockVoiceDescriptor
    private struct Policy: Codable {
        let version: Int
        let modelSHA256, conditioningSHA256, rendererProfile: String
        let language: String
        let delivery: ChapterAudioDelivery
        let direction, grouping: String
        let maximumCharacters: Int?
        let seed: UInt64
        let authoredDirectionsRevision: String
        let plannerRevision: String
    }
    private static var currentPlannerRevision: String { ChatterboxBookDirector.revision + ":chapterV1:" + ConversationCadence.revision }
    /// Policy compatibility only, never backend availability/listening approval.
    public var supportsCurrentPlanner: Bool {
        (try? JSONDecoder().decode(Policy.self, from: scope.configuration).plannerRevision) == Self.currentPlannerRevision
    }
    package init(book: ChapterBookSource, settings: ChatterboxBookRenderSettings,
                 descriptor: ChatterboxStockVoiceDescriptor, session: ChapterAccountSession) throws {
        let mode: String, maximum: Int?
        switch settings.grouping {
        case .sentences: mode = "sentences"; maximum = nil
        case .compatibleNarration(let count): mode = "compatible-narration"; maximum = count
        }
        let policy = Policy(version: 1, modelSHA256: descriptor.modelSHA256, conditioningSHA256: descriptor.conditioningSHA256,
            rendererProfile: descriptor.rendererProfile, language: settings.language, delivery: settings.delivery,
            direction: settings.direction == .neutral ? "neutral" : "storyteller", grouping: mode,
            maximumCharacters: maximum, seed: settings.seed, authoredDirectionsRevision: "exact-chapter-directions-1",
            plannerRevision: Self.currentPlannerRevision)
        scope = try .init(book: book, accountPartition: session.accountPartition, configuration: Self.encode(policy))
        self.settings = settings; self.descriptor = descriptor
    }
    private init(scope: ChapterBookPreparationScope, settings: ChatterboxBookRenderSettings, descriptor: ChatterboxStockVoiceDescriptor) {
        self.scope = scope; self.settings = settings; self.descriptor = descriptor
    }
    /// SDK durable recovery, never defaults inferred from an opaque digest. The
    /// recovered descriptor is metadata ONLY; Worker must rebind actual backend.
    public static func restore(scope: ChapterBookPreparationScope, session: ChapterAccountSession) throws -> Self {
        guard scope.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let policy = try JSONDecoder().decode(Policy.self, from: scope.configuration)
        guard policy.version == 1, policy.authoredDirectionsRevision == "exact-chapter-directions-1",
              !policy.plannerRevision.isEmpty, policy.plannerRevision.utf8.count <= 1024,
              try encode(policy) == scope.configuration else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        let direction: ChatterboxBookDirector.Direction
        switch policy.direction {
        case "neutral": direction = .neutral
        case "storyteller": direction = .storyteller
        default: throw ChatterboxChapterRenderPlanError.invalidPlan
        }
        let grouping: ChatterboxBookDirector.Grouping
        switch policy.grouping {
        case "sentences":
            guard policy.maximumCharacters == nil else { throw ChatterboxChapterRenderPlanError.invalidPlan }; grouping = .sentences
        case "compatible-narration":
            guard let count = policy.maximumCharacters else { throw ChatterboxChapterRenderPlanError.invalidPlan }
            grouping = .compatibleNarration(maxCharacters: count)
        default: throw ChatterboxChapterRenderPlanError.invalidPlan
        }
        let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: policy.modelSHA256,
            conditioningSHA256: policy.conditioningSHA256, rendererProfile: policy.rendererProfile)
        let settings = try ChatterboxBookRenderSettings(language: policy.language, delivery: policy.delivery,
            direction: direction, grouping: grouping, seed: policy.seed)
        // Historical policy metadata remains readable. This does not verify
        // historical media or silently request the current planner for new input.
        return .init(scope: scope, settings: settings, descriptor: descriptor)
    }
    public func prepareEntry(chapterIndex: Int, text: String, performanceDirections: ChatterboxPerformanceDirections? = nil,
                             session: ChapterAccountSession) throws -> ChatterboxPreparedBookEntry {
        guard session.accountPartition == scope.accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard supportsCurrentPlanner else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        switch try scope.book.classify(text: text, chapterIndex: chapterIndex) {
        case .silent(let proof):
            // Do not silently discard authored controls on a supposedly silent
            // entry. The caller must supply its exact intended classification.
            guard performanceDirections == nil else { throw ChatterboxChapterRenderPlanError.invalidPlan }
            return .silent(proof)
        case .narratable(let source):
            let options = try ChatterboxChapterRenderOptions(text: text, language: settings.language, delivery: settings.delivery,
                direction: settings.direction, grouping: settings.grouping, performanceDirections: performanceDirections, seed: settings.seed)
            return .chapter(try descriptor.prepareChapter(source: source, options: options, session: session))
        }
    }
    package func validate(_ prepared: ChatterboxPreparedChapterSubmission, chapterIndex: Int) throws {
        // Restoration preserves metadata, not a mixed-era synthesis verifier.
        // Historical pair/media acceptance needs its own pinned fingerprint.
        guard supportsCurrentPlanner else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        try scope.validate(prepared.submission.request, chapterIndex: chapterIndex)
        try ChatterboxLocalRenderPlan.validate(prepared.plan, submission: prepared.submission)
        let options = try prepared.plan.restore(source: prepared.submission.originalText)
        let policy = try JSONDecoder().decode(Policy.self, from: scope.configuration)
        guard options.language == settings.language, options.delivery == settings.delivery, options.direction == settings.direction,
              options.grouping == settings.grouping, options.seed == settings.seed,
              case .narratable(let source) = try scope.book.classify(text: options.text, chapterIndex: chapterIndex)
        else { throw ChatterboxChapterRenderPlanError.recipeMismatch }
        let recipe = try ChapterRenderRecipe(language: options.language, stockVoiceID: descriptor.id,
            conditioningSHA256: descriptor.conditioningSHA256, modelSHA256: descriptor.modelSHA256,
            rendererProfile: descriptor.rendererProfile, plannerRevision: policy.plannerRevision,
            expressionSHA256: options.expressionSHA256,
            synthesisOptionsSHA256: options.canonicalSynthesisIdentity(rendererProfile: descriptor.rendererProfile),
            seedPolicy: "fixed-per-unit-1:\(options.seed)", watermarkRevision: "disabled-1")
        let expected = try ChapterRenderRequest(accountPartition: scope.accountPartition, source: source, recipe: recipe, delivery: options.delivery)
        guard try Self.encode(expected) == Self.encode(prepared.submission.request),
              try ChatterboxChapterRenderPlan(request: options).encoded() == prepared.plan.encoded()
        else { throw ChatterboxChapterRenderPlanError.recipeMismatch }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
}
extension ChatterboxStockVoiceDescriptor {
    /// Must originate from an actual prepared/qualified catalog path. Producing
    /// this scope alone never loads a model or establishes catalog availability.
    public func prepareBook(source: ChapterBookSource, settings: ChatterboxBookRenderSettings,
                            session: ChapterAccountSession) throws -> ChatterboxPreparedBookSubmission {
        try .init(book: source, settings: settings, descriptor: self, session: session)
    }
}

public enum ChatterboxBookSubmissionAdmission {
    enum Event: Sendable { case afterSource, beforeSettlement, beforeIntent, afterIntent }
    typealias Checkpoint = @Sendable (Event) async throws -> Void
    /// Reuses the existing exact source/plan publishers and allowance policy.
    /// Source is lazy per original spine entry; no app-side plan stash/hash recipe.
    public static func submit(_ prepared: ChatterboxPreparedChapterSubmission, book: ChatterboxPreparedBookSubmission,
                              chapterIndex: Int, gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox,
                              budget: ChapterArtifactStorageBudget, sourceDirectory: URL, planDirectory: URL) async throws -> ChapterBookDemandIntent {
        try await submit(prepared, book: book, chapterIndex: chapterIndex, gate: gate, outbox: outbox,
            budget: budget, sourceDirectory: sourceDirectory, planDirectory: planDirectory, checkpoint: { _ in })
    }
    static func submit(_ prepared: ChatterboxPreparedChapterSubmission, book: ChatterboxPreparedBookSubmission,
                       chapterIndex: Int, gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox,
                       budget: ChapterArtifactStorageBudget, sourceDirectory: URL, planDirectory: URL,
                       checkpoint: @escaping Checkpoint) async throws -> ChapterBookDemandIntent {
        try Task.checkCancellation(); try await gate.validate(prepared.submission.session); try Task.checkCancellation()
        try book.validate(prepared, chapterIndex: chapterIndex)
        let admission = try await outbox.observeAdmission(scopeID: book.scope.identifier, chapterIndex: chapterIndex)
        try await budget.requireManagedDirectory(sourceDirectory); try await budget.requireManagedDirectory(planDirectory)
        let allowance = try await budget.reserve(bytes: ChatterboxLocalSubmissionAdmission.maximumPublicationGrowthBytes)
        let producer = Task {
            let source = try await ChapterLocalSource.publish(prepared.submission, gate: gate, directory: sourceDirectory)
            try await checkpoint(.afterSource)
            let plan = try await ChatterboxLocalRenderPlan.publish(prepared.plan, submission: prepared.submission,
                source: source, gate: gate, directory: planDirectory)
            return (source, plan)
        }
        let result = await withTaskCancellationHandler { await producer.result } onCancel: { producer.cancel() }
        let publications: (ChapterLocalSourcePublication, ChapterLocalRenderPlanPublication)
        do { publications = try result.get(); try await checkpoint(.beforeSettlement); _ = try await budget.settleAfterJoining(allowance) }
        catch { try await budget.releaseAfterJoining(allowance); throw error }
        try await checkpoint(.beforeIntent)
        try await gate.validate(prepared.submission.session); try Task.checkCancellation()
        let intent = try await outbox.attach(admission, request: prepared.submission.request, source: publications.0, plan: publications.1)
        try await checkpoint(.afterIntent)
        try await gate.validate(prepared.submission.session); try Task.checkCancellation(); return intent
    }
    public static func submitSilent(_ proof: ChapterBookSilentSource, originalText: String,
                                    book: ChatterboxPreparedBookSubmission, session: ChapterAccountSession,
                                    gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox) async throws -> ChapterBookDemandIntent {
        try await gate.validate(session); try Task.checkCancellation()
        guard session.accountPartition == book.scope.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let admission = try await outbox.observeAdmission(scopeID: book.scope.identifier, chapterIndex: proof.chapterIndex)
        try proof.validate(text: originalText)
        try await gate.validate(session); try Task.checkCancellation()
        let intent = try await outbox.attachSilent(proof, originalText: originalText, admission: admission)
        try await gate.validate(session); try Task.checkCancellation(); return intent
    }
}

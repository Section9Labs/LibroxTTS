import Foundation
import LibroxChapterWorker
import LibroxChatterbox
import KokoroNarration

/// SDK-prepared exact source/options pair. Metadata only: submission still needs
/// current Reader authority, storage admission and a separately qualified Worker.
public struct ChatterboxPreparedChapterSubmission: Sendable {
    public let submission: ChapterSubmission
    public let plan: ChatterboxChapterRenderPlan
}

/// Source-independent backend metadata, produced by a prepared SDK renderer.
/// This is NOT availability, listening approval, an account or an inference grant.
/// No dummy source/expression hash is used to pretend a recipe is reusable.
public struct ChatterboxStockVoiceDescriptor: Sendable {
    public let modelSHA256, conditioningSHA256, rendererProfile: String
    public var id: String { "librox-narrator" }
    public var displayName: String { "Librox Narrator" }
    public var languages: [String] { ["en", "es"] }
    public var inputUTF16Limit: Int { 131072 }
    package init(modelSHA256: String, conditioningSHA256: String, rendererProfile: String) throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard digest(modelSHA256), digest(conditioningSHA256), !rendererProfile.isEmpty,
              rendererProfile.utf8.count <= 1024 else { throw ChapterWorkerError.invalidIdentity }
        self.modelSHA256 = modelSHA256; self.conditioningSHA256 = conditioningSHA256; self.rendererProfile = rendererProfile
    }
    /// Pure canonical binding for the ACTUAL text, direction, grouping, seed,
    /// authored expressions and delivery. Never copy a generic catalog recipe.
    /// This operation neither opens a model nor publishes wanted demand.
    public func prepareChapter(source: ChapterSourceIdentity, options: ChatterboxChapterRenderOptions,
                               session: ChapterAccountSession) throws -> ChatterboxPreparedChapterSubmission {
        try source.validate(text: options.text)
        let recipe = try ChapterRenderRecipe(language: options.language, stockVoiceID: id,
            conditioningSHA256: conditioningSHA256, modelSHA256: modelSHA256, rendererProfile: rendererProfile,
            plannerRevision: ChatterboxBookDirector.revision + ":chapterV1:" + ConversationCadence.revision,
            expressionSHA256: options.expressionSHA256,
            synthesisOptionsSHA256: options.canonicalSynthesisIdentity(rendererProfile: rendererProfile),
            seedPolicy: "fixed-per-unit-1:\(options.seed)", watermarkRevision: "disabled-1")
        let request = try ChapterRenderRequest(accountPartition: session.accountPartition, source: source, recipe: recipe, delivery: options.delivery)
        return try .init(submission: ChapterSubmission(request: request, originalText: options.text, session: session),
                         plan: ChatterboxChapterRenderPlan(request: options))
    }
}

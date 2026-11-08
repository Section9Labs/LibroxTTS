import Testing
import LibroxTTS

@Test func realtimeBudgetPreservesQualityUntilMeasuredBufferPressure() throws {
    let requested = PocketTTSSamplingOptions(temperature: 0.42, samplerSteps: 8)
    var budget = try PocketTTSRealtimeBudget(requested: requested)
    #expect(budget.record(renderSeconds: 13, audioSeconds: 10, bufferedAudioSeconds: 90, renderedWith: requested) == requested)
    #expect(budget.record(renderSeconds: 13, audioSeconds: 10, bufferedAudioSeconds: 60, renderedWith: requested) == requested)
    let reduced = budget.record(renderSeconds: 13, audioSeconds: 10, bufferedAudioSeconds: 25, renderedWith: requested)
    #expect(reduced.samplerSteps == 4)
    #expect(reduced.temperature == requested.temperature)
    #expect(budget.requested == requested)
    #expect(reduced.cacheIdentity != requested.cacheIdentity)
    // A queued eight-step render finishing later must not downgrade four again.
    #expect(budget.record(renderSeconds: 13, audioSeconds: 10, bufferedAudioSeconds: 10, renderedWith: requested) == reduced)
    #expect(budget.record(renderSeconds: 5, audioSeconds: 10, bufferedAudioSeconds: 20, renderedWith: reduced) == reduced)
    budget.reset()
    #expect(budget.effective == requested)
}

@Test func realtimeBudgetRespectsPlaybackSpeedAndInvalidMeasurements() throws {
    let requested = PocketTTSSamplingOptions(temperature: 0.3, samplerSteps: 8)
    var budget = try PocketTTSRealtimeBudget(requested: requested)
    #expect(budget.record(renderSeconds: .nan, audioSeconds: 10, bufferedAudioSeconds: 1, renderedWith: requested) == requested)
    #expect(budget.record(renderSeconds: 7, audioSeconds: 10, bufferedAudioSeconds: 40, playbackRate: 2, renderedWith: requested) == requested)
    #expect(budget.record(renderSeconds: 7, audioSeconds: 10, bufferedAudioSeconds: 40, playbackRate: 2, renderedWith: requested).samplerSteps == 4)
    for steps in [4, 2] {
        let sampling = budget.effective
        #expect(sampling.samplerSteps == steps)
        for _ in 0..<2 {
            budget.record(renderSeconds: 20, audioSeconds: 10, bufferedAudioSeconds: 0, renderedWith: sampling)
        }
    }
    #expect(budget.effective.samplerSteps == 1)
    for _ in 0..<3 {
        budget.record(renderSeconds: 20, audioSeconds: 10, bufferedAudioSeconds: 0, renderedWith: budget.effective)
    }
    #expect(budget.effective.samplerSteps == 1)
}

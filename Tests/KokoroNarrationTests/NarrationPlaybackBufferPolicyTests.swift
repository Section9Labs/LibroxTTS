import Testing
import KokoroNarration

@Test func playbackBufferFillsThenRestsUntilReserveIsLow() {
    var policy = NarrationPlaybackBufferPolicy()
    for seconds in [0.0, 12, 22, 29] {
        let decision1 = policy.shouldGenerate(bufferedAudioSeconds: seconds, playbackRequested: true)
        #expect(decision1)
    }
    for seconds in [35.0, 30, 22, 12.1] {
        let decision2 = policy.shouldGenerate(bufferedAudioSeconds: seconds, playbackRequested: true)
        #expect(!decision2)
    }
    let decision3 = policy.shouldGenerate(bufferedAudioSeconds: 12, playbackRequested: true)
    #expect(decision3)
}

@Test func playbackBufferUsesListeningTimeAtSelectedRate() {
    var policy = NarrationPlaybackBufferPolicy()
    let decision4 = policy.shouldGenerate(bufferedAudioSeconds: 60, playbackRate: 2, playbackRequested: true)
    #expect(!decision4)
    let decision5 = policy.shouldGenerate(bufferedAudioSeconds: 25, playbackRate: 2, playbackRequested: true)
    #expect(!decision5)
    let decision6 = policy.shouldGenerate(bufferedAudioSeconds: 24, playbackRate: 2, playbackRequested: true)
    #expect(decision6)
}

@Test func playbackBufferStopsOnPauseAndAtEndOfBook() {
    var policy = NarrationPlaybackBufferPolicy()
    let decision7 = policy.shouldGenerate(bufferedAudioSeconds: 0, playbackRequested: false)
    #expect(!decision7)
    let decision8 = policy.shouldGenerate(bufferedAudioSeconds: 0, playbackRequested: true, hasPendingUnits: false)
    #expect(!decision8)
    let decision9 = policy.shouldGenerate(bufferedAudioSeconds: 0, playbackRequested: true)
    #expect(decision9)
}

@Test func playbackBufferCanStartFreshAfterSeeking() {
    var policy = NarrationPlaybackBufferPolicy()
    let decision10 = policy.shouldGenerate(bufferedAudioSeconds: 31, playbackRequested: true)
    #expect(!decision10)
    policy.reset()
    let decision11 = policy.shouldGenerate(bufferedAudioSeconds: 20, playbackRequested: true)
    #expect(decision11)
}

@Test func playbackBufferRejectsInvalidPlayerMeasurements() {
    var policy = NarrationPlaybackBufferPolicy()
    for seconds in [Double.nan, .infinity, -1] {
        let decision12 = policy.shouldGenerate(bufferedAudioSeconds: seconds, playbackRequested: true)
        #expect(!decision12)
    }
    for rate in [Double.nan, .infinity, 0, -1] {
        let decision13 = policy.shouldGenerate(bufferedAudioSeconds: 0, playbackRate: rate, playbackRequested: true)
        #expect(!decision13)
    }
}

import Testing
@testable import ChatterboxCoreML

@Test func shortContextAdmissionAcceptsWholeBudget() throws {
    try MTLT3LMRunner.validateContext(textTokenCount: 96, prefillWindow: 512,
                                      maxSequence: 512, maxNewTokens: 350)
    try MTLT3LMRunner.validateContext(textTokenCount: 129, prefillWindow: 512,
                                      maxSequence: 512, maxNewTokens: 128)
    // Exact boundary is valid: final write is at maxSequence-1.
    try MTLT3LMRunner.validateContext(textTokenCount: 126, prefillWindow: 512,
                                      maxSequence: 512, maxNewTokens: 350)
}

@Test func shortContextRejectsOverflowBeforeInference() {
    #expect(throws: (any Error).self) {
        try MTLT3LMRunner.validateContext(textTokenCount: 127, prefillWindow: 512,
                                          maxSequence: 512, maxNewTokens: 350)
    }
    #expect(throws: (any Error).self) {
        try MTLT3LMRunner.validateContext(textTokenCount: 477, prefillWindow: 512,
                                          maxSequence: 1536, maxNewTokens: 128)
    }
    #expect(throws: (any Error).self) {
        try MTLT3LMRunner.validateContext(textTokenCount: 10, prefillWindow: 512,
                                          maxSequence: 512, maxNewTokens: 0)
    }
}

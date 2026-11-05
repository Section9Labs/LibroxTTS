import Foundation
import CloudKit

package struct ChapterBookCloudWorkToken: Sendable {
    let claim: ChapterBookCloudClaim
    package let session: ChapterAccountSession
    fileprivate init(_ claim: ChapterBookCloudClaim, session: ChapterAccountSession) { self.claim = claim; self.session = session }
}
package struct ChapterBookCloudPrefixObservation: Sendable {
    package let prefix: ChapterSegmentPrefix
    package let manifests: [ChapterSegmentManifest]
    package let seal: ChapterSegmentCompletionSeal?
}

/// Single-appointed native Worker claim and ordered publication transaction.
/// A non-expiring claim never transfers automatically by elapsed/client time.
/// The host MUST retain its distinct private Worker role lock, own producers,
/// and call releaseAfterJoin ONLY after rendering/callback/codec/uploads join.
package actor ChapterCloudBookWorkTransport {
    private let store: any ChapterCloudMetadataStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let authorize: @Sendable () async throws -> Void
    private let workerOwnership: @Sendable () async throws -> Void
    private var occupied = false
    package init(container: CKContainer, account: ChapterCloudAccountIdentity, session: ChapterAccountSession,
                 gate: ChapterAccountSessionGate, authorizeControlTransfer: @escaping @Sendable () async throws -> Void,
                 validateWorkerOwnership: @escaping @Sendable () async throws -> Void) throws {
        guard container.containerIdentifier == account.containerIdentifier, account.accountPartition == session.accountPartition else {
            throw ChapterWorkerError.accountMismatch
        }
        store = NativeChapterCloudMetadataStore(database: container.privateCloudDatabase)
        self.session = session; self.gate = gate; authorize = authorizeControlTransfer; workerOwnership = validateWorkerOwnership
    }
    init(store: any ChapterCloudMetadataStore, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
         authorize: @escaping @Sendable () async throws -> Void = {},
         workerOwnership: @escaping @Sendable () async throws -> Void = {}) {
        self.store = store; self.session = session; self.gate = gate; self.authorize = authorize; self.workerOwnership = workerOwnership
    }
    static func root(_ scope: String) -> ChapterCloudMetadataKey { .init(key: "bd-" + scope, type: "LibroxBookDemandV1") }
    static func member(_ scope: String, _ device: UUID) -> ChapterCloudMetadataKey {
        .init(key: ChapterCloudBookControlTransport.deviceKey(scope, device), type: "LibroxBookDeviceV1")
    }
    static func claim(_ scope: String, _ render: String) -> ChapterCloudMetadataKey {
        .init(key: "bc-" + scope + "-" + render, type: "LibroxBookWorkerClaimV1")
    }
    static func head(_ scope: String, _ render: String) -> ChapterCloudMetadataKey {
        .init(key: "bh-" + scope + "-" + render, type: "LibroxBookSegmentHeadV1")
    }
    static func segment(_ scope: String, _ render: String, _ index: Int) -> ChapterCloudMetadataKey {
        .init(key: "bs-" + scope + "-" + render + "-" + String(index), type: "LibroxBookSegmentIndexV1")
    }
    private func valid(worker: Bool) async throws {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        if worker { try await workerOwnership(); try await gate.validate(session); try Task.checkCancellation() }
    }
    private func authorized(worker: Bool) async throws {
        try await valid(worker: worker); try await authorize(); try await valid(worker: worker)
    }
    private func fetch(_ keys: [ChapterCloudMetadataKey], worker: Bool) async throws -> [String: ChapterBookControlRecord] {
        try await authorized(worker: worker)
        do {
            let records = try await store.fetch(keys); try await valid(worker: worker)
            let types = Dictionary(uniqueKeysWithValues: keys.map { ($0.key, $0.type) })
            for (key, record) in records {
                guard key == record.key, types[key] == record.type, !record.tag.isEmpty, record.tag.utf8.count <= 1024,
                      !record.payload.isEmpty, record.payload.count <= 128 * 1024 else { throw ChapterDemandTransportError.invalidRecord }
            }
            return records
        } catch { try await valid(worker: worker); throw error }
    }
    private struct Observation {
        let records: [String: ChapterBookControlRecord]
        let fences: [ChapterCloudMetadataKey]
        let claim: ChapterBookCloudClaim?
        let head: ChapterBookCloudHead
    }
    private func observe(_ admission: ChapterBookWorkAdmission, worker: Bool) async throws -> Observation {
        guard admission.request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let scope = admission.readSet.scope.identifier, render = try admission.request.renderKey(), rootKey = Self.root(scope)
        guard let initial = try await fetch([rootKey], worker: worker)[rootKey.key] else { throw ChapterDemandTransportError.inconsistentSnapshot }
        let root = try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, initial.payload)
        try root.validate(account: session.accountPartition, scope: scope)
        let members = root.members.keys.sorted().map { Self.member(scope, UUID(uuidString: $0)!) }
        let fences = [rootKey] + members
        let records = try await fetch(fences + [Self.claim(scope, render), Self.head(scope, render)], worker: worker)
        guard let sameRoot = records[rootKey.key], sameRoot.tag == initial.tag, sameRoot.payload == initial.payload else {
            throw ChapterDemandTransportError.conflict
        }
        var selected: ChapterBookCloudDevice?
        for key in members {
            guard let record = records[key.key] else { throw ChapterDemandTransportError.inconsistentSnapshot }
            let device = try ChapterBookCloudControl.decode(ChapterBookCloudDevice.self, record.payload)
            try device.validate(account: session.accountPartition, scope: scope, device: device.intent.deviceID)
            guard key == Self.member(scope, device.intent.deviceID),
                  root.members[device.intent.deviceID.uuidString.lowercased()] == (try ChapterBookCloudControl.digest(device)) else {
                throw ChapterDemandTransportError.inconsistentSnapshot
            }
            if device.intent.deviceID == admission.readSet.intent.deviceID { selected = device }
        }
        guard let selected, selected.intent.wanted, selected.intent == admission.readSet.intent,
              selected.readSet == (try ChapterBookReadSetIdentity(admission.readSet)) else { throw ChapterWorkerError.staleClaim }
        let claim = try records[Self.claim(scope, render).key].map { try ChapterBookWorkWire.decode(ChapterBookCloudClaim.self, $0.payload) }
        if let claim {
            guard claim.version == 1, claim.accountPartition == session.accountPartition, claim.scopeID == scope,
                  claim.renderKey == render, claim.chapterIndex == admission.chapterIndex, claim.generation > 0,
                  claim.wantedRevision > 0, claim.entry.renderKey == render else { throw ChapterDemandTransportError.invalidRecord }
            try claim.entry.validate(scope: admission.readSet.scope)
        }
        let head = try records[Self.head(scope, render).key].map { try ChapterBookWorkWire.decode(ChapterBookCloudHead.self, $0.payload) }
            ?? ChapterBookCloudHead(admission)
        try head.validate(admission)
        guard claim != nil || head.segmentCount == 0 else { throw ChapterDemandTransportError.inconsistentSnapshot }
        return .init(records: records, fences: fences, claim: claim, head: head)
    }
    private func write(_ key: ChapterCloudMetadataKey, _ payload: Data, _ observation: Observation) -> ChapterCloudMetadataWrite {
        .init(key: key, expected: observation.records[key.key], payload: payload)
    }
    private func fenced(_ observation: Observation) throws -> [ChapterCloudMetadataWrite] {
        try observation.fences.map {
            guard let record = observation.records[$0.key] else { throw ChapterDemandTransportError.inconsistentSnapshot }
            return .init(key: $0, expected: record, payload: record.payload)
        }
    }
    private func commit(_ writes: [ChapterCloudMetadataWrite]) async throws {
        try await authorized(worker: true)
        do {
            let saved = try await store.save(writes); try await valid(worker: true)
            guard saved.count == writes.count, writes.allSatisfy({ saved[$0.key.key]?.payload == $0.payload && saved[$0.key.key]?.type == $0.key.type }) else {
                throw ChapterDemandTransportError.invalidRecord
            }
        } catch {
            try await valid(worker: true)
            guard let failure = error as? ChapterDemandTransportError, failure == .uncertain || failure == .conflict else { throw error }
            let actual = try await fetch(writes.map(\.key), worker: true)
            guard actual.count == writes.count, writes.allSatisfy({ actual[$0.key.key]?.payload == $0.payload }) else {
                throw ChapterDemandTransportError.conflict
            }
        }
    }
    private func current(_ token: ChapterBookCloudWorkToken, _ admission: ChapterBookWorkAdmission, _ observation: Observation) throws {
        guard token.session == session, observation.claim == token.claim, token.claim.active else { throw ChapterWorkerError.staleClaim }
        try token.claim.validate(admission)
    }
    package func acquire(_ admission: ChapterBookWorkAdmission, workerID: UUID, runID: UUID) async throws -> ChapterBookCloudWorkToken {
        guard !occupied else { throw ChapterWorkerError.busy }; occupied = true; defer { occupied = false }
        let before = try await observe(admission, worker: true)
        // Even this same run cannot acquire an already active claim twice.
        // A role lock is not proof that its previous producer has joined.
        if before.claim?.active == true { throw ChapterWorkerError.busy }
        // A partial prefix survives. It is not permission to restart synthesis
        // or to replace existing indices. Recovery is a separate explicit path.
        guard before.head.segmentCount == 0, (before.claim?.generation ?? 0) < UInt64.max else { throw ChapterWorkerError.invalidTransition }
        let set = admission.readSet
        let claim = ChapterBookCloudClaim(version: 1, accountPartition: session.accountPartition, scopeID: set.scope.identifier,
            renderKey: try admission.request.renderKey(), chapterIndex: admission.chapterIndex, deviceID: set.intent.deviceID,
            wantedRevision: set.intent.wantedRevision, entry: admission.entry, workerID: workerID, runID: runID,
            claimID: UUID(), generation: (before.claim?.generation ?? 0) + 1, active: true)
        var writes = try fenced(before)
        writes.append(write(Self.claim(claim.scopeID, claim.renderKey), try ChapterBookWorkWire.encode(claim), before))
        writes.append(write(Self.head(claim.scopeID, claim.renderKey), try ChapterBookWorkWire.encode(before.head), before))
        try await commit(writes)
        let actual = try await observe(admission, worker: true)
        let token = ChapterBookCloudWorkToken(claim, session: session); try current(token, admission, actual); return token
    }
    /// Resume ONLY on the same installation holding its exclusive role lock,
    /// after the original producer joined or the previous process died. There
    /// is no timeout-based takeover. Existing segment indices are immutable.
    package func resumeAfterJoin(_ admission: ChapterBookWorkAdmission, workerID: UUID, runID: UUID) async throws -> ChapterBookCloudWorkToken {
        guard !occupied else { throw ChapterWorkerError.busy }; occupied = true; defer { occupied = false }
        let before = try await observe(admission, worker: true)
        guard var claim = before.claim, claim.workerID == workerID else { throw ChapterWorkerError.busy }
        // A new wanted generation may reuse completed exact output, but must
        // never resume a partial stream from a different source/options intent.
        guard claim.accountPartition == admission.request.accountPartition,
              claim.scopeID == admission.readSet.scope.identifier,
              claim.renderKey == (try admission.request.renderKey()),
              claim.chapterIndex == admission.chapterIndex, claim.entry == admission.entry else {
            throw ChapterWorkerError.staleClaim
        }
        guard claim.generation < UInt64.max else { throw ChapterWorkerError.invalidTransition }
        claim = ChapterBookCloudClaim(version: claim.version, accountPartition: claim.accountPartition,
            scopeID: claim.scopeID, renderKey: claim.renderKey, chapterIndex: claim.chapterIndex,
            deviceID: admission.readSet.intent.deviceID, wantedRevision: admission.readSet.intent.wantedRevision, entry: claim.entry,
            workerID: workerID, runID: runID, claimID: UUID(), generation: claim.generation + 1, active: true)
        var writes = try fenced(before)
        writes.append(write(Self.claim(claim.scopeID, claim.renderKey), try ChapterBookWorkWire.encode(claim), before))
        writes.append(write(Self.head(claim.scopeID, claim.renderKey), try ChapterBookWorkWire.encode(before.head), before))
        try await commit(writes)
        let token = ChapterBookCloudWorkToken(claim, session: session)
        try current(token, admission, await observe(admission, worker: true)); return token
    }
    /// Boundary observation, NOT a lock across subsequent model work. Actual
    /// output publication repeats the complete conditional transaction.
    package func requireCurrent(_ token: ChapterBookCloudWorkToken, admission: ChapterBookWorkAdmission) async throws {
        let actual = try await observe(admission, worker: true); try current(token, admission, actual)
    }
    package func append(_ manifest: ChapterSegmentManifest, content: ChapterCloudSegmentServerReceipt,
                        token: ChapterBookCloudWorkToken, admission: ChapterBookWorkAdmission, originalText: String) async throws {
        guard !occupied else { throw ChapterWorkerError.busy }; occupied = true; defer { occupied = false }
        guard content.session == session, content.manifestSHA256 == (try manifest.sha256()), content.key == "s-" + content.manifestSHA256 else {
            throw ChapterDemandTransportError.invalidRecord
        }
        let before = try await observe(admission, worker: true); try current(token, admission, before)
        let claim = token.claim, pointer = Self.segment(claim.scopeID, claim.renderKey, manifest.segmentIndex)
        var head = before.head
        try head.append(manifest, admission: admission, text: originalText)
        let existing = try await fetch([pointer], worker: true)
        // Never overwrite an existing index, even if an unrelated server actor
        // inserted identical bytes outside our atomic head publication.
        guard existing.isEmpty else { throw ChapterDemandTransportError.conflict }
        var writes = try fenced(before)
        writes.append(write(Self.claim(claim.scopeID, claim.renderKey), try ChapterBookWorkWire.encode(claim), before))
        writes.append(write(Self.head(claim.scopeID, claim.renderKey), try ChapterBookWorkWire.encode(head), before))
        writes.append(.init(key: pointer, expected: nil, payload: try manifest.encoded()))
        try await commit(writes)
        let actual = try await observe(admission, worker: true); try current(token, admission, actual)
        guard actual.head == head else { throw ChapterDemandTransportError.conflict }
    }
    package func seal(_ seal: ChapterSegmentCompletionSeal, token: ChapterBookCloudWorkToken,
                      admission: ChapterBookWorkAdmission, originalText: String) async throws {
        guard !occupied else { throw ChapterWorkerError.busy }; occupied = true; defer { occupied = false }
        let before = try await observe(admission, worker: true); try current(token, admission, before)
        var head = before.head; try head.finish(seal, admission: admission, text: originalText)
        if before.head == head { return }
        var writes = try fenced(before)
        writes.append(write(Self.claim(token.claim.scopeID, token.claim.renderKey), try ChapterBookWorkWire.encode(token.claim), before))
        writes.append(write(Self.head(token.claim.scopeID, token.claim.renderKey), try ChapterBookWorkWire.encode(head), before))
        try await commit(writes)
        let actual = try await observe(admission, worker: true); try current(token, admission, actual)
        guard actual.head == head else { throw ChapterDemandTransportError.conflict }
    }
    /// This method does NOT own or prove producer joins. The eventual host must
    /// await the ORIGINAL render/callback/upload Task.result before calling it.
    /// Cancellation of Reader demand does not prevent conditional cleanup.
    package func releaseAfterJoin(_ token: ChapterBookCloudWorkToken) async throws {
        guard !occupied else { throw ChapterWorkerError.busy }; occupied = true; defer { occupied = false }
        guard token.session == session else { throw ChapterWorkerError.staleClaim }
        let key = Self.claim(token.claim.scopeID, token.claim.renderKey)
        guard let record = try await fetch([key], worker: true)[key.key] else { throw ChapterWorkerError.staleClaim }
        let current = try ChapterBookWorkWire.decode(ChapterBookCloudClaim.self, record.payload)
        var released = token.claim; released.active = false
        if current == released { return }
        guard current == token.claim else { throw ChapterWorkerError.staleClaim }
        try await commit([.init(key: key, expected: record, payload: try ChapterBookWorkWire.encode(released))])
    }
    /// Current wanted metadata plus an ACTUAL ordered prefix. Audio remains
    /// unverified until the Reader's own bounded copy/hash/codec admission.
    package func prefix(_ admission: ChapterBookWorkAdmission, through index: Int?, originalText: String) async throws -> ChapterBookCloudPrefixObservation {
        guard !occupied else { throw ChapterWorkerError.busy }; occupied = true; defer { occupied = false }
        let before = try await observe(admission, worker: false), head = before.head
        if let index { guard (0..<4096).contains(index) else { throw ChapterWorkerError.invalidManifest } }
        let count = index.map { $0 + 1 } ?? head.segmentCount
        guard count >= 0, count <= head.segmentCount, index == nil || index! >= 0 else { throw ChapterWorkerError.invalidManifest }
        var prefix = try ChapterSegmentPrefix(request: admission.request, originalText: originalText)
        var manifests: [ChapterSegmentManifest] = []
        let scope = admission.readSet.scope.identifier, render = try admission.request.renderKey()
        for first in stride(from: 0, to: count, by: 32) {
            let keys = (first..<min(first + 32, count)).map { Self.segment(scope, render, $0) }
            let records = try await fetch(keys, worker: false)
            for key in keys {
                guard let record = records[key.key] else { throw ChapterDemandTransportError.inconsistentSnapshot }
                let manifest = try ChapterSegmentManifest.decode(record.payload, request: admission.request, originalText: originalText)
                try prefix.append(manifest); manifests.append(manifest)
            }
        }
        let actual = try await observe(admission, worker: false)
        guard actual.head == head else { throw ChapterDemandTransportError.conflict }
        if count == head.segmentCount {
            guard prefix.decodedFrameCount == head.decodedFrameCount, prefix.sourceEnd == head.sourceEnd,
                  prefix.tailSHA256 == head.tailSHA256 else { throw ChapterDemandTransportError.inconsistentSnapshot }
            if let seal = head.seal { try prefix.validate(seal) }
        }
        return .init(prefix: prefix, manifests: manifests, seal: count == head.segmentCount ? head.seal : nil)
    }
}

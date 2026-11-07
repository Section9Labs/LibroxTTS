import Foundation
import CryptoKit
import Darwin
import LibroxTTS
import KokoroPronunciation
import LibroxCTNative

/// Private native SDK qualification. Does not claim actual Librox audio-queue or background execution.
enum ApprovedExpressionQualification {
    struct Fixture: Decodable, Sendable {
        let id: String, text: String, language: String, narratorVoice: String
        let records: [Record]
    }
    struct Record: Decodable, Sendable {
        let index: Int, text: String, voiceID: String
        let nativeSampleCount: Int, deliveredSampleCount: Int, latentFrames: Int, joinedOffsetSamples: Int
        let nativePCM32SHA256: String, candidatePCM32SHA256: String
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func peakRSS() -> Int64 { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Int64(r.ru_maxrss) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func run(assets: URL, graphs: URL, fixtures: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        let cases = try decoder.decode([Fixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil,
            contextStyleDiagnostic: CTApprovedExpression.configuration(directory: graphs))
        var events: [[String: Any]] = []
        var hashes: [String: String] = [:]
        let initial = footprint(), started = Date()
        try await renderer.load(.plus, directory: assets, executionContext: .foreground)
        let loadSeconds = Date().timeIntervalSince(started), loaded = footprint()
        for (phase, context, selectedCases) in [
            ("gpu-first", NarrationRenderer.ExecutionContext.foreground, cases),
            ("gpu-warm", .foreground, Array(cases.prefix(4))),
            ("cpu-handoff", .background, Array(cases.prefix(4))),
            ("gpu-return", .foreground, Array(cases.prefix(4)))
        ] {
            let transition = Date()
            try await renderer.load(.plus, directory: assets, executionContext: context)
            events.append(["phase": phase, "transitionSeconds": Date().timeIntervalSince(transition), "footprint": footprint()])
            for fixture in selectedCases {
                let directory = fixtures.appendingPathComponent(fixture.id)
                let cast = try BookVoiceCast.restore(Data(contentsOf: directory.appendingPathComponent("cast.json")), bookID: "context-comparison")
                let plan = try await NarrationPipeline().plan(fixture.text, model: .plus,
                    bookID: "context-comparison", chapterID: "1", narratorVoiceID: fixture.narratorVoice,
                    language: fixture.language, cast: cast, characterVoices: true, nativeExpression: true)
                let expectedRoles = try decoder.decode([String: CTRolePoolEvidence].self,
                    from: Data(contentsOf: directory.appendingPathComponent("role-evidence.json")))
                let expectedReporting = try decoder.decode([String: CTReportingPoolEvidence].self,
                    from: Data(contentsOf: directory.appendingPathComponent("reporting-evidence.json")))
                guard plan.units.count == fixture.records.count else { throw CTError.invalidTensor("unit planning drift") }
                var offset = 0
                for (unit, record) in zip(plan.units, fixture.records) {
                    guard unit.synthesisText == record.text, unit.voiceID == record.voiceID,
                          offset == record.joinedOffsetSamples else { throw CTError.invalidTensor("unit/voice/boundary drift") }
                    if let expression = unit.nativeExpression {
                        let key = expression.binding.renderCacheKey
                        guard expression.roles == expectedRoles[key], expression.reporting == expectedReporting[key] else {
                            throw CTError.invalidTensor("SDK expression evidence differs from accepted reference")
                        }
                    } else if unit.role == .dialogue, !expectedRoles.isEmpty {
                        throw CTError.invalidTensor("SDK omitted accepted dialogue context")
                    }
                    let noise = try CTTensor(shape: [1, 144, record.latentFrames], kind: .float32,
                        data: Data(contentsOf: directory.appendingPathComponent("noise-\(record.index).bin")))
                    let before = footprint(), begin = Date()
                    let rendered = try await renderer.renderNativeDiagnostic(unit, initialNoise: noise, captureTrace: false)
                    let elapsed = Date().timeIntervalSince(begin)
                    guard rendered.native.trace.isEmpty,
                          rendered.native.samples.count == record.nativeSampleCount,
                          rendered.samples.count == record.deliveredSampleCount else { throw CTError.invalidTensor("complete frames") }
                    let raw = rendered.native.samples.withUnsafeBytes { hash(Data($0)) }
                    let delivered = rendered.samples.withUnsafeBytes { hash(Data($0)) }
                    let exact = raw == record.nativePCM32SHA256 && delivered == record.candidatePCM32SHA256
                    #if os(macOS)
                    if phase != "cpu-handoff", !exact { throw CTError.invalidTensor("approved GPU PCM changed: " + fixture.id + "/\(record.index)") }
                    #endif
                    let key = fixture.id + "/\(record.index)"
                    if phase != "cpu-handoff" {
                        if let previous = hashes[key], previous != delivered { throw CTError.invalidTensor("same-device GPU drift") }
                        hashes[key] = delivered
                    }
                    offset += rendered.samples.count
                    events.append(["case": fixture.id, "unit": record.index, "voiceID": unit.voiceID,
                        "phase": phase, "seconds": elapsed, "audioSeconds": Double(rendered.samples.count) / 44100,
                        "beforeFootprint": before, "afterFootprint": footprint(), "graphSeconds": rendered.native.graphSeconds,
                        "rawPCM32SHA256": raw, "deliveredPCM32SHA256": delivered, "matchesAcceptedMacGPU": exact,
                        "contextDisposition": rendered.native.textContextDisposition.rawValue,
                        "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
                    try write(["events": events], to: output.appendingPathComponent("progress.json"))
                }
            }
        }
        await renderer.unload()
        try await Task.sleep(for: .milliseconds(500))
        let unloaded = footprint(), reloadStart = Date()
        try await renderer.load(.plus, directory: assets, executionContext: .foreground)
        let reloadSeconds = Date().timeIntervalSince(reloadStart)
        await renderer.unload()
        try write(["expressionIdentity": CTApprovedExpression.identity, "loadSeconds": loadSeconds,
            "reloadSeconds": reloadSeconds, "initialFootprint": initial, "loadedFootprint": loaded,
            "settledUnloadedFootprint": unloaded, "finalFootprint": footprint(), "peakResidentBytes": peakRSS(),
            "events": events, "sameDeviceGPUReplayExact": true,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "scope": "Optimized SDK shared planner and renderer, full frames, untraced calls and explicit backend transitions; not actual app background playback."],
            to: output.appendingPathComponent("receipt.json"))
    }
}

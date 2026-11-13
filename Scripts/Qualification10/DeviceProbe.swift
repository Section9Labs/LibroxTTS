import SwiftUI
import CoreML
import CryptoKit
import Darwin
import Synchronization
import PocketTTSCoreML
import PocketTTSMLX
import KokoroCatalog

@main struct QualificationApp: App {
    var body: some Scene { WindowGroup { QualificationView() } }
}
struct QualificationView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = "Preparing qualification…"
    var body: some View {
        VStack(spacing:20) { Text("LibroxTTS qualification").font(.title); Text(status).textSelection(.enabled) }
        .padding().onChange(of: phase) { _, next in DeviceQualification.foreground.withLock { $0 = next == .active } }
        .task {
            status = "Running qualification. Keep this app in the foreground."
            UIApplication.shared.isIdleTimerDisabled = true
            do { status = try await Task.detached { try await DeviceQualification.run() }.value }
            catch {
                status = "Failed: \(error)"
                try? Data(status.utf8).write(to: URL.documentsDirectory.appendingPathComponent("error.txt"))
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
enum DeviceQualification {
    static let foreground = Mutex(true)
    struct Event: Codable, Equatable { let text: String; let start: Int; let end: Int; let accepted: Int }
    struct Row: Codable {
        let name: String; let seconds: Double; let firstFrameSeconds: Double
        let samples: Int; let sha256: String; let events: [Event]
        let footprint: UInt64; let thermal: Int
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
            task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
        } }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func run() async throws -> String {
        let processStarted = ProcessInfo.processInfo.systemUptime
        let args = CommandLine.arguments
        func argument(_ name: String, _ fallback: String) -> String {
            args.firstIndex(of:name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? fallback
        }
        let label = argument("--label","qualification"), duration = Double(argument("--seconds","0")) ?? 0
        let root = URL.documentsDirectory.appendingPathComponent(args.contains("--fresh") ? "Assets-" + label : "Assets")
        if !FileManager.default.fileExists(atPath:root.path) {
            try FileManager.default.copyItem(at: Bundle.main.resourceURL!.appendingPathComponent("Assets"), to:root)
        }
        let prepared = ProcessInfo.processInfo.systemUptime
        try PocketTTSCoreMLAssets.prepare(in:root,language:"en")
        let preparationSeconds = ProcessInfo.processInfo.systemUptime - prepared
        let output = URL.documentsDirectory.appendingPathComponent(label)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let metadata: [String:Any] = ["os":ProcessInfo.processInfo.operatingSystemVersionString,
            "freshAssetCopy":args.contains("--fresh"),"preparationSeconds":preparationSeconds,"setupSeconds":ProcessInfo.processInfo.systemUptime - processStarted,"durationGoal":duration,"cpuBudget":"unmetered foreground",
            "runtime":PocketTTSCoreMLEngine.runtimeIdentity]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("environment.json"))
        let engine = PocketTTSCoreMLEngine(directory:root)
        await engine.setCPUBudgetFraction(nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        var rows: [Row] = []
        let book = "She rested her hand against the door. For a moment, she could almost hear his voice again. It was the small things she remembered: the way he folded the newspaper, the sound of his keys on the table, and the cup he always left beside the window. She waited. Nobody came."
        let begun = ProcessInfo.processInfo.systemUptime
        var index = 0
        repeat {
            let steps = duration > 0 ? 4 : [1,2,3,4,5,6,7,8,2,4,4,4][index]
            let text = duration > 0 || index == 11 ? book : "The door was open."
            let style: PocketTTSDeliveryStyle = duration > 0 || index != 9 && index != 10 ? .calm : .original
            let voice = index == 10 && duration == 0 ? "alba" : "caro_davy"
            await engine.setRandomSeed(42)
            let capture = Mutex((samples:[Float](),events:[Event](),first:Optional<Double>.none,peak:UInt64(0)))
            let started = ProcessInfo.processInfo.systemUptime
            await engine.setResourceObserver { snapshot in capture.withLock { $0.peak = max($0.peak,snapshot.footprintBytes) } }
            try await engine.renderFrames(text,voiceID:"pocket-\(voice)-en-v1",chunking:.carefulReading,samplerSteps:steps,deliveryStyle:style,onTextChunk:{ event in
                capture.withLock { $0.events.append(.init(text:event.text,start:event.startSample,end:event.endSample,accepted:$0.samples.count)) }
            }, receive:{ frame in
                guard foreground.withLock({ $0 }) else { throw CancellationError() }
                capture.withLock {
                    if $0.first == nil { $0.first = ProcessInfo.processInfo.systemUptime - started }
                    $0.samples += frame
                }
            })
            let seconds = ProcessInfo.processInfo.systemUptime - started, result = capture.withLock { $0 }
            let pcm = result.samples.withUnsafeBytes { Data($0) }
            let row = Row(name:"trial-\(index)-steps\(steps)",seconds:seconds,firstFrameSeconds:result.first ?? seconds,
                samples:result.samples.count,sha256:SHA256.hash(data:pcm).map { String(format:"%02x",$0) }.joined(),
                events:result.events,footprint:max(result.peak,footprint()),thermal:ProcessInfo.processInfo.thermalState.rawValue)
            if duration > 0, let first = rows.first {
                guard row.sha256 == first.sha256, row.events == first.events else { throw NSError(domain:"Qualification",code:1,userInfo:[NSLocalizedDescriptionKey:"Repeated PCM/events changed"]) }
            }
            if duration == 0 || index == 0 { try pcm.write(to:output.appendingPathComponent(row.name+".f32")) }
            rows.append(row)
            try encoder.encode(rows).write(to:output.appendingPathComponent("report.json"),options:.atomic)
            index += 1
        } while duration > 0 ? ProcessInfo.processInfo.systemUptime - begun < duration : index < 12
        await engine.unload()
        try Data("complete".utf8).write(to:output.appendingPathComponent("complete.txt"),options:.atomic)
        return "Completed \(label): \(rows.count) renders"
    }
}

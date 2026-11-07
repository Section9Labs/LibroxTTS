import SwiftUI
import LibroxTTS
import LibroxCTNative
@main struct QualificationApp: App {
    var body: some Scene { WindowGroup { QualificationView() } }
}
struct QualificationView: View {
    @State private var status = "Private expression qualification"
    @State private var running = false
    var body: some View {
        VStack(spacing:24) {
            Text(status)
            Button("Run approved expression") { run() }.disabled(running)
        }.padding().task {
            if ProcessInfo.processInfo.arguments.contains("--run") { run() }
        }.onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func run() {
        running = true; UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let root = URL.documentsDirectory
            let output = root.appendingPathComponent("qualification-"+UUID().uuidString)
            do {
                try await ApprovedExpressionQualification.run(assets:root.appendingPathComponent("Assets"), graphs:root.appendingPathComponent("Graphs"), fixtures:root.appendingPathComponent("Fixtures"), output:output,
                    repositoryID: FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/expression/manifest.json").path)
                        ? CTApprovedExpression.installationIdentity : CTAssets.identity)
                status = output.lastPathComponent; print("EXPRESSION_QUALIFICATION_COMPLETE " + status)
            } catch { status = String(describing:error); print("EXPRESSION_QUALIFICATION_FAILED " + status) }
            running = false; UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

import AppKit
import SwiftUI
import ServiceManagement

@main struct LibroxCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    init() { setenv("MLX_ENABLE_TF32", "0", 1) }
    var body: some Scene {
        MenuBarExtra("Librox", systemImage: delegate.model.busy ? "waveform" : "book.closed") {
            CompanionPanel(model: delegate.model)
        }.menuBarExtraStyle(.window)
        Settings { CompanionSettings(model: delegate.model) }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Quit Librox Companion") { NSApp.terminate(nil) }.keyboardShortcut("q")
                }
            }
        Window("Librox Companion", id: "review") { CompanionPanel(model: delegate.model) }
            .windowResizability(.contentSize).defaultLaunchBehavior(.suppressed)
    }
}

@MainActor final class CompanionDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionModel()
    private var quitting = false
    private var joined = false
    private var reviewWindow: NSWindow?
    private var diagnostic: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--review-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let checking = CommandLine.arguments.contains("--check-cloud") || CommandLine.arguments.contains("--check-delivery") || CommandLine.arguments.contains("--check-library")
        model.start(restoreEnabled: !checking && !CommandLine.arguments.contains("--library-only"), browseLibrary: !checking)
        if let index = CommandLine.arguments.firstIndex(of: "--check-library"), CommandLine.arguments.count > index + 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            diagnostic = Task { await model.checkLibrary(to: output); diagnostic = nil; NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--review-window") { showPanel() }
        if let index = CommandLine.arguments.firstIndex(of: "--check-cloud"), CommandLine.arguments.count > index + 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            diagnostic = Task { await model.checkCloud(to: output); diagnostic = nil; NSApp.terminate(nil) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-delivery"), CommandLine.arguments.count > index + 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            diagnostic = Task {
                await CompanionDeliveryCheck.run(model: model, output: output)
                diagnostic = nil
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel(); return true
    }
    private func showPanel() {
        if reviewWindow == nil {
            let view = NSHostingController(rootView: CompanionPanel(model: model))
            let window = NSWindow(contentViewController: view)
            window.title = "Librox Companion"; window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.center(); reviewWindow = window
        }
        reviewWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { model.importBook(at: url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if joined { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true; model.prepareForExit()
        let pendingDiagnostic = diagnostic
        pendingDiagnostic?.cancel()
        Task {
            await pendingDiagnostic?.value
            await model.stopForExit(); joined = true
            // Returning cancel lets the original main-actor event unwind.
            // AppKit's terminateLater nested loop can otherwise block the very
            // Swift concurrency work that must join before termination.
            sender.terminate(nil)
        }
        return .terminateCancel
    }
}

private enum Layout {
    static let width: CGFloat = 360
    static let inset: CGFloat = 20
    static let group: CGFloat = 16
    static let row: CGFloat = 8
}

struct CompanionPanel: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.group) {
            HStack {
                Text("Librox").font(.title2.weight(.semibold))
                Spacer()
                Text("Companion").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Layout.row) {
                Label(model.status, systemImage: model.busy ? "waveform" : model.enabled ? "checkmark.circle" : "moon")
                    .font(.headline).accessibilityAddTraits(.updatesFrequently)
                Text(model.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.setEnabled(!model.enabled)
            } label: {
                HStack {
                    if model.changing { ProgressView().controlSize(.small) }
                    Text(model.enabled ? "Pause Preparation" : "Enable This Mac")
                    Spacer()
                    Image(systemName: model.enabled ? "pause.fill" : "play.fill")
                }
            }.disabled(model.changing || (!model.enabled && !model.queueSchemaReady)).buttonStyle(.borderedProminent)
                .help("Pausing this Mac preserves requests and completed audio.")
            Divider()
            HStack {
                Text("Your Library").font(.headline)
                Spacer()
                Button("Refresh Library", systemImage: "arrow.clockwise", action: model.refreshLibrary)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Refresh from iCloud")
                Button("Add Book…", systemImage: "plus", action: model.importBook).labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("Add an EPUB, text file, or Librox book export")
            }
            if model.libraryBooks.count > 8 {
                TextField("Find a book", text: $model.librarySearch).textFieldStyle(.roundedBorder)
            }
            Text(model.libraryStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.group) {
                    if model.visibleLibraryBooks.isEmpty, !model.librarySearch.isEmpty {
                        Text("No matching books.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.visibleLibraryBooks) { book in
                        HStack(alignment: .top, spacing: Layout.row) {
                            Image(systemName: book.isFinished ? "checkmark.circle" : "book.closed").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.title).lineLimit(2).help(book.title)
                                if let author = book.author, !author.isEmpty {
                                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let opened = book.lastOpened {
                                    Text("Opened \(opened.formatted(date: .abbreviated, time: .omitted)) · \(Int(book.progress * 100))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: Layout.row)
                            if model.selectingBook == book.id { ProgressView().controlSize(.small) }
                            else {
                                Button("Prepare Audiobook", systemImage: "play.fill") { model.selectLibraryBook(book) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .disabled(!book.canPrepare || model.selectingBook != nil || model.changing)
                                    .help(book.canPrepare ? "Prepare \(book.title) on this Mac" : "Narration currently supports EPUB and text books.")
                            }
                        }
                    }
                    if !model.visiblePreparations.isEmpty || model.remoteBooks.contains(where: \.requested) {
                        Divider()
                        Text("Preparation").font(.headline)
                    }
                        ForEach(model.visiblePreparations) { book in
                            HStack(alignment: .top, spacing: Layout.row) {
                                Image(systemName: "book.closed").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.title).lineLimit(2).help(book.title)
                                    Text(book.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Layout.row)
                                Button("Prepare", systemImage: "play.fill") { model.prepare(book.id) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!model.canPrepare)
                                    .help("Prepare \(book.title)")
                            }.contextMenu {
                                Button("Prepare Audiobook") { model.prepare(book.id) }.disabled(!model.canPrepare)
                                if book.scopeID != nil || book.detail == "Waiting for this Mac" { Button("Stop This Request") { model.cancel(book.id) } }
                            }
                        }
                        ForEach(model.remoteBooks.filter { remote in remote.requested && !model.books.contains { $0.scopeID == remote.scopeID } }) { book in
                            HStack(alignment: .top, spacing: Layout.row) {
                                Image(systemName: "icloud").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.title).lineLimit(2)
                                    Text("Requested in Librox").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(height: 260)
            if let failure = model.failure {
                VStack(alignment: .leading, spacing: Layout.row) {
                    Label(failure, systemImage: "exclamationmark.circle").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again", action: model.retry)
                }
            }
            Divider()
            HStack {
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
                    .buttonStyle(.borderless).keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).keyboardShortcut("q")
            }
        }.padding(Layout.inset).frame(width: Layout.width)
    }
}

struct CompanionSettings: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        Form {
            Section("Narration") {
                Picker("Language", selection: $model.language) {
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                }
                Picker("Audio files", selection: $model.lossless) {
                    Text("Smaller · AAC").tag(false)
                    Text("Lossless · ALAC").tag(true)
                }
                Text("Applies to books prepared from this Mac. iPhone requests keep their own narration settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("This Mac") {
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                if model.loginApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Button("Narration Files…", action: model.installModels)
                Button("Show Prepared Files", action: model.revealFiles)
                Text("Chatterbox Multilingual\nEnglish and Spanish · Stock narrator")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 440).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Layout.row)
    }
}

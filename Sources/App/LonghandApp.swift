import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = sender.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

@main
struct LonghandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()

    init() {
        FontFamily.registerBundledFonts()
    }

    var body: some Scene {
        Window("longhand", id: "main") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands { AppCommands(workspace: workspace) }

        Window("About longhand", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Settings {
            SettingsView()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var workspace: Workspace
    @AppStorage(Pref.viewMode) private var mode: ViewMode = .write
    @AppStorage(Pref.focusMode) private var focusMode = false
    @AppStorage(Pref.theme) private var theme: AppTheme = .system
    @ObservedObject private var chrome = ChromeState.shared
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var columnsBeforeFocus: NavigationSplitViewVisibility = .all

    var body: some View {
        // Palette is read during this render pass, so set it first.
        let _ = (Palette.theme = theme)
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(ViewMode.allCases) { m in
                        Label(m.title, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Write (⌘1) · Split (⌘2) · Preview (⌘3)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { t in Text(t.title).tag(t) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                }
                .help("Theme: Light ⌥⌘1 · Paper ⌥⌘2 · Sepia ⌥⌘3 · Dark ⌥⌘4")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $focusMode) {
                    Label("Focus", systemImage: "scope")
                }
                .help("Focus mode: dim all but the current paragraph (⌘⇧F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chrome.toggleDistractionFree()
                } label: {
                    Label("Distraction-free", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Distraction-free: hide everything, go fullscreen (⌘⇧D)")
            }
        }
        .toolbar(chrome.distractionFree ? .hidden : .visible, for: .windowToolbar)
        .onAppear {
            NSApp.appearance = theme.appearance
            chrome.installMouseMonitor()
        }
        .onChange(of: theme) { _, t in NSApp.appearance = t.appearance }
        .onChange(of: chrome.distractionFree) { _, on in
            if on {
                columnsBeforeFocus = columns
                columns = .detailOnly
            } else {
                columns = columnsBeforeFocus
            }
            DispatchQueue.main.async { chrome.syncFullScreen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            // Leaving fullscreen with the green button / Esc also leaves distraction-free.
            if chrome.distractionFree { chrome.distractionFree = false }
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var workspace: Workspace
    @AppStorage(Pref.viewMode) private var mode: ViewMode = .write
    @AppStorage(Pref.focusMode) private var focusMode = false
    @AppStorage(Pref.typewriter) private var typewriter = false
    @AppStorage(Pref.hideSyntax) private var hideSyntax = false
    @AppStorage(Pref.fontSize) private var fontSize: Double = 16
    @AppStorage(Pref.showStatusBar) private var showStatusBar = true
    @AppStorage(Pref.theme) private var theme: AppTheme = .system
    @AppStorage(Pref.keepLineBreaks) private var keepLineBreaks = true
    @AppStorage(Pref.fontFamily) private var family: FontFamily = .quattro
    @ObservedObject private var chrome = ChromeState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About longhand") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { workspace.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(workspace.recentFolders, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { workspace.openFolder(URL(fileURLWithPath: path)) }
                }
                if !workspace.recentFolders.isEmpty {
                    Divider()
                    Button("Clear Menu") { workspace.clearRecents() }
                }
            }
            Button("New Markdown File") {
                if let folder = workspace.document?.directory ?? workspace.rootURL {
                    workspace.createMarkdownFile(in: folder)
                }
            }
            .keyboardShortcut("n")
            .disabled(workspace.rootURL == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace.document?.save() }
                .keyboardShortcut("s")
                .disabled(workspace.document == nil)
            Button("Reveal in Finder") {
                if let url = workspace.document?.url ?? workspace.imageURL { workspace.revealInFinder(url) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to longhand") { workspace.openWelcome() }
        }
        CommandMenu("Format") {
            Button("Bold") { send(#selector(MarkdownTextView.toggleBold(_:))) }
                .keyboardShortcut("b")
            Button("Italic") { send(#selector(MarkdownTextView.toggleItalic(_:))) }
                .keyboardShortcut("i")
            Button("Inline Code") { send(#selector(MarkdownTextView.toggleCode(_:))) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Picker("Mode", selection: $mode) {
                Text("Write").tag(ViewMode.write).keyboardShortcut("1")
                Text("Split").tag(ViewMode.split).keyboardShortcut("2")
                Text("Preview").tag(ViewMode.preview).keyboardShortcut("3")
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Theme", selection: $theme) {
                Text("System").tag(AppTheme.system)
                Text("Light").tag(AppTheme.light).keyboardShortcut("1", modifiers: [.command, .option])
                Text("Paper").tag(AppTheme.paper).keyboardShortcut("2", modifiers: [.command, .option])
                Text("Sepia").tag(AppTheme.sepia).keyboardShortcut("3", modifiers: [.command, .option])
                Text("Dark").tag(AppTheme.dark).keyboardShortcut("4", modifiers: [.command, .option])
            }
            Divider()
            Button("Toggle Distraction-free") { chrome.toggleDistractionFree() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Picker("Font", selection: $family) {
                ForEach(FontFamily.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Focus Mode", isOn: $focusMode)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Typewriter Scrolling", isOn: $typewriter)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Toggle("Hide Markdown Syntax", isOn: $hideSyntax)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Toggle("Keep Line Breaks in Preview", isOn: $keepLineBreaks)
            Toggle("Show Quiet Bar", isOn: $showStatusBar)
            Divider()
            Button("Bigger Text") { fontSize = min(28, fontSize + 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { fontSize = max(11, fontSize - 1) }
                .keyboardShortcut("-")
            Button("Default Text Size") { fontSize = 16 }
                .keyboardShortcut("0")
            Divider()
        }
    }

    private func send(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

struct SettingsView: View {
    @AppStorage(Pref.theme) private var theme: AppTheme = .system
    @AppStorage(Pref.fontFamily) private var family: FontFamily = .quattro
    @AppStorage(Pref.fontSize) private var fontSize: Double = 16
    @AppStorage(Pref.lineWidth) private var lineWidth: LineWidth = .medium
    @AppStorage(Pref.hideSyntax) private var hideSyntax = false
    @AppStorage(Pref.inlineImages) private var inlineImages = true
    @AppStorage(Pref.typewriter) private var typewriter = false
    @AppStorage(Pref.keepLineBreaks) private var keepLineBreaks = true

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Font", selection: $family) {
                ForEach(FontFamily.allCases) { f in
                    Text(f.title).font(Font(FontBook.preview(f))).tag(f)
                }
            }
            HStack {
                Slider(value: $fontSize, in: 11...28, step: 1) { Text("Size") }
                Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Picker("Line width", selection: $lineWidth) {
                ForEach(LineWidth.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Divider()
            Toggle("Hide Markdown syntax away from the cursor (Typora-style)", isOn: $hideSyntax)
            Toggle("Show images inline (Write mode)", isOn: $inlineImages)
            Toggle("Typewriter scrolling", isOn: $typewriter)
            Toggle("Keep single line breaks in preview (Markua style)", isOn: $keepLineBreaks)
        }
        .padding(24)
        .frame(width: 460)
    }
}

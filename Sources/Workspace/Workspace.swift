import AppKit
import Combine

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var tree: [FileNode] = []
    @Published private(set) var document: MarkdownDocument?
    @Published private(set) var imageURL: URL?
    @Published var selection: URL? {
        didSet { if selection != oldValue { open(selection) } }
    }

    private var watcher: DirectoryWatcher?
    private var docCancellable: AnyCancellable?

    @Published private(set) var recentFolders: [String] = UserDefaults.standard.stringArray(forKey: Keys.recentFolders) ?? []

    private enum Keys {
        static let lastFolder = "lastFolder"
        static let lastFile = "lastFile"
        static let recentFolders = "recentFolders"
        static let welcomeShown = "welcomeShown"
    }

    init() {
        if !UserDefaults.standard.bool(forKey: Keys.welcomeShown) {
            UserDefaults.standard.set(true, forKey: Keys.welcomeShown)
            DispatchQueue.main.async { [weak self] in self?.openWelcome() }
        }
        if let path = UserDefaults.standard.string(forKey: Keys.lastFolder),
           FileManager.default.fileExists(atPath: path) {
            openFolder(URL(fileURLWithPath: path))
            if let file = UserDefaults.standard.string(forKey: Keys.lastFile),
               FileManager.default.fileExists(atPath: file) {
                selection = URL(fileURLWithPath: file)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.document?.save() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.document?.save() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.document?.save() }
        }
    }

    var allFiles: [FileNode] { tree.flatMap(\.allFiles) }

    func relativePath(of url: URL) -> String {
        guard let root = rootURL?.standardizedFileURL.path else { return url.lastPathComponent }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    // MARK: - Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder (or a Markdown file) to open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            openFolder(url)
        } else {
            openFolder(url.deletingLastPathComponent())
            selection = url
        }
    }

    func openFolder(_ url: URL) {
        document?.save()
        rootURL = url
        selection = nil
        reloadTree()
        UserDefaults.standard.set(url.path, forKey: Keys.lastFolder)
        recentFolders = [url.path] + recentFolders.filter { $0 != url.path }.prefix(7)
        UserDefaults.standard.set(recentFolders, forKey: Keys.recentFolders)
        watcher = DirectoryWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.fileSystemChanged() }
        }
    }

    func reloadTree() {
        guard let rootURL else { tree = []; return }
        tree = FileTreeLoader.load(rootURL)
        ImageCache.workspaceRoot = rootURL
        var index: [String: URL] = [:]
        for node in allFiles where node.kind == .image {
            let key = node.name.lowercased()
            if index[key] == nil { index[key] = node.url }
        }
        ImageCache.imageIndex = index
    }

    private func fileSystemChanged() {
        reloadTree()
        document?.reloadIfChangedOnDisk()
        ImageCache.shared.removeAll()
        if let sel = selection, !FileManager.default.fileExists(atPath: sel.path) {
            selection = nil
        }
    }

    private func open(_ url: URL?) {
        document?.save()
        guard let url, let kind = FileKind.of(url) else {
            // folders or nil: keep current document visible
            if url == nil { document = nil; imageURL = nil }
            return
        }
        switch kind {
        case .markdown:
            document = MarkdownDocument(url: url)
            imageURL = nil
            docCancellable = document?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        case .image:
            document = nil
            imageURL = url
        case .folder:
            return
        }
        UserDefaults.standard.set(url.path, forKey: Keys.lastFile)
    }

    /// Open a link clicked in the preview, if it points at a file in this workspace.
    func openLinkedFile(_ url: URL) -> Bool {
        guard FileKind.of(url) != nil, FileManager.default.fileExists(atPath: url.path) else { return false }
        selection = url.standardizedFileURL
        return true
    }

    func clearRecents() {
        recentFolders = []
        UserDefaults.standard.removeObject(forKey: Keys.recentFolders)
    }

    /// Copies the bundled welcome note to ~/Documents/longhand (once) and opens it.
    func openWelcome() {
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/longhand")
        let file = folder.appendingPathComponent("Welcome to longhand.md")
        if !fm.fileExists(atPath: file.path), let bundled = Bundle.main.url(forResource: "Welcome to longhand", withExtension: "md") {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.copyItem(at: bundled, to: file)
        }
        let logo = folder.appendingPathComponent("longhand-logo.png")
        if !fm.fileExists(atPath: logo.path), let bundledLogo = Bundle.main.url(forResource: "longhand-logo", withExtension: "png") {
            try? fm.copyItem(at: bundledLogo, to: logo)
        }
        guard fm.fileExists(atPath: file.path) else { return }
        openFolder(folder)
        selection = file
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func createMarkdownFile(in folder: URL) {
        var target = folder.appendingPathComponent("Untitled.md")
        var i = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("Untitled \(i).md")
            i += 1
        }
        FileManager.default.createFile(atPath: target.path, contents: Data())
        reloadTree()
        selection = target
    }
}

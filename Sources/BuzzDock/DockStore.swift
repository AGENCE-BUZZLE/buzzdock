import AppKit
import Combine

/// Une icône d'application affichée dans le Dock.
struct DockEntry: Identifiable, Hashable {
    let id: String          // chemin standardisé du .app
    let url: URL
    let name: String
    let isPinned: Bool
    let isRunning: Bool
    let isFrontmost: Bool
    let isLaunching: Bool
}

/// Les emplacements du Dock, de gauche à droite.
enum DockSlot: Identifiable, Hashable {
    case launcher
    case app(DockEntry)
    case separator
    case downloads
    case trash

    var id: String {
        switch self {
        case .launcher: return "slot.launcher"
        case .app(let entry): return entry.id
        case .separator: return "slot.separator"
        case .downloads: return "slot.downloads"
        case .trash: return "slot.trash"
        }
    }
}

/// Un élément gardé sur la barre : une app ou un raccourci web, traités pareil.
enum BarItem: Codable, Hashable, Identifiable {
    case app(String)
    case link(WebLink)

    var id: String {
        switch self {
        case .app(let path): return path
        case .link(let link): return "link:\(link.id.uuidString)"
        }
    }
}

/// Ce qu'affiche le bloc des apps : apps (gardées ou ouvertes) et raccourcis web.
enum BarSlot: Identifiable {
    case app(DockEntry)
    case link(WebLink)

    var id: String {
        switch self {
        case .app(let entry): return entry.id
        case .link(let link): return "link:\(link.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case .app(let entry): return entry.name
        case .link(let link): return link.name
        }
    }
}

/// Un dossier d'apps, façon iPhone.
struct AppFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String]
    /// Raccourcis web rangés dans le dossier
    var links: [WebLink] = []

    init(id: UUID = UUID(), name: String, paths: [String], links: [WebLink] = []) {
        self.id = id
        self.name = name
        self.paths = paths
        self.links = links
    }

    enum CodingKeys: String, CodingKey { case id, name, paths, links }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        links = try c.decodeIfPresent([WebLink].self, forKey: .links) ?? []
    }
}

/// Modèle du Dock : apps épinglées (persistées) et apps ouvertes (temps réel).
@MainActor
final class DockStore: ObservableObject {
    struct Pin: Codable, Hashable {
        var path: String
    }

    @Published private(set) var pins: [Pin] = []
    @Published private(set) var running: [NSRunningApplication] = []
    @Published private(set) var frontmostPath: String?
    @Published private(set) var launching: Set<String> = []
    /// Icône en cours de glisser-déposer (réorganisation)
    /// Élément en cours de glisser : chemin d'app, ou « link:<id> » pour un raccourci web
    @Published var draggingID: String? {
        didSet { if draggingID == nil { dragSourceFolder = nil } }
    }
    /// Dossier d'où vient l'élément glissé (nil = barre ou extérieur)
    var dragSourceFolder: UUID?
    /// Vrai tant qu'un menu ou une fenêtre surgissante du Dock est ouvert (empêche le masquage)
    @Published var isInteracting = false
    @Published private(set) var folders: [AppFolder] = []
    /// Pastilles de notification par app (chemin → « 3 »)
    @Published private(set) var badges: [String: String] = [:]
    private var badgeTimer: Timer?
    /// Éléments gardés sur la barre (apps et raccourcis web, dans l'ordre choisi)
    @Published private(set) var barItems: [BarItem] = []

    /// Raccourcis web posés sur la barre
    var dockLinks: [WebLink] {
        barItems.compactMap { if case .link(let link) = $0 { return link } else { return nil } }
    }

    let settings: DockSettings
    private let pinsKey = "pins.v1"
    private let foldersKey = "folders.v1"
    private let dockLinksKey = "dockLinks.v1"
    private let barItemsKey = "barItems.v1"
    private var observers: [NSObjectProtocol] = []

    init(settings: DockSettings) {
        self.settings = settings
        loadPins()
        loadFolders()
        loadDockLinks()
        migrateLinksToSafari()
        refreshRunning()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
        observeWorkspace()
    }

    // MARK: Lecture

    var entries: [DockEntry] {
        let runningPaths = Dictionary(
            running.compactMap { app in app.bundleURL.map { (Self.key($0), app) } },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [DockEntry] = pins.map { pin in
            let url = URL(fileURLWithPath: pin.path)
            return makeEntry(url: url, pinned: true, running: runningPaths[pin.path] != nil)
        }
        if settings.showRunningApps {
            let pinned = Set(pins.map(\.path))
            for app in running {
                guard let url = app.bundleURL else { continue }
                let path = Self.key(url)
                guard !pinned.contains(path) else { continue }
                result.append(makeEntry(url: url, pinned: false, running: true))
            }
        }
        return result
    }

    var slots: [DockSlot] {
        var result: [DockSlot] = [.launcher]
        result += entries.map { .app($0) }
        if settings.showDownloads || settings.showTrash { result.append(.separator) }
        if settings.showDownloads { result.append(.downloads) }
        if settings.showTrash { result.append(.trash) }
        return result
    }

    private func makeEntry(url: URL, pinned: Bool, running: Bool) -> DockEntry {
        let path = Self.key(url)
        return DockEntry(
            id: path,
            url: url,
            name: Self.cachedName(for: url),
            isPinned: pinned,
            isRunning: running,
            isFrontmost: frontmostPath == path,
            isLaunching: launching.contains(path)
        )
    }

    /// Noms affichés mis en cache (lire le nom sur le disque à chaque rendu faisait ramer le Dock)
    private static var nameCache: [String: String] = [:]

    static func cachedName(for url: URL) -> String {
        if let name = nameCache[url.path] { return name }
        let name = AppCatalog.displayName(for: url)
        nameCache[url.path] = name
        return name
    }

    nonisolated static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Toutes les apps ouvertes, Finder en premier (mode widgets).
    var runningEntries: [DockEntry] {
        let pinned = Set(pins.map(\.path))
        var list: [DockEntry] = running.compactMap { app in
            guard let url = app.bundleURL else { return nil }
            return makeEntry(url: url, pinned: pinned.contains(Self.key(url)), running: true)
        }
        if let index = list.firstIndex(where: { $0.url.lastPathComponent == "Finder.app" }) {
            list.insert(list.remove(at: index), at: 0)
        }
        // Les apps en cours de lancement apparaissent tout de suite et rebondissent
        let shown = Set(list.map(\.id))
        for path in launching.sorted() where !shown.contains(path) {
            list.append(makeEntry(url: URL(fileURLWithPath: path), pinned: pinned.contains(path), running: false))
        }
        return list
    }

    func entry(for url: URL) -> DockEntry {
        let path = Self.key(url)
        let isRunning = running.contains { $0.bundleURL.map(Self.key) == path }
        return makeEntry(url: url, pinned: isOnBar(url), running: isRunning)
    }

    // MARK: Dossiers

    func apps(in folder: AppFolder) -> [URL] {
        folder.paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    func createFolder(named name: String = "Nouveau dossier", with urls: [URL] = []) -> UUID {
        var paths: [String] = []
        for url in urls where url.pathExtension == "app" {
            let path = Self.key(url)
            if !paths.contains(path) { paths.append(path) }
        }
        let folder = AppFolder(name: name, paths: paths)
        folders.append(folder)
        saveFolders()
        return folder.id
    }

    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        saveFolders()
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        saveFolders()
    }

    func moveFolder(_ id: UUID, by offset: Int) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard folders.indices.contains(target) else { return }
        folders.swapAt(index, target)
        saveFolders()
    }

    func add(_ url: URL, to id: UUID) {
        guard url.pathExtension == "app", let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let path = Self.key(url)
        guard !folders[index].paths.contains(path) else { return }
        folders[index].paths.append(path)
        saveFolders()
    }

    func remove(_ url: URL, from id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let path = Self.key(url)
        folders[index].paths.removeAll { $0 == path }
        saveFolders()
    }

    func move(_ url: URL, from source: UUID, to target: UUID) {
        add(url, to: target)
        remove(url, from: source)
    }

    func contains(_ url: URL, in id: UUID) -> Bool {
        folders.first { $0.id == id }?.paths.contains(Self.key(url)) ?? false
    }

    // MARK: Pastilles

    /// Dernière demande d'attention par app (une pastille qui augmente) : l'icône rebondit
    @Published private(set) var attention: [String: Date] = [:]
    private var badgesLoaded = false

    private var readingBadges = false

    /// Lecture des pastilles hors du fil principal (l'Accessibilité peut prendre quelques millisecondes)
    func refreshBadges() {
        guard !readingBadges, WindowService.isTrusted else { return }
        readingBadges = true
        DispatchQueue.global(qos: .utility).async {
            let fresh = DockBadges.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingBadges = false
                self.applyBadges(fresh)
            }
        }
    }

    private func applyBadges(_ fresh: [String: String]) {
        guard fresh != badges else {
            badgesLoaded = true
            return
        }
        func count(_ label: String?) -> Int {
            guard let label else { return 0 }
            return Int(label.filter(\.isNumber)) ?? (label.isEmpty ? 0 : 1)
        }
        var raised: [String] = []
        for (path, label) in fresh where count(label) > count(badges[path]) { raised.append(path) }
        badges = fresh
        // première lecture (démarrage) : on affiche les pastilles sans faire rebondir
        guard badgesLoaded else {
            badgesLoaded = true
            return
        }
        guard !raised.isEmpty else { return }
        for path in raised { attention[path] = Date() }
        // comme le Dock d'Apple : le Dock ressort pour montrer l'app qui t'appelle
        NotificationCenter.default.post(name: .buzzAttention, object: nil)
    }

    /// Pastille d'un dossier : total des pastilles de ses apps (comme sur iPhone)
    func badge(for folder: AppFolder) -> String? {
        var total = 0
        var any = false
        for path in folder.paths {
            guard let label = badges[path] else { continue }
            any = true
            total += Int(label.filter(\.isNumber)) ?? 0
        }
        guard any else { return nil }
        return total > 0 ? String(total) : "•"
    }

    // MARK: Raccourcis web

    /// Ouvre un raccourci. En mode « app web » (par défaut), fabrique la vraie app au premier clic,
    /// la met à la place du raccourci, puis la lance.
    func openLink(_ link: WebLink) {
        guard link.appWindow else {
            Browsers.open(link)
            return
        }
        if let existing = WebAppMaker.existingApp(for: link) {
            convertLink(link.id, toApp: existing)
            NSWorkspace.shared.openApplication(at: existing, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let futurePath = Self.key(WebAppMaker.appsFolder.appendingPathComponent("\(WebAppMaker.safeName(link.name)).app"))
        launching.insert(futurePath)
        WebAppMaker.make(link) { [weak self] appURL in
            guard let self else { return }
            guard let appURL else {
                self.launching.remove(futurePath)
                Browsers.open(link)   // échec : simple ouverture dans le navigateur
                return
            }
            self.convertLink(link.id, toApp: appURL)
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Remplace un raccourci par l'app web créée, à la même place (barre ou dossier).
    func convertLink(_ id: UUID, toApp appURL: URL) {
        let path = Self.key(appURL)
        if let index = barItems.firstIndex(where: { $0.id == "link:\(id.uuidString)" }) {
            barItems.removeAll { $0.id == path }
            let target = barItems.firstIndex(where: { $0.id == "link:\(id.uuidString)" }) ?? index
            barItems[target] = .app(path)
            saveBar()
        }
        for f in folders.indices {
            if let i = folders[f].links.firstIndex(where: { $0.id == id }) {
                folders[f].links.remove(at: i)
                if !folders[f].paths.contains(path) { folders[f].paths.append(path) }
            }
        }
        saveFolders()
    }

    /// Une fois : les raccourcis faits pour Chrome passent en apps web Safari.
    private func migrateLinksToSafari() {
        let key = "migration.liensSafari.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        func migrate(_ link: WebLink) -> WebLink {
            var copy = link
            if copy.browser == nil || copy.browser == "com.google.Chrome" {
                copy.browser = "com.apple.Safari"
                copy.appWindow = true
            }
            return copy
        }
        barItems = barItems.map { item in
            if case .link(let link) = item { return .link(migrate(link)) }
            return item
        }
        for f in folders.indices { folders[f].links = folders[f].links.map(migrate) }
        saveBar()
        saveFolders()
    }

    func addDockLink(_ link: WebLink) {
        insertOnBar(.link(link), at: nil)
    }

    func addLink(_ link: WebLink, to folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].links.append(link)
        saveFolders()
    }

    /// Retire le raccourci où qu'il soit (barre ou dossier).
    func removeLink(_ id: UUID) {
        barItems.removeAll { if case .link(let l) = $0 { return l.id == id } else { return false } }
        for index in folders.indices { folders[index].links.removeAll { $0.id == id } }
        saveBar()
        saveFolders()
    }

    func updateLink(_ link: WebLink) {
        for index in barItems.indices {
            if case .link(let l) = barItems[index], l.id == link.id { barItems[index] = .link(link) }
        }
        for f in folders.indices {
            if let index = folders[f].links.firstIndex(where: { $0.id == link.id }) { folders[f].links[index] = link }
        }
        saveBar()
        saveFolders()
    }

    func link(_ id: UUID) -> WebLink? {
        dockLinks.first { $0.id == id } ?? folders.lazy.flatMap(\.links).first { $0.id == id }
    }

    /// Déplace un raccourci vers un dossier, ou vers la barre (nil).
    func moveLink(_ id: UUID, toFolder folderID: UUID?, barIndex: Int? = nil) {
        guard let link = link(id) else { return }
        removeLink(id)
        if let folderID { addLink(link, to: folderID) } else { insertOnBar(.link(link), at: barIndex) }
    }

    func moveDockLink(_ id: UUID, by offset: Int) {
        guard let index = barItems.firstIndex(where: { $0.id == "link:\(id.uuidString)" }) else { return }
        let target = index + offset
        guard barItems.indices.contains(target) else { return }
        barItems.swapAt(index, target)
        saveBar()
    }

    /// Le site est-il déjà quelque part (raccourci ou app web) ?
    func hasSite(host: String, name: String) -> Bool {
        if dockLinks.contains(where: { $0.host == host }) { return true }
        if folders.contains(where: { $0.links.contains { $0.host == host } }) { return true }
        guard let app = WebAppMaker.existingApp(for: WebLink(name: name, url: host)) else { return false }
        let path = Self.key(app)
        return barItems.contains { $0.id == path } || folders.contains { $0.paths.contains(path) }
    }

    // MARK: Barre (apps et sites gardés)

    func isOnBar(_ url: URL) -> Bool {
        let path = Self.key(url)
        return barItems.contains { $0.id == path }
    }

    func barIndex(of id: String) -> Int? {
        barItems.firstIndex { $0.id == id }
    }

    /// Ajoute (ou déplace) un élément sur la barre, à la place donnée (nil = à la fin).
    func insertOnBar(_ item: BarItem, at index: Int?) {
        barItems.removeAll { $0.id == item.id }
        let target = min(max(index ?? barItems.count, 0), barItems.count)
        barItems.insert(item, at: target)
        saveBar()
    }

    func keepOnBar(_ url: URL, at index: Int? = nil) {
        guard url.pathExtension == "app" else { return }
        insertOnBar(.app(Self.key(url)), at: index)
    }

    func removeFromBar(_ id: String) {
        barItems.removeAll { $0.id == id }
        saveBar()
    }

    /// Réorganisation pendant le glisser : l'élément prend la place de la cible.
    func moveBarItem(_ id: String, to targetID: String) {
        guard id != targetID, let from = barIndex(of: id), let to = barIndex(of: targetID) else { return }
        let item = barItems.remove(at: from)
        barItems.insert(item, at: to)
        saveBar()
    }

    /// Le contenu du bloc des apps : Finder, éléments gardés, puis apps ouvertes.
    private var slotsCache: (key: Int, slots: [BarSlot])?

    /// Le contenu du bloc des apps, recalculé seulement quand quelque chose a changé
    var barSlots: [BarSlot] {
        var hasher = Hasher()
        hasher.combine(barItems)
        hasher.combine(running.map(\.processIdentifier))
        hasher.combine(frontmostPath)
        hasher.combine(launching)
        let key = hasher.finalize()
        if let slotsCache, slotsCache.key == key { return slotsCache.slots }
        let slots = computeBarSlots()
        slotsCache = (key, slots)
        return slots
    }

    private func computeBarSlots() -> [BarSlot] {
        var result: [BarSlot] = []
        var shown = Set<String>()
        for item in barItems {
            switch item {
            case .app(let path):
                guard FileManager.default.fileExists(atPath: path) else { continue }
                result.append(.app(self.entry(for: URL(fileURLWithPath: path))))
                shown.insert(path)
            case .link(let link):
                result.append(.link(link))
            }
        }
        var others = runningEntries.filter { !shown.contains($0.id) }
        if let index = others.firstIndex(where: { $0.url.lastPathComponent == "Finder.app" }) {
            result.insert(.app(others.remove(at: index)), at: 0)
        }
        result += others.map { .app($0) }
        return result
    }

    /// Dépose ce qui est en cours de glisser sur la barre, à la place donnée.
    /// Renvoie vrai si un élément interne a été traité.
    func dropDraggedOnBar(at index: Int?) -> Bool {
        guard let dragging = draggingID else { return false }
        let source = dragSourceFolder
        draggingID = nil
        if dragging.hasPrefix("link:"), let id = UUID(uuidString: String(dragging.dropFirst(5))) {
            moveLink(id, toFolder: nil, barIndex: index)
        } else {
            let url = URL(fileURLWithPath: dragging)
            keepOnBar(url, at: index)
            if let source { remove(url, from: source) }
        }
        return true
    }

    /// Apps (.app) ou adresses web venues de l'extérieur (Finder, barre d'adresse du navigateur).
    func dropExternal(_ urls: [URL], at index: Int?) {
        var position = index
        for url in urls {
            if url.isFileURL {
                guard url.pathExtension == "app" else { continue }
                keepOnBar(url, at: position)
            } else {
                insertOnBar(.link(WebLink(name: WebLink.guessName(for: url), url: url.absoluteString)), at: position)
            }
            position = position.map { $0 + 1 }
        }
    }

    /// Dépose ce qui est en cours de glisser dans un dossier (déplacement, comme sur iPhone).
    func dropDragged(into folderID: UUID) -> Bool {
        guard let dragging = draggingID else { return false }
        let source = dragSourceFolder
        draggingID = nil
        if dragging.hasPrefix("link:"), let id = UUID(uuidString: String(dragging.dropFirst(5))) {
            moveLink(id, toFolder: folderID)
        } else {
            let url = URL(fileURLWithPath: dragging)
            add(url, to: folderID)
            if source == nil { removeFromBar(dragging) }
            if let source, source != folderID { remove(url, from: source) }
        }
        return true
    }

    /// Glisser sur la Corbeille : retire l'élément de la barre ou de son dossier.
    func dropDraggedOnTrash() -> Bool {
        guard let dragging = draggingID else { return false }
        let source = dragSourceFolder
        draggingID = nil
        if dragging.hasPrefix("link:"), let id = UUID(uuidString: String(dragging.dropFirst(5))) {
            removeLink(id)
        } else if let source {
            remove(URL(fileURLWithPath: dragging), from: source)
        } else {
            removeFromBar(dragging)
        }
        return true
    }

    /// Dossier tout prêt : Instagram, TikTok, LinkedIn, X, Facebook, YouTube, Threads.
    func createSocialFolder() {
        let links = WebLink.socialPresets.map { preset -> WebLink in
            var copy = preset
            copy.id = UUID()
            return copy
        }
        folders.append(AppFolder(name: "Réseaux sociaux", paths: [], links: links))
        saveFolders()
    }

    private func loadDockLinks() {
        if let data = UserDefaults.standard.data(forKey: barItemsKey),
           let saved = try? JSONDecoder().decode([BarItem].self, from: data) {
            barItems = saved
        } else if let data = UserDefaults.standard.data(forKey: dockLinksKey),
                  let saved = try? JSONDecoder().decode([WebLink].self, from: data) {
            // ancienne version : raccourcis du bloc à part, repris sur la barre
            barItems = saved.map { .link($0) }
            saveBar()
        }
    }

    private func saveBar() {
        if let data = try? JSONEncoder().encode(barItems) {
            UserDefaults.standard.set(data, forKey: barItemsKey)
        }
    }

    /// Dossiers de départ : « Favoris » (le Dock macOS) puis les catégories les plus fournies.
    func rebuildDefaultFolders() {
        var result: [AppFolder] = []
        let favorites = pins.map(\.path).filter { !$0.hasSuffix("/Finder.app") }
        if !favorites.isEmpty { result.append(AppFolder(name: "Favoris", paths: favorites)) }
        let apps = AppCatalog.scan().filter { $0.category != "Autres" }
        let groups = Dictionary(grouping: apps, by: \.category)
            .sorted { $0.value.count > $1.value.count }
            .prefix(4)
        for (name, list) in groups {
            result.append(AppFolder(name: name, paths: list.map { Self.key($0.url) }))
        }
        folders = result
        saveFolders()
    }

    private func loadFolders() {
        if let data = UserDefaults.standard.data(forKey: foldersKey),
           let saved = try? JSONDecoder().decode([AppFolder].self, from: data) {
            folders = saved
        } else {
            rebuildDefaultFolders()
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
    }

    // MARK: Actions

    /// Ouvre l'app, ou la ramène au premier plan si elle tourne déjà
    /// (macOS envoie alors l'événement « reopen », qui recrée une fenêtre si besoin).
    func open(_ entry: DockEntry) {
        if !entry.isRunning { launching.insert(entry.id) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: config) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.launching.remove(entry.id) }
        }
    }

    /// Ouvre des fichiers déposés sur l'icône d'une app.
    func open(files: [URL], with entry: DockEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: entry.url, configuration: config)
    }

    func quit(_ entry: DockEntry) {
        runningApp(for: entry)?.terminate()
    }

    func hide(_ entry: DockEntry) {
        runningApp(for: entry)?.hide()
    }

    func revealInFinder(_ entry: DockEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func pin(_ url: URL, at index: Int? = nil) {
        let path = Self.key(url)
        guard url.pathExtension == "app" else { return }
        pins.removeAll { $0.path == path }
        let target = min(max(index ?? pins.count, 0), pins.count)
        pins.insert(Pin(path: path), at: target)
        savePins()
    }

    func unpin(_ entry: DockEntry) {
        pins.removeAll { $0.path == entry.id }
        savePins()
    }

    func pinIndex(of id: String) -> Int? {
        pins.firstIndex { $0.path == id }
    }

    /// Réorganisation pendant le glisser : l'icône prend la place de la cible.
    func movePin(_ id: String, to targetID: String) {
        guard id != targetID,
              let from = pinIndex(of: id),
              let to = pinIndex(of: targetID) else { return }
        let pin = pins.remove(at: from)
        pins.insert(pin, at: to)
        savePins()
    }

    /// Reprend les apps du Dock macOS (com.apple.dock, clé persistent-apps).
    func importSystemDock() {
        let value = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
        guard let items = value as? [[String: Any]] else { return }
        var urls: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for item in items {
            guard let tile = item["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let raw = file["_CFURLString"] as? String else { continue }
            let url: URL? = raw.hasPrefix("file://") ? URL(string: raw) : URL(fileURLWithPath: raw)
            if let url, url.pathExtension == "app" { urls.append(url) }
        }
        var seen = Set<String>()
        pins = urls.compactMap { url in
            let path = Self.key(url)
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { return nil }
            seen.insert(path)
            return Pin(path: path)
        }
        savePins()
    }

    func runningApp(for entry: DockEntry) -> NSRunningApplication? {
        running.first { $0.bundleURL.map(Self.key) == entry.id }
    }

    // MARK: Persistance

    private func loadPins() {
        if let data = UserDefaults.standard.data(forKey: pinsKey),
           let saved = try? JSONDecoder().decode([Pin].self, from: data) {
            pins = saved
        } else {
            importSystemDock()
        }
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pins) {
            UserDefaults.standard.set(data, forKey: pinsKey)
        }
    }

    // MARK: Apps ouvertes

    private func refreshRunning() {
        running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil
        }
        frontmostPath = NSWorkspace.shared.frontmostApplication?.bundleURL.map(Self.key)
        let runningPaths = Set(running.compactMap { $0.bundleURL.map(Self.key) })
        launching.subtract(runningPaths)
    }

    private func observeWorkspace() {
        // une icône a changé (site ou app web) : redessiner le Dock
        let iconToken = NotificationCenter.default.addObserver(forName: .buzzIconsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        observers.append(iconToken)
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
            observers.append(token)
        }
    }
}

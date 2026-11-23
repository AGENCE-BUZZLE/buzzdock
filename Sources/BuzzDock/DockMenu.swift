import AppKit
import ApplicationServices

// MARK: Fenêtres des apps (API d'Accessibilité)

/// Liste et ramène les fenêtres d'une app. Demande l'autorisation « Accessibilité » une fois.
@MainActor
enum WindowService {
    struct Window {
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
        let isMain: Bool
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func windows(of app: NSRunningApplication) -> [Window] {
        guard isTrusted else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let list = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.compactMap { window in
            guard (attribute(window, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String) else { return nil }
            let title = (attribute(window, kAXTitleAttribute) as? String) ?? ""
            return Window(
                element: window,
                title: title.isEmpty ? "Sans titre" : title,
                isMinimized: (attribute(window, kAXMinimizedAttribute) as? Bool) ?? false,
                isMain: (attribute(window, kAXMainAttribute) as? Bool) ?? false
            )
        }
    }

    /// Ramène une fenêtre au premier plan (la sort du Dock si elle était réduite).
    static func focus(_ window: Window, of app: NSRunningApplication) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        activate(app)
    }

    static func activate(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// « Nouvelle fenêtre » : l'élément de menu de l'app s'il existe, sinon ⌘N.
    static func newWindow(for app: NSRunningApplication) {
        activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !pressMenuItem(of: app, startingWith: ["Nouvelle fenêtre", "New Window"]) {
                sendCommandN(to: app)
            }
        }
    }

    /// Résultats mis en cache par app (lire les menus par l'Accessibilité coûte quelques millisecondes)
    private static var menuItemCache: [String: Bool] = [:]

    static func hasMenuItem(of app: NSRunningApplication, startingWith titles: [String]) -> Bool {
        let key = (app.bundleIdentifier ?? "\(app.processIdentifier)") + titles.joined()
        if let cached = menuItemCache[key] { return cached }
        let found = findMenuItem(of: app, startingWith: titles) != nil
        menuItemCache[key] = found
        return found
    }

    private static func findMenuItem(of app: NSRunningApplication, startingWith titles: [String]) -> AXUIElement? {
        guard isTrusted else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(element, kAXMenuBarAttribute),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return nil }
        let bar = menuBar as! AXUIElement
        for barItem in (attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for menu in (attribute(barItem, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    let title = (attribute(item, kAXTitleAttribute) as? String) ?? ""
                    if titles.contains(where: { title.hasPrefix($0) }) { return item }
                }
            }
        }
        return nil
    }

    static func pressMenuItem(of app: NSRunningApplication, startingWith titles: [String]) -> Bool {
        guard isTrusted else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(element, kAXMenuBarAttribute),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return false }
        let bar = menuBar as! AXUIElement
        let barItems = (attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for barItem in barItems {
            let menus = (attribute(barItem, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for menu in menus {
                let items = (attribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                for item in items {
                    let title = (attribute(item, kAXTitleAttribute) as? String) ?? ""
                    if titles.contains(where: { title.hasPrefix($0) }) {
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                }
            }
        }
        return false
    }

    /// Fenêtre « Ajouter au Dock » de Safari : met le nom voulu puis appuie sur « Ajouter ».
    static func confirmAddToDock(of app: NSRunningApplication, name: String) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        // la feuille d'abord, sinon les fenêtres elles-mêmes (selon la version de Safari)
        let sheets = windows.flatMap { descendants(of: $0, depth: 2) }.filter { role($0) == "AXSheet" }
        for container in sheets + windows {
            let all = descendants(of: container, depth: 6)
            guard let button = all.first(where: { role($0) == (kAXButtonRole as String) && ["Ajouter", "Add"].contains(title($0)) }) else { continue }
            if let field = all.first(where: { role($0) == (kAXTextFieldRole as String) }) {
                AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, name as CFTypeRef)
            }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return
        }
    }

    private static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private static func title(_ element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute) as? String
    }

    private static func descendants(of element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return children + children.flatMap { descendants(of: $0, depth: depth - 1) }
    }

    private static func sendCommandN(to app: NSRunningApplication) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyN: CGKeyCode = 45
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(app.processIdentifier)
        }
    }

    /// « Afficher toutes les fenêtres » (Exposé de l'app, comme le Dock d'Apple).
    static func showAllWindows(of app: NSRunningApplication) {
        activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
            process.arguments = ["2"]
            try? process.run()
        }
    }
}

// MARK: Pastilles de notification (lues dans le Dock d'Apple, masqué mais toujours là)

enum DockBadges {
    /// chemin de l'app → texte de la pastille (« 3 », « • »…) ; appelable hors du fil principal
    static func read() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        var lists: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &lists) == .success,
              let children = lists as? [AXUIElement] else { return [:] }
        for list in children {
            var items: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success,
                  let elements = items as? [AXUIElement] else { continue }
            for item in elements {
                var label: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &label) == .success,
                      let text = label as? String, !text.isEmpty else { continue }
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url) == .success,
                   let appURL = (url as? URL) ?? (url as? NSURL).map({ $0 as URL }) {
                    result[DockStore.key(appURL)] = text
                }
            }
        }
        return result
    }
}

// MARK: Ouverture à la connexion (éléments de connexion de macOS)

/// Lecture et modification des éléments de connexion par AppleScript (System Events),
/// toujours en arrière-plan. Le menu lit la dernière liste connue.
@MainActor
final class LoginItems {
    static let shared = LoginItems()
    private(set) var names = Set<String>()
    private let queue = DispatchQueue(label: "fr.buzzle.buzzdock.loginitems", qos: .utility)

    private init() { refresh() }

    func contains(_ url: URL) -> Bool {
        names.contains(url.deletingPathExtension().lastPathComponent)
    }

    func refresh() {
        queue.async {
            let output = Self.osascript("tell application \"System Events\" to get the name of every login item") ?? ""
            let list = Set(output.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            DispatchQueue.main.async { LoginItems.shared.names = list }
        }
    }

    func toggle(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let script = contains(url)
            ? "tell application \"System Events\" to delete login item \"\(name)\""
            : "tell application \"System Events\" to make login item at end with properties {path:\"\(url.path)\", hidden:false}"
        queue.async {
            _ = Self.osascript(script)
            DispatchQueue.main.async { LoginItems.shared.refresh() }
        }
    }

    nonisolated private static func osascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Menu d'une app (appui long ou clic droit), comme le Dock d'Apple

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.state = state
    }

    required init(coder: NSCoder) {
        fatalError("non utilisé")
    }

    @objc private func run() { handler() }
}

/// Emprise des icônes d'apps au repos, pour savoir quelle icône reçoit un clic droit.
@MainActor
final class DockHitRegistry {
    static let shared = DockHitRegistry()
    var slots: [(span: ClosedRange<CGFloat>, slot: BarSlot)] = []

    func update(centers: [CGFloat], slots: [BarSlot], halfWidth: CGFloat) {
        self.slots = zip(centers, slots).map { (span: ($0 - halfWidth)...($0 + halfWidth), slot: $1) }
    }

    /// L'app sous la souris (un raccourci web garde son menu SwiftUI)
    func entry(at x: CGFloat) -> DockEntry? {
        guard let slot = slots.first(where: { $0.span.contains(x) })?.slot, case .app(let entry) = slot else { return nil }
        return entry
    }
}

@MainActor
enum DockMenu {
    static func show(for entry: DockEntry, store: DockStore) {
        let menu = build(for: entry, store: store)
        store.isInteracting = true
        // au-dessus de l'icône, comme le menu du Dock d'Apple
        menu.popUp(positioning: nil, at: NSPoint(x: NSEvent.mouseLocation.x - 20, y: DockPopup.barTop + 6), in: nil)
        store.isInteracting = false
    }

    static func build(for entry: DockEntry, store: DockStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let app = store.runningApp(for: entry)

        // Fenêtres ouvertes
        if let app {
            if WindowService.isTrusted {
                let windows = WindowService.windows(of: app)
                for window in windows {
                    let title = window.isMinimized ? "◆ \(window.title)" : window.title
                    menu.addItem(ClosureMenuItem(title, state: window.isMain ? .on : .off) {
                        WindowService.focus(window, of: app)
                    })
                }
                if !windows.isEmpty { menu.addItem(.separator()) }
            } else {
                menu.addItem(ClosureMenuItem("Autoriser l'accès aux fenêtres…") {
                    WindowService.requestTrust()
                })
                menu.addItem(.separator())
            }
            // seulement si l'app a vraiment « Nouvelle fenêtre » dans ses menus (pas de ⌘N à l'aveugle)
            if WindowService.hasMenuItem(of: app, startingWith: ["Nouvelle fenêtre", "New Window"]) {
                menu.addItem(ClosureMenuItem("Nouvelle fenêtre") { WindowService.newWindow(for: app) })
                menu.addItem(.separator())
            }
        }

        // Options
        let options = NSMenu()
        options.autoenablesItems = false
        let folders = store.folders
        let inFolders = folders.filter { store.contains(entry.url, in: $0.id) }
        let addMenu = NSMenu()
        for folder in folders where !inFolders.contains(where: { $0.id == folder.id }) {
            addMenu.addItem(ClosureMenuItem(folder.name) { store.add(entry.url, to: folder.id) })
        }
        if !addMenu.items.isEmpty { addMenu.addItem(.separator()) }
        addMenu.addItem(ClosureMenuItem("Nouveau dossier") { store.createFolder(with: [entry.url]) })
        let onBar = store.isOnBar(entry.url)
        options.addItem(ClosureMenuItem("Garder dans le Dock", state: onBar ? .on : .off) {
            onBar ? store.removeFromBar(entry.id) : store.keepOnBar(entry.url)
        })
        let addItem = NSMenuItem(title: "Ajouter au dossier", action: nil, keyEquivalent: "")
        addItem.submenu = addMenu
        options.addItem(addItem)
        for folder in inFolders {
            options.addItem(ClosureMenuItem("Retirer de « \(folder.name) »") { store.remove(entry.url, from: folder.id) })
        }
        options.addItem(ClosureMenuItem("Ouvrir à la connexion", state: LoginItems.shared.contains(entry.url) ? .on : .off) {
            LoginItems.shared.toggle(entry.url)
        })
        options.addItem(ClosureMenuItem("Afficher dans le Finder") { store.revealInFinder(entry) })
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)

        // app fermée : Options puis Ouvrir, comme le Dock d'Apple
        if app == nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Ouvrir") { store.open(entry) })
        }

        if let app {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Afficher toutes les fenêtres") { WindowService.showAllWindows(of: app) })
            menu.addItem(.separator())
            if app.isHidden {
                menu.addItem(ClosureMenuItem("Afficher") { app.unhide() })
            } else {
                menu.addItem(ClosureMenuItem("Masquer") { app.hide() })
            }
            menu.addItem(ClosureMenuItem("Quitter") { app.terminate() })
            // ⌥ maintenue : « Forcer à quitter », comme le Dock d'Apple
            let force = ClosureMenuItem("Forcer à quitter") { app.forceTerminate() }
            force.isAlternate = true
            force.keyEquivalentModifierMask = .option
            menu.addItem(force)
        }
        return menu
    }
}

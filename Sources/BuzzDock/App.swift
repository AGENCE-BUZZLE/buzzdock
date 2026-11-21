import SwiftUI
import AppKit
import Combine

@main
struct BuzzDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("BuzzDock", systemImage: "dock.rectangle") {
            MenuBarContent(appDelegate: appDelegate)
        }
    }
}

struct MenuBarContent: View {
    let appDelegate: AppDelegate

    var body: some View {
        Button("Ouvrir le lanceur (⌃⌥ Espace)") { appDelegate.launcher.toggle() }
        Button("Réglages…") { appDelegate.showSettings() }
        Divider()
        Button("Importer les apps du Dock macOS") { appDelegate.store.importSystemDock() }
        Button("Restaurer le Dock macOS") {
            appDelegate.settings.hideSystemDock = false
        }
        Divider()
        Button("Quitter BuzzDock") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: DockSettings
    let store: DockStore
    let launcher: LauncherController
    private var dock: DockController?
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let settings = DockSettings()
        let store = DockStore(settings: settings)
        self.settings = settings
        self.store = store
        self.launcher = LauncherController(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Masquer le Dock d'Apple avant tout le reste
        if settings.hideSystemDock { SystemDockService.hide() }

        // apps web déjà fabriquées : nouvelle coquille si BuzzDock a été mis à jour
        WebAppMaker.refreshShells()
        WebAppMaker.refreshOldIcons()

        let dock = DockController(store: store, settings: settings, launcher: launcher)
        dock.start()
        self.dock = dock

        // ⌃⌥ Espace ouvre le lanceur plein écran
        hotKey = HotKey(keyCode: HotKey.spaceKeyCode, modifiers: HotKey.controlOption) { [weak self] in
            self?.launcher.toggle()
        }

        NotificationCenter.default.publisher(for: .buzzOpenSettings)
            .sink { [weak self] _ in self?.showSettings() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .buzzOpenLauncher)
            .sink { [weak self] _ in self?.launcher.toggle() }
            .store(in: &cancellables)

        settings.$hideSystemDock
            .dropFirst()
            .removeDuplicates()
            .sink { hide in hide ? SystemDockService.hide() : SystemDockService.restore() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Le Dock macOS revient toujours quand BuzzDock s'arrête
        SystemDockService.restore()
    }

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(settings)
                    .environmentObject(store)
            )
            let window = NSWindow(contentViewController: host)
            window.title = "Personnaliser BuzzDock"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

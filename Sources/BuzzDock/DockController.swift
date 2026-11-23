import AppKit
import SwiftUI
import Combine

/// Position de la souris au dessus du Dock, en coordonnées de la fenêtre.
@MainActor
final class HoverModel: ObservableObject {
    @Published var mouseX: CGFloat?
}

/// Fenêtre du Dock : sans bord, transparente, au niveau du Dock système,
/// présente sur tous les bureaux et par dessus les apps en plein écran.
final class DockPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
    }

    // Peut prendre le focus (menus, fenêtres surgissantes) sans activer l'app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Le premier clic agit tout de suite, même si la fenêtre n'a pas le focus.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DockController {
    let panel = DockPanel()
    let hover = HoverModel()
    private var host: NSView = NSView()
    private let store: DockStore
    private let settings: DockSettings
    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var isRevealed = true
    private var hideTask: DispatchWorkItem?

    init(store: DockStore, settings: DockSettings, launcher: LauncherController) {
        self.store = store
        self.settings = settings
        let root = DockRootView(onOpenLauncher: { launcher.toggle() })
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(hover)
        let host = FirstMouseHostingView(rootView: root)
        // La fenêtre ne suit jamais la taille du contenu : c'est le contrôleur qui la fixe
        host.sizingOptions = []
        panel.contentView = host
        self.host = host
    }

    private var widgetMode: Bool { settings.style == .widgets }

    /// Taille de la fenêtre du Dock à widgets : barre au repos + place pour la loupe.
    /// Taille de la barre au repos, recalculée seulement quand le Dock change (pas à chaque mouvement de souris)
    private var restingCache: CGSize = .zero

    private var widgetSize: CGSize {
        let resting = WidgetLayout.restingSize(settings: settings, store: store)
        restingCache = resting
        let growth = WidgetLayout.magnificationGrowth(settings: settings)
        return CGSize(width: ceil(resting.width + growth.width), height: resting.height)
    }

    private var barHalfWidth: CGFloat {
        widgetMode
            ? restingCache.width / 2 - widgetSideMargin
            : metrics.barWidth / 2
    }

    private var screen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }

    private var metrics: DockMetrics {
        DockMetrics(slots: store.slots, settings: settings)
    }

    func start() {
        isRevealed = !settings.autoHide
        // Laisse passer les clics partout, sauf au dessus de la barre (voir handleMouse)
        panel.ignoresMouseEvents = true
        layout(animated: false)
        panel.orderFrontRegardless()

        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.layout(animated: true) }
            .store(in: &cancellables)

        settings.$autoHide
            .dropFirst()
            .sink { [weak self] autoHide in
                guard let self else { return }
                self.isRevealed = !autoHide
                self.layout(animated: true)
            }
            .store(in: &cancellables)

        // nouvelle notification : le Dock masqué ressort 3 s pour montrer l'icône qui rebondit
        NotificationCenter.default.publisher(for: .buzzAttention)
            .sink { [weak self] _ in
                guard let self, self.settings.autoHide, !self.isRevealed else { return }
                self.reveal()
                self.hideTask?.cancel()
                let task = DispatchWorkItem { [weak self] in
                    guard let self, self.hover.mouseX == nil, !self.store.isInteracting else { return }
                    self.isRevealed = false
                    self.layout(animated: true)
                }
                self.hideTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: task)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout(animated: false) }
            .store(in: &cancellables)

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }) {
            monitors.append(global)
        }
        // clic dans une autre app : les fenêtres surgissantes du Dock se ferment
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .buzzClosePopovers, object: nil)
            }
        }) {
            monitors.append(outside)
        }

        // Clic droit (ou ⌃ clic) sur une app : le menu du Dock d'Apple
        if let menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel, self.settings.style == .widgets else { return event }
                if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
                let x = NSEvent.mouseLocation.x - self.panel.frame.minX
                guard let entry = DockHitRegistry.shared.entry(at: x) else { return event }
                DockMenu.show(for: entry, store: self.store)
                return nil
            }
        }) {
            monitors.append(menuMonitor)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse() }
            return event
        }) {
            monitors.append(local)
        }
    }

    // MARK: Position

    private func frame(revealed: Bool) -> NSRect {
        let m = metrics
        let size = widgetMode ? widgetSize : CGSize(width: m.panelWidth, height: m.panelHeight)
        let screenFrame = screen.frame
        let x = (screenFrame.midX - size.width / 2).rounded()
        let y = revealed ? screenFrame.minY : screenFrame.minY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func layout(animated: Bool) {
        let target = frame(revealed: isRevealed || !settings.autoHide)
        // haut de la barre visible : les fenêtres surgissantes s'ouvrent juste au-dessus
        let k = settings.tileSize / 64
        DockPopup.barTop = frame(revealed: true).minY
            + (widgetMode ? 64 * k + 16 * k + 4 : metrics.barHeight + metrics.bottomGap)
        guard target != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                // « Réduire les animations » : pas de glissement
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Zone de la barre en coordonnées écran. Au repos : la barre seule ;
    /// pendant le survol : la barre élargie par l'effet loupe.
    private var interactiveRect: NSRect {
        let m = metrics
        let f = panel.frame
        if widgetMode {
            let k = settings.tileSize / 64
            let resting = restingCache
            let growth = WidgetLayout.magnificationGrowth(settings: settings)
            let hovering = hover.mouseX != nil
            let width = resting.width - widgetSideMargin * 2 + (hovering ? growth.width : 0)
            let height = 64 * k + 16 * k + 4 + (hovering ? growth.rise : 0)
            return NSRect(x: f.midX - width / 2, y: f.minY, width: width, height: height)
        }
        let hovering = hover.mouseX != nil
        let width = m.barWidth + (hovering ? m.base * (m.magnification - 1) * 2.4 : 0)
        let iconHeight = hovering ? m.base * m.magnification : m.base
        let height = iconHeight + m.indicatorHeight + m.padding * 2 + m.bottomGap
        return NSRect(x: f.midX - width / 2, y: f.minY, width: width, height: height)
    }

    // MARK: Souris

    private func handleMouse() {
        let point = NSEvent.mouseLocation
        let screenFrame = screen.frame

        // Glisser annulé hors du Dock : on oublie l'icône en cours de déplacement
        if store.draggingID != nil, NSEvent.pressedMouseButtons == 0 {
            store.draggingID = nil
        }

        if settings.autoHide {
            let nearBottomEdge = point.y <= screenFrame.minY + 2
                && abs(point.x - screenFrame.midX) <= barHalfWidth + 20
            if !isRevealed && nearBottomEdge {
                reveal()
            } else if isRevealed {
                if interactiveRect.contains(point) || store.isInteracting {
                    hideTask?.cancel()
                    hideTask = nil
                } else if hideTask == nil {
                    scheduleHide()
                }
            }
        }

        let visible = isRevealed || !settings.autoHide
        let inside = visible && interactiveRect.contains(point)
        if inside {
            hover.mouseX = point.x - panel.frame.minX
        } else if hover.mouseX != nil {
            hover.mouseX = nil
        }

        // La fenêtre du Dock ne capte la souris qu'au dessus de la barre :
        // partout ailleurs, les clics passent aux fenêtres en dessous.
        let ignore = !(inside || store.isInteracting || store.draggingID != nil)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    private func reveal() {
        hideTask?.cancel()
        hideTask = nil
        isRevealed = true
        layout(animated: true)
    }

    private func scheduleHide() {
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideTask = nil
            guard self.settings.autoHide, !self.store.isInteracting else { return }
            NotificationCenter.default.post(name: .buzzClosePopovers, object: nil)
            DockPopup.shared.close()
            self.isRevealed = false
            self.hover.mouseX = nil
            self.layout(animated: true)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }
}

import SwiftUI
import AppKit

/// Fenêtre surgissante du Dock (dossier ouvert, galerie, Téléchargements), placée par BuzzDock lui-même :
/// toujours juste au-dessus de la barre, centrée sur l'icône, et qui grandit vers le haut.
/// (Les popovers SwiftUI se plaçaient mal depuis une barre au niveau du Dock : coupés, par-dessus la barre.)
@MainActor
final class DockPopup {
    static let shared = DockPopup()

    /// Haut de la barre du Dock, en coordonnées écran (mis à jour par DockController)
    static var barTop: CGFloat = 100

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }   // pour taper dans les champs (nom du dossier, recherche)
    }

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?
    private var ownerID: String?
    private var observer: NSObjectProtocol?

    var isOpen: Bool { panel != nil }

    /// Ouvre la fenêtre ; un 2e clic sur la même icône la referme.
    func toggle<V: View>(id: String, anchorX: CGFloat, onClose: @escaping () -> Void, @ViewBuilder content: () -> V) {
        if ownerID == id, panel != nil {
            close()
            return
        }
        show(id: id, anchorX: anchorX, onClose: onClose, content: content)
    }

    func show<V: View>(id: String, anchorX: CGFloat, onClose: @escaping () -> Void, @ViewBuilder content: () -> V) {
        close()
        ownerID = id
        self.onClose = onClose

        let body = content()
        let root = PopupChrome { body }.fixedSize()
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]   // la fenêtre suit la taille du contenu

        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let size = controller.view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorX, y: Self.barTop)) } ?? NSScreen.main
        var x = anchorX - size.width / 2
        if let frame = screen?.frame { x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8) }
        panel.setFrame(NSRect(x: x, y: Self.barTop + 10, width: size.width, height: size.height), display: true)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        // garder la fenêtre ancrée en bas (au-dessus du Dock) quand son contenu change de taille
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let panel = DockPopup.shared.panel else { return }
                if abs(panel.frame.minY - (DockPopup.barTop + 10)) > 1 {
                    var frame = panel.frame
                    frame.origin.y = DockPopup.barTop + 10
                    panel.setFrame(frame, display: true)
                }
                panel.invalidateShadow()   // l'ombre suit la nouvelle taille
            }
        }

        // fermeture : clic dans une autre app, clic hors de la fenêtre, Échap, Dock qui se range
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { DockPopup.shared.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { event in
            MainActor.assumeIsolated {
                guard let panel = DockPopup.shared.panel else { return }
                if event.type == .keyDown, event.keyCode == 53 { DockPopup.shared.close(); return }
                // un clic sur le Dock lui-même laisse l'icône gérer (ouvrir/fermer)
                if event.type == .leftMouseDown, event.window !== panel, !(event.window is DockPanel) {
                    DockPopup.shared.close()
                }
            }
            return event
        }) { monitors.append(local) }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let panel {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        panel = nil
        ownerID = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

/// Habillage commun des fenêtres surgissantes : verre (macOS 26) ou matériau, et apparition
/// « matérialisée » depuis le Dock (échelle + fondu, ressort sans rebond ; fondu seul si Réduire les animations).
struct PopupChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        background(content(), shape)
            .clipShape(shape)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.92, anchor: .bottom)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)) {
                    appeared = true
                }
            }
    }

    @ViewBuilder
    private func background(_ view: Content, _ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            view.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                view.glassEffect(.regular, in: shape)
            } else {
                view.background(.regularMaterial, in: shape)
            }
            #else
            view.background(.regularMaterial, in: shape)
            #endif
        }
    }
}

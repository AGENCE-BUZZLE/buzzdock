import AppKit
import WebKit
import UserNotifications

// Coquille d'app web générée par BuzzDock : une fenêtre WebKit sur l'adresse du site
// (clé BuzzWebAppURL de l'Info.plist). Chaque app web garde ses propres cookies.

// Remplace les notifications et la pastille du site par celles de macOS
// (WebKit intégré ne sait pas les afficher tout seul)
let notificationBridge = """
(function () {
  const post = (m) => { try { window.webkit.messageHandlers.buzz.postMessage(m); } catch (e) {} };
  class BuzzNotification extends EventTarget {
    constructor(title, options = {}) {
      super();
      this.title = title; this.body = options.body || ''; this.tag = options.tag || '';
      this.onclick = null; this.onclose = null; this.onshow = null; this.onerror = null;
      post({ type: 'notify', title: String(title || ''), body: String(this.body) });
    }
    close() {}
    static get permission() { return 'granted'; }
    static requestPermission(callback) { if (callback) callback('granted'); return Promise.resolve('granted'); }
  }
  window.Notification = BuzzNotification;
  if (window.ServiceWorkerRegistration) {
    ServiceWorkerRegistration.prototype.showNotification = function (title, options = {}) {
      post({ type: 'notify', title: String(title || ''), body: String(options.body || '') });
      return Promise.resolve();
    };
  }
  navigator.setAppBadge = (n) => { post({ type: 'badge', count: n == null ? -1 : Number(n) }); return Promise.resolve(); };
  navigator.clearAppBadge = () => { post({ type: 'badge', count: 0 }); return Promise.resolve(); };
  if (navigator.permissions && navigator.permissions.query) {
    const query = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = (d) => (d && d.name === 'notifications')
      ? Promise.resolve({ state: 'granted', onchange: null }) : query(d);
  }
})();
"""

// Ajouté à l'identifiant WebKit par défaut : les sites voient exactement Safari
let safariApplicationName = "Version/26.0 Safari/605.1.15"

final class WebAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private var windows: [NSWindow] = []
    private var lastBadgeCount = 0
    private var lastPageNotification = Date.distantPast
    private var titleObservers: [NSKeyValueObservation] = []

    private let startURL: URL = {
        let text = Bundle.main.object(forInfoDictionaryKey: "BuzzWebAppURL") as? String ?? "https://www.apple.com"
        return URL(string: text) ?? URL(string: "https://www.apple.com")!
    }()

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App web"
    }

    private lazy var configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = safariApplicationName
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(WKUserScript(
            source: notificationBridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(self, name: "buzz")
        return config
    }()

    private var currentWebView: WKWebView? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView as? WKWebView
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // demande l'autorisation des notifications dès l'ouverture (macOS l'affiche une seule fois)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        buildMenu()
        openWindow(url: startURL, isMain: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(url: startURL, isMain: true) }
        return true
    }

    // Fermer la dernière fenêtre quitte l'app : rien ne reste en mémoire
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @discardableResult
    private func openWindow(url: URL?, isMain: Bool, configuration custom: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: custom ?? configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.title = appName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .preferred
        if isMain && windows.isEmpty {
            if !window.setFrameUsingName("main") { window.center() }
            window.setFrameAutosaveName("main")
        } else if let last = windows.last {
            window.setFrameOrigin(NSPoint(x: last.frame.minX + 24, y: last.frame.minY - 24))
        } else {
            window.center()
        }
        windows.append(window)
        titleObservers.append(webView.observe(\.title, options: [.new]) { [weak window] view, _ in
            let title = view.title ?? ""
            DispatchQueue.main.async {
                window?.title = title.isEmpty ? self.appName : title
                self.updateBadge(fromTitle: title)
            }
        })
        window.makeKeyAndOrderFront(nil)
        if let url { webView.load(URLRequest(url: url)) }
        return webView
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            NSWorkspace.shared.open(url)   // mailto:, tel:, apps…
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    // Le moteur du site a planté (mémoire…) : on recharge au lieu d'afficher une page blanche
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // téléchargement seulement pour une page principale que WebKit ne sait pas afficher
        // (sinon des réponses de connexion étaient prises pour des fichiers et coupaient le chargement)
        let isAttachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        if navigationResponse.isForMainFrame && (isAttachment || !navigationResponse.canShowMIMEType) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = folder.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        completionHandler(target)
    }

    // Fenêtres ouvertes par le site (connexion Facebook/Google, partage…) : toujours dans l'app,
    // sinon la session de connexion ne revient jamais. « Ouvrir dans le navigateur » reste au menu (⌘⇧O).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openWindow(url: nil, isMain: false, configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.close()
    }

    // MARK: Boîtes de dialogue du site

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    // MARK: Notifications et pastille

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "notify":
            lastPageNotification = Date()
            notify(title: (body["title"] as? String) ?? appName, body: (body["body"] as? String) ?? "")
        case "badge":
            let count = (body["count"] as? Int) ?? Int((body["count"] as? Double) ?? 0)
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : (count < 0 ? "•" : nil)
        default:
            break
        }
    }

    /// « (3) Instagram » dans le titre de la page = 3 messages non lus
    private func updateBadge(fromTitle title: String) {
        guard title.hasPrefix("("), let close = title.firstIndex(of: ")") else {
            if NSApp.dockTile.badgeLabel != nil, !(title.hasPrefix("(")) { NSApp.dockTile.badgeLabel = nil }
            lastBadgeCount = 0
            return
        }
        let inside = title[title.index(after: title.startIndex)..<close]
        if let n = Int(inside.filter(\.isNumber)), n > 0 {
            NSApp.dockTile.badgeLabel = inside.contains("+") ? "\(n)+" : String(n)
            // nouveau message non lu : notification, même si le site n'en envoie pas lui-même
            // (X, Instagram… passent par un service en arrière-plan que WebKit intégré n'exécute pas)
            if n > lastBadgeCount, Date().timeIntervalSince(lastPageNotification) > 5 {
                let extra = n - lastBadgeCount
                notify(title: appName, body: extra == 1 ? "Nouvelle notification" : "\(extra) nouvelles notifications")
            }
            lastBadgeCount = n
        }
    }

    private func notify(title: String, body: String) {
        // comme Safari : pas de bannière quand on est déjà dans l'app
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? self.appName : title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Menus

    @objc private func newWindow() { openWindow(url: startURL, isMain: false) }
    @objc private func reload() { currentWebView?.reload() }
    @objc private func goBack() { currentWebView?.goBack() }
    @objc private func goForward() { currentWebView?.goForward() }
    @objc private func goHome() { currentWebView?.load(URLRequest(url: startURL)) }
    @objc private func zoomIn() { currentWebView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc private func zoomOut() { currentWebView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }
    @objc private func zoomReset() { currentWebView?.pageZoom = 1 }
    @objc private func openInBrowser() {
        if let url = currentWebView?.url { NSWorkspace.shared.open(url) }
    }
    @objc private func copyAddress() {
        guard let url = currentWebView?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        return item
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("Masquer \(appName)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Masquer les autres", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quitter \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        let fileMenu = NSMenu(title: "Fichier")
        fileMenu.addItem(item("Nouvelle fenêtre", #selector(newWindow), "n", target: self))
        fileMenu.addItem(item("Fermer la fenêtre", #selector(NSWindow.performClose(_:)), "w"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Ouvrir dans le navigateur", #selector(openInBrowser), "o", [.command, .shift], target: self))
        fileMenu.addItem(item("Copier l'adresse", #selector(copyAddress), "c", [.command, .shift], target: self))

        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(item("Annuler", Selector(("undo:")), "z"))
        editMenu.addItem(item("Rétablir", Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Couper", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copier", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Coller", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Tout sélectionner", #selector(NSText.selectAll(_:)), "a"))

        let viewMenu = NSMenu(title: "Présentation")
        viewMenu.addItem(item("Recharger", #selector(reload), "r", target: self))
        viewMenu.addItem(item("Accueil", #selector(goHome), "h", [.command, .shift], target: self))
        viewMenu.addItem(item("Précédent", #selector(goBack), "[", target: self))
        viewMenu.addItem(item("Suivant", #selector(goForward), "]", target: self))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Zoom avant", #selector(zoomIn), "+", target: self))
        viewMenu.addItem(item("Zoom arrière", #selector(zoomOut), "-", target: self))
        viewMenu.addItem(item("Taille réelle", #selector(zoomReset), "0", target: self))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Plein écran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(item("Réduire", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Réduire/agrandir", #selector(NSWindow.performZoom(_:)), ""))
        NSApp.windowsMenu = windowMenu

        for (title, menu) in [(appName, appMenu), ("Fichier", fileMenu), ("Édition", editMenu), ("Présentation", viewMenu), ("Fenêtre", windowMenu)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        NSApp.mainMenu = main
    }
}

let application = NSApplication.shared
let webAppDelegate = WebAppDelegate()
application.delegate = webAppDelegate
application.setActivationPolicy(.regular)
application.run()

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

extension Notification.Name {
    /// Une icône (site ou app web) a changé : le Dock se redessine
    static let buzzIconsChanged = Notification.Name("fr.buzzle.buzzdock.iconsChanged")
    /// Une app réclame l'attention (nouvelle notification)
    static let buzzAttention = Notification.Name("fr.buzzle.buzzdock.attention")
    /// Fermer les fenêtres surgissantes du Dock (clic ailleurs, Dock qui se range)
    static let buzzClosePopovers = Notification.Name("fr.buzzle.buzzdock.closePopovers")
}

// MARK: Modèle

/// Un raccourci web affiché comme une app (comme « Sur l'écran d'accueil » sur iPhone).
struct WebLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    /// Navigateur (identifiant d'app) ; nil = navigateur par défaut du Mac
    var browser: String?
    /// Ouvre le site dans sa propre fenêtre, sans onglets (navigateurs Chromium)
    var appWindow = false

    init(id: UUID = UUID(), name: String, url: String, browser: String? = Browsers.preferred, appWindow: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.browser = browser
        self.appWindow = appWindow
    }

    enum CodingKeys: String, CodingKey { case id, name, url, browser, appWindow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        appWindow = try c.decodeIfPresent(Bool.self, forKey: .appWindow) ?? false
    }

    /// Adresse complète (https:// ajouté si besoin)
    var resolvedURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }

    var host: String {
        (resolvedURL?.host ?? url).replacingOccurrences(of: "www.", with: "")
    }

    /// « www.instagram.com » → « Instagram »
    static func guessName(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let base = host.split(separator: ".").first.map(String.init) ?? host
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// Galerie d'apps web prêtes à ajouter
    static let catalog: [WebAppPreset] = [
        WebAppPreset(name: "Instagram", url: "https://www.instagram.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "TikTok", url: "https://www.tiktok.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "LinkedIn", url: "https://www.linkedin.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "X", url: "https://x.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "Facebook", url: "https://www.facebook.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "YouTube", url: "https://www.youtube.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "Threads", url: "https://www.threads.net", category: "Réseaux sociaux"),
        WebAppPreset(name: "Pinterest", url: "https://www.pinterest.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "Snapchat", url: "https://web.snapchat.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "Reddit", url: "https://www.reddit.com", category: "Réseaux sociaux"),
        WebAppPreset(name: "WhatsApp", url: "https://web.whatsapp.com", category: "Messagerie"),
        WebAppPreset(name: "Messenger", url: "https://www.messenger.com", category: "Messagerie"),
        WebAppPreset(name: "Gmail", url: "https://mail.google.com", category: "Messagerie"),
        WebAppPreset(name: "Outlook", url: "https://outlook.live.com", category: "Messagerie"),
        WebAppPreset(name: "Slack", url: "https://app.slack.com", category: "Messagerie"),
        WebAppPreset(name: "Google Drive", url: "https://drive.google.com", category: "Productivité"),
        WebAppPreset(name: "Google Agenda", url: "https://calendar.google.com", category: "Productivité"),
        WebAppPreset(name: "Google Photos", url: "https://photos.google.com", category: "Productivité"),
        WebAppPreset(name: "Notion", url: "https://www.notion.so", category: "Productivité"),
        WebAppPreset(name: "Canva", url: "https://www.canva.com", category: "Productivité"),
        WebAppPreset(name: "ChatGPT", url: "https://chatgpt.com", category: "IA"),
        WebAppPreset(name: "Claude", url: "https://claude.ai", category: "IA"),
        WebAppPreset(name: "Netflix", url: "https://www.netflix.com", category: "Divertissement"),
        WebAppPreset(name: "Spotify", url: "https://open.spotify.com", category: "Divertissement"),
        WebAppPreset(name: "YouTube Music", url: "https://music.youtube.com", category: "Divertissement"),
    ]

    static let socialPresets: [WebLink] = [
        WebLink(name: "Instagram", url: "https://www.instagram.com"),
        WebLink(name: "TikTok", url: "https://www.tiktok.com"),
        WebLink(name: "LinkedIn", url: "https://www.linkedin.com"),
        WebLink(name: "X", url: "https://x.com"),
        WebLink(name: "Facebook", url: "https://www.facebook.com"),
        WebLink(name: "YouTube", url: "https://www.youtube.com"),
        WebLink(name: "Threads", url: "https://www.threads.net"),
        WebLink(name: "WhatsApp", url: "https://web.whatsapp.com"),
    ]
}

/// Une app web de la galerie
struct WebAppPreset: Identifiable, Hashable {
    let name: String
    let url: String
    let category: String
    var id: String { url }
    /// Un nouveau raccourci à chaque ajout (identifiant neuf)
    var link: WebLink { WebLink(name: name, url: url) }
    var host: String { link.host }
}

// MARK: Navigateurs

enum Browsers {
    struct Browser: Hashable, Identifiable {
        let name: String
        let bundleID: String
        let supportsAppWindow: Bool
        var id: String { bundleID }
    }

    static let known: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", supportsAppWindow: true),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", supportsAppWindow: true),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", supportsAppWindow: false),
        Browser(name: "Dia", bundleID: "company.thebrowser.dia", supportsAppWindow: false),
        Browser(name: "Brave", bundleID: "com.brave.Browser", supportsAppWindow: true),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", supportsAppWindow: true),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", supportsAppWindow: false),
    ]

    static var installed: [Browser] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Safari par défaut
    static var preferred: String? { "com.apple.Safari" }

    /// Libellé de l'option « comme une app » selon le navigateur
    static func appModeLabel(_ bundleID: String?) -> String {
        "App web (vraie app avec l'icône du site, visible dans le Dock)"
    }

    /// L'option « app web » existe pour tous les raccourcis (BuzzDock fabrique l'app lui-même)
    static func supportsAppWindow(_ bundleID: String?) -> Bool { true }

    static func open(_ link: WebLink) {
        guard let url = link.resolvedURL else { return }
        if let bundleID = link.browser,
           let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            if link.appWindow && (known.first { $0.bundleID == bundleID }?.supportsAppWindow ?? false) && bundleID != "com.apple.Safari" {
                // Fenêtre d'app : « open -na <navigateur> --args --app=<adresse> »
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-na", browserURL.path, "--args", "--app=\(url.absoluteString)"]
                try? process.run()
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Apps web (fabriquées par BuzzDock)

/// Fabrique une vraie app pour un site : coquille WebKit (BuzzWebApp, livrée dans BuzzDock),
/// Info.plist avec l'adresse, icône du site. Rangée dans ~/Applications/BuzzDock Apps.
@MainActor
enum WebAppMaker {
    static let bundlePrefix = "fr.buzzle.webapp."

    static var appsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/BuzzDock Apps", isDirectory: true)
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "App web" : cleaned
    }

    /// App web déjà fabriquée pour ce raccourci (même nom)
    static func existingApp(for link: WebLink) -> URL? {
        let url = appsFolder.appendingPathComponent("\(safeName(link.name)).app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func isWebApp(_ url: URL) -> Bool {
        (Bundle(url: url)?.bundleIdentifier ?? "").hasPrefix(bundlePrefix)
    }

    static func make(_ link: WebLink, completion: @escaping (URL?) -> Void) {
        guard let address = link.resolvedURL,
              let shell = Bundle.main.url(forResource: "BuzzWebApp", withExtension: nil) else {
            completion(nil)
            return
        }
        // icône : celle du site si elle est déjà là, sinon on attend un peu qu'elle arrive
        let siteIcon = WebIconCache.shared.image(for: link)
        let icons = iconPNGs(site: siteIcon, letter: String(link.name.prefix(1)).uppercased())
        let name = safeName(link.name)
        let host = link.host.replacingOccurrences(of: ".", with: "-")
        let folder = appsFolder

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let app = folder.appendingPathComponent("\(name).app")
            let contents = app.appendingPathComponent("Contents")
            let macOS = contents.appendingPathComponent("MacOS")
            let resources = contents.appendingPathComponent("Resources")
            do {
                try? fm.removeItem(at: app)
                try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
                try fm.createDirectory(at: resources, withIntermediateDirectories: true)
                try fm.copyItem(at: shell, to: macOS.appendingPathComponent("BuzzWebApp"))

                let info: [String: Any] = [
                    "CFBundleExecutable": "BuzzWebApp",
                    "CFBundleIdentifier": "\(WebAppMaker.bundlePrefix)\(host)",
                    "CFBundleName": name,
                    "CFBundleDisplayName": name,
                    "CFBundlePackageType": "APPL",
                    "CFBundleIconFile": "AppIcon",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "CFBundleInfoDictionaryVersion": "6.0",
                    "LSMinimumSystemVersion": "14.0",
                    "NSHighResolutionCapable": true,
                    "NSPrincipalClass": "NSApplication",
                    "BuzzWebAppURL": address.absoluteString,
                    "NSCameraUsageDescription": "Le site peut utiliser la caméra (appels, stories).",
                    "NSMicrophoneUsageDescription": "Le site peut utiliser le micro (appels, messages vocaux).",
                ]
                let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                try plist.write(to: contents.appendingPathComponent("Info.plist"))

                // icône .icns via iconutil
                let iconset = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).iconset")
                try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
                for (file, data) in icons { try data.write(to: iconset.appendingPathComponent(file)) }
                WebAppMaker.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path])
                try? fm.removeItem(at: iconset)
                if siteIcon != nil { try? "4".write(to: resources.appendingPathComponent("icone.version"), atomically: true, encoding: .utf8) }

                if let shellData = try? Data(contentsOf: shell) {
                    let stamp = SHA256.hash(data: shellData).map { String(format: "%02x", $0) }.joined()
                    try? stamp.write(to: resources.appendingPathComponent("coquille.sha256"), atomically: true, encoding: .utf8)
                }
                WebAppMaker.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
                DispatchQueue.main.async { completion(app) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Une meilleure icône est arrivée pour un site : on refait l'icône des apps web de ce site.
    static func updateIcons(host: String, site: NSImage) {
        let folder = appsFolder
        guard let apps = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for app in apps where app.pathExtension == "app" {
            guard let address = Bundle(url: app)?.object(forInfoDictionaryKey: "BuzzWebAppURL") as? String,
                  let appHost = URL(string: address)?.host?.replacingOccurrences(of: "www.", with: ""),
                  appHost == host else { continue }
            let name = app.deletingPathExtension().lastPathComponent
            let icons = iconPNGs(site: site, letter: String(name.prefix(1)).uppercased())
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                let iconset = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).iconset")
                try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)
                for (file, data) in icons { try? data.write(to: iconset.appendingPathComponent(file)) }
                WebAppMaker.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", app.appendingPathComponent("Contents/Resources/AppIcon.icns").path])
                try? fm.removeItem(at: iconset)
                try? "4".write(to: app.appendingPathComponent("Contents/Resources/icone.version"), atomically: true, encoding: .utf8)
                WebAppMaker.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
                DispatchQueue.main.async {
                    IconCache.forget(app.path)
                    NotificationCenter.default.post(name: .buzzIconsChanged, object: nil)
                }
            }
        }
    }

    /// Apps web fabriquées avant les icônes officielles : on va chercher la bonne icône et on la refait.
    static func refreshOldIcons() {
        guard let apps = try? FileManager.default.contentsOfDirectory(at: appsFolder, includingPropertiesForKeys: nil) else { return }
        for app in apps where app.pathExtension == "app" {
            let marker = app.appendingPathComponent("Contents/Resources/icone.version")
            guard (try? String(contentsOf: marker, encoding: .utf8)) != "4",
                  let address = Bundle(url: app)?.object(forInfoDictionaryKey: "BuzzWebAppURL") as? String else { continue }
            let link = WebLink(name: app.deletingPathExtension().lastPathComponent, url: address)
            // déjà en cache : on refait l'icône tout de suite ; sinon le téléchargement s'en chargera
            if let image = WebIconCache.shared.image(for: link) {
                updateIcons(host: link.host, site: image)
            }
        }
    }

    /// Met à jour la coquille des apps web déjà fabriquées quand BuzzDock en livre une nouvelle
    /// (les connexions sont gardées : elles dépendent de l'identifiant de l'app, qui ne change pas).
    static func refreshShells() {
        guard let shell = Bundle.main.url(forResource: "BuzzWebApp", withExtension: nil) else { return }
        let folder = appsFolder
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let newData = try? Data(contentsOf: shell),
                  let apps = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            // empreinte de la coquille livrée (la signature modifie le binaire copié : on compare l'empreinte notée)
            let stamp = SHA256.hash(data: newData).map { String(format: "%02x", $0) }.joined()
            for app in apps where app.pathExtension == "app" {
                let binary = app.appendingPathComponent("Contents/MacOS/BuzzWebApp")
                let marker = app.appendingPathComponent("Contents/Resources/coquille.sha256")
                guard fm.fileExists(atPath: binary.path),
                      (try? String(contentsOf: marker, encoding: .utf8)) != stamp else { continue }
                try? fm.removeItem(at: binary)
                try? fm.copyItem(at: shell, to: binary)
                try? stamp.write(to: marker, atomically: true, encoding: .utf8)
                WebAppMaker.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            }
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Les tailles d'un .iconset : icône du site dans un carré arrondi, comme une app.
    static func iconPNGs(site: NSImage?, letter: String) -> [(String, Data)] {
        let specs: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        return specs.compactMap { file, size in render(site: site, letter: letter, size: size).map { (file, $0) } }
    }

    static func render(site: NSImage?, letter: String, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(size)
        let inset = s * 0.098
        let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSColor.white.setFill()
        path.fill()
        path.addClip()
        if let site {
            if WebIconCache.pixelWidth(site) >= 120 && !WebIconCache.isCutOut(site) {
                site.draw(in: body)
            } else {
                // logo détouré ou petit : centré avec de la marge, proportions gardées
                let box = body.insetBy(dx: body.width * 0.18, dy: body.width * 0.18)
                let ratio = site.size.width / max(site.size.height, 1)
                let w = ratio >= 1 ? box.width : box.height * ratio
                let h = ratio >= 1 ? box.width / ratio : box.height
                site.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            }
        } else {
            NSColor(white: 0.3, alpha: 1).setFill()
            body.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: s * 0.42, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: letter, attributes: attrs)
            let size = text.size()
            text.draw(at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: Icônes des sites

/// Récupère l'icône « écran d'accueil » du site (apple-touch-icon, celle qu'utilise l'iPhone),
/// sinon son favicon. Gardée sur le disque.
@MainActor
final class WebIconCache: ObservableObject {
    static let shared = WebIconCache()
    @Published private(set) var images: [String: NSImage] = [:]
    private var pending = Set<String>()
    /// Icônes trop petites déjà retentées pendant cette session
    private var upgraded = Set<String>()
    /// Versions sombres déjà calculées (nil = pas de fond blanc)
    private var darkCache: [String: NSImage?] = [:]

    func dark(for host: String, _ image: NSImage) -> NSImage? {
        let key = "\(host)#\(Self.pixelWidth(image))"
        if let cached = darkCache[key] { return cached }
        let variant = Self.darkVariant(image)
        darkCache[key] = variant
        return variant
    }

    /// Vrai si l'image est un logo détouré (coins transparents) : à centrer sur fond blanc, pas à étirer
    nonisolated static func isCutOut(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 2, rep.pixelsHigh > 2 else { return false }
        let corners = [(1, 1), (rep.pixelsWide - 2, 1), (1, rep.pixelsHigh - 2), (rep.pixelsWide - 2, rep.pixelsHigh - 2)]
        return corners.contains { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.5 }
    }

    /// Version sombre d'une icône à fond blanc (comme les icônes sombres d'iOS) : le blanc relié aux bords
    /// devient gris très foncé, le logo et ses détails intérieurs (le triangle de YouTube) restent intacts.
    nonisolated static func darkVariant(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let source = NSBitmapImageRep(data: tiff) else { return nil }
        let w = source.pixelsWide, h = source.pixelsHigh
        guard w > 8, h > 8, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()

        func whiteness(_ i: Int) -> Int { min(Int(data[i]), Int(data[i + 1]), Int(data[i + 2])) }
        // fond blanc ? (les quatre coins)
        let corners = [0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + w - 1) * 4]
        guard corners.allSatisfy({ whiteness($0) > 235 }) else { return nil }

        let dark: (UInt8, UInt8, UInt8) = (28, 28, 30)
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let p = stack.popLast() {
            guard !visited[p] else { continue }
            visited[p] = true
            let i = p * 4
            let white = whiteness(i)
            guard white > 170 else { continue }
            // bord adouci : mélange proportionnel à la blancheur
            let t = Double(min(max(white - 170, 0), 70)) / 70
            data[i] = UInt8(Double(data[i]) * (1 - t) + Double(dark.0) * t)
            data[i + 1] = UInt8(Double(data[i + 1]) * (1 - t) + Double(dark.1) * t)
            data[i + 2] = UInt8(Double(data[i + 2]) * (1 - t) + Double(dark.2) * t)
            guard white > 225 else { continue }   // on ne traverse que le vrai blanc
            let x = p % w, y = p / w
            if x > 0 { stack.append(p - 1) }
            if x < w - 1 { stack.append(p + 1) }
            if y > 0 { stack.append(p - w) }
            if y < h - 1 { stack.append(p + w) }
        }
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    /// Plus grand côté en pixels réels
    nonisolated static func pixelWidth(_ image: NSImage) -> Int {
        image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
    }

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("BuzzDock/icones-web-v4", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(for link: WebLink) -> NSImage? {
        let host = link.host
        if let image = images[host] { return image }
        let file = folder.appendingPathComponent("\(host).png")
        let cached = NSImage(contentsOf: file)
        if let cached {
            // mémorisé hors du rendu en cours (pas de publication pendant une mise à jour de vue)
            DispatchQueue.main.async { WebIconCache.shared.images[host] = cached }
        }
        // pas d'icône, ou une icône trop petite : on (re)cherche une version haute définition
        let tooSmall = cached.map { Self.pixelWidth($0) < 120 } ?? true
        if tooSmall, !pending.contains(host), !(cached != nil && upgraded.contains(host)), let pageURL = link.resolvedURL {
            pending.insert(host)
            upgraded.insert(host)
            let previous = cached.map(Self.pixelWidth) ?? 0
            let name = link.name
            Task.detached(priority: .utility) {
                let data = await Self.fetchIcon(pageURL: pageURL, name: name)
                await MainActor.run {
                    WebIconCache.shared.pending.remove(host)
                    guard let data, let image = NSImage(data: data), Self.pixelWidth(image) > previous else { return }
                    try? data.write(to: file)
                    WebIconCache.shared.images[host] = image
                    WebAppMaker.updateIcons(host: host, site: image)
                    NotificationCenter.default.post(name: .buzzIconsChanged, object: nil)
                }
            }
        }
        return cached
    }

    func forget(_ link: WebLink) {
        images[link.host] = nil
        pending.remove(link.host)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(link.host).png"))
    }

    nonisolated private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// Apps iPhone des sites courants (identifiant App Store)
    nonisolated private static let knownApps: [String: String] = [
        "youtube.com": "com.google.ios.youtube",
        "instagram.com": "com.burbn.instagram",
        "x.com": "com.atebits.Tweetie2",
        "twitter.com": "com.atebits.Tweetie2",
        "tiktok.com": "com.zhiliaoapp.musically",
        "linkedin.com": "com.linkedin.LinkedIn",
        "facebook.com": "com.facebook.Facebook",
        "threads.net": "com.burbn.barcelona",
        "threads.com": "com.burbn.barcelona",
        // WhatsApp : logo WhatsApp Business
        "whatsapp.com": "net.whatsapp.WhatsAppSMB",
        "web.whatsapp.com": "net.whatsapp.WhatsAppSMB",
        "messenger.com": "com.facebook.Messenger",
        "pinterest.com": "pinterest",
        "snapchat.com": "com.toyopagroup.picaboo",
        "reddit.com": "com.reddit.Reddit",
        "netflix.com": "com.netflix.Netflix",
        "spotify.com": "com.spotify.client",
        "open.spotify.com": "com.spotify.client",
        "notion.so": "notion.id",
        "canva.com": "com.canva.canvaeditor",
        "gmail.com": "com.google.Gmail",
        "mail.google.com": "com.google.Gmail",
        "drive.google.com": "com.google.Drive",
        "chatgpt.com": "com.openai.chat",
        "calendar.google.com": "com.google.Calendar",
        "photos.google.com": "com.google.photos",
        "music.youtube.com": "com.google.ios.youtubemusic",
        "app.slack.com": "com.tinyspeck.chatlyio",
        "slack.com": "com.tinyspeck.chatlyio",
        "outlook.live.com": "com.microsoft.Office.Outlook",
        "outlook.office.com": "com.microsoft.Office.Outlook",
        "web.snapchat.com": "com.toyopagroup.picaboo",
        "claude.ai": "com.anthropic.claude",
    ]

    /// Icône 512 px de l'app iPhone correspondant au site, via l'API publique de l'App Store.
    nonisolated private static func appStoreIcon(host: String, name: String) async -> URL? {
        struct Response: Decodable {
            struct App: Decodable {
                let trackName: String?
                let bundleId: String?
                let sellerUrl: String?
                let artworkUrl512: String?
            }
            let results: [App]
        }
        var query: URL?
        if let bundleID = knownApps[host] {
            query = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=fr")
        } else if !name.isEmpty, let term = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=software&country=fr&limit=8")
        }
        guard let query, let data = await download(query),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let wanted = name.lowercased()
        let app = response.results.first { app in
            if let bundleID = knownApps[host], app.bundleId == bundleID { return true }
            if let seller = app.sellerUrl, seller.lowercased().contains(host) { return true }
            return (app.trackName ?? "").lowercased() == wanted
        }
        return app?.artworkUrl512.flatMap(URL.init(string:))
    }

    nonisolated private static func fetchIcon(pageURL: URL, name: String) async -> Data? {
        var candidates: [URL] = []
        let host = pageURL.host ?? ""
        let bare = host.replacingOccurrences(of: "www.", with: "")
        // 0. Grands sites connus : icône officielle de leur app iPhone (App Store), en 512 px.
        //    Les autres sites gardent LEUR icône (une recherche par nom tombait sur des homonymes : CTV+).
        if knownApps[bare] != nil, let appStore = await appStoreIcon(host: bare, name: name), let data = await download(appStore) {
            return data
        }
        // 1. Icône « écran d'accueil » déclarée par la page
        if let html = await download(pageURL).flatMap({ String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }) {
            for rel in ["apple-touch-icon", "apple-touch-icon-precomposed", "icon"] {
                if let href = linkHref(in: html, rel: rel), let url = URL(string: href, relativeTo: pageURL)?.absoluteURL {
                    candidates.append(url)
                }
            }
        }
        // 2. Emplacement habituel, 3. services d'icônes haute définition
        if let scheme = pageURL.scheme {
            candidates.append(URL(string: "\(scheme)://\(host)/apple-touch-icon.png")!)
        }
        if let gstatic = URL(string: "https://t1.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://\(bare)&size=256") {
            candidates.append(gstatic)
        }
        if let google = URL(string: "https://www.google.com/s2/favicons?domain=\(bare)&sz=256") {
            candidates.append(google)
        }

        // on garde la plus grande ; on s'arrête dès qu'une icône est vraiment grande
        var best: (data: Data, width: Int)?
        for url in candidates {
            guard let data = await download(url), let image = NSImage(data: data) else { continue }
            let width = pixelWidth(image)
            guard width >= 16, width > (best?.width ?? 0) else { continue }
            let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? data
            best = (png, width)
            if width >= 180 { break }
        }
        return best?.data
    }

    /// Cherche <link rel="…" href="…"> (dans n'importe quel ordre d'attributs).
    nonisolated private static func linkHref(in html: String, rel: String) -> String? {
        let pattern = "<link[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            let lower = tag.lowercased()
            guard lower.contains("rel=\"\(rel)\"") || lower.contains("rel='\(rel)'") || lower.contains("rel=\(rel) ") else { continue }
            if let hrefRange = tag.range(of: #"href\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                let attr = String(tag[hrefRange])
                if let start = attr.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
                    let value = attr[attr.index(after: start)...].dropLast()
                    return value.replacingOccurrences(of: "&amp;", with: "&")
                }
            }
        }
        return nil
    }
}

/// Icône d'un raccourci web, arrondie comme une icône d'app.
struct WebLinkIcon: View {
    @ObservedObject private var cache = WebIconCache.shared
    @AppStorage("darkSiteIcons") private var darkIcons = true
    let link: WebLink
    let size: CGFloat

    var body: some View {
        Group {
            if let original = cache.image(for: link) {
                let image = darkIcons ? (WebIconCache.shared.dark(for: link.host, original) ?? original) : original
                if WebIconCache.pixelWidth(image) >= 120 && !WebIconCache.isCutOut(image) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    // petit favicon : centré sur fond blanc, comme l'iPhone
                    ZStack {
                        Color.white
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.8 * 0.18)
                    }
                }
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.35), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
                    Text(String(link.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size * 0.8, height: size * 0.8)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.8 * 0.225, style: .continuous))
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

// MARK: Menu commun d'un raccourci

struct WebLinkMenu: View {
    @EnvironmentObject private var store: DockStore
    let link: WebLink

    var body: some View {
        Button("Ouvrir") { store.openLink(link) }
        Menu("Ouvrir dans") {
            ForEach(Browsers.installed) { browser in
                Button(browser.name) {
                    var copy = link
                    copy.browser = browser.bundleID
                    copy.appWindow = false
                    Browsers.open(copy)
                }
            }
        }
        if Browsers.supportsAppWindow(link.browser) {
            Toggle(Browsers.appModeLabel(link.browser), isOn: Binding(
                get: { link.appWindow },
                set: { var copy = link; copy.appWindow = $0; store.updateLink(copy) }
            ))
        }
        Divider()
        Menu("Déplacer vers") {
            Button("Le Dock (avec les apps)") { store.moveLink(link.id, toFolder: nil) }
            ForEach(store.folders) { folder in
                Button(folder.name) { store.moveLink(link.id, toFolder: folder.id) }
            }
        }
        Button("Modifier…") { NotificationCenter.default.post(name: .buzzOpenSettings, object: nil) }
        Button("Supprimer le raccourci") { store.removeLink(link.id) }
    }
}

// MARK: Galerie d'apps web

struct WebAppGallery: View {
    @EnvironmentObject private var store: DockStore
    let onPick: (WebLink) -> Void
    let onCustom: () -> Void
    @State private var query = ""

    private var categories: [String] {
        var seen: [String] = []
        for preset in WebLink.catalog where !seen.contains(preset.category) { seen.append(preset.category) }
        return seen
    }

    var body: some View {
        let filtered = WebLink.catalog.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 10) {
            TextField("Rechercher (Instagram, Gmail…)", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(categories, id: \.self) { category in
                        let items = filtered.filter { $0.category == category }
                        if !items.isEmpty {
                            Text(category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 6), count: 4), spacing: 12) {
                                ForEach(items) { preset in
                                    let added = store.hasSite(host: preset.host, name: preset.name)
                                    VStack(spacing: 4) {
                                        WebLinkIcon(link: preset.link, size: 54)
                                            .overlay(alignment: .topTrailing) {
                                                if added {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(.white, Color.green)
                                                        .font(.system(size: 15))
                                                }
                                            }
                                        Text(preset.name).font(.system(size: 11)).lineLimit(1)
                                    }
                                    .frame(width: 78)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(preset.link) }
                                    .help(added ? "Déjà ajoutée : clic pour l'ajouter encore" : "Ajouter \(preset.name)")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 320)
            Button(action: onCustom) {
                Label("Autre site…", systemImage: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: Formulaire d'ajout

struct WebLinkForm: View {
    @State private var name = ""
    @State private var address = ""
    @State private var browser: String? = Browsers.preferred
    @State private var appWindow = true
    let onAdd: (WebLink) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Adresse (ex. instagram.com)", text: $address)
                .textFieldStyle(.roundedBorder)
            TextField("Nom (facultatif)", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Ouvrir avec", selection: $browser) {
                Text("Navigateur par défaut").tag(String?.none)
                ForEach(Browsers.installed) { b in
                    Text(b.name).tag(Optional(b.bundleID))
                }
            }
            if Browsers.supportsAppWindow(browser) {
                Toggle(Browsers.appModeLabel(browser), isOn: $appWindow)
            }
            HStack {
                Button("Annuler", action: onCancel)
                Spacer()
                Button("Ajouter") {
                    let link = WebLink(name: "", url: address, browser: browser, appWindow: appWindow)
                    guard let url = link.resolvedURL else { return }
                    var final = link
                    final.name = name.isEmpty ? WebLink.guessName(for: url) : name
                    onAdd(final)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

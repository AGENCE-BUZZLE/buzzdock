import AppKit

/// Une application installée sur le Mac.
struct AppInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    let category: String

    var id: String { url.path }
}

/// Inventaire des applications installées (équivalent de l'ancien Launchpad).
enum AppCatalog {
    static var searchFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// Parcourt les dossiers d'apps (un niveau de sous-dossier, comme « Adobe Photoshop/ »).
    static func scan() -> [AppInfo] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppInfo] = []

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            result.append(info(for: url))
        }

        for folder in searchFolders {
            guard let items = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          !searchFolders.contains(item) {
                    let nested = (try? fm.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }

        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func info(for url: URL) -> AppInfo {
        let bundle = Bundle(url: url)
        let rawCategory = bundle?.infoDictionary?["LSApplicationCategoryType"] as? String
        return AppInfo(
            url: url,
            name: displayName(for: url),
            bundleID: bundle?.bundleIdentifier,
            category: Self.category(for: rawCategory)
        )
    }

    static func displayName(for url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }

    /// Regroupe les catégories Apple en familles lisibles en français.
    static func category(for raw: String?) -> String {
        guard let raw else { return "Autres" }
        let key = raw.replacingOccurrences(of: "public.app-category.", with: "")
        if key.hasSuffix("games") { return "Jeux" }
        switch key {
        case "productivity", "business": return "Productivité"
        case "developer-tools": return "Développement"
        case "graphics-design", "photography", "video": return "Création"
        case "music": return "Musique"
        case "social-networking": return "Communication"
        case "utilities": return "Utilitaires"
        case "entertainment": return "Divertissement"
        case "education", "reference": return "Éducation"
        case "finance": return "Finance"
        case "news", "lifestyle", "travel", "weather", "sports",
             "health-fitness", "medical": return "Quotidien"
        default: return "Autres"
        }
    }
}

/// Cache des icônes (lire une icône sur le disque coûte cher).
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func forgetAll() { cache.removeAllObjects() }

    /// Icône rendue une fois en 512 px : SwiftUI ne la redessine plus depuis sa petite version (flou)
    static func crisp(_ image: NSImage, pixels: Int = 512) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        context?.imageInterpolation = .high
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        result.addRepresentation(rep)
        return result
    }

    /// Icône système nommée (Corbeille…), nette
    static func named(_ name: NSImage.Name) -> NSImage {
        let key = "nom:\(name)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = crisp(NSImage(named: name) ?? NSImage())
        cache.setObject(image, forKey: key)
        return image
    }

    static func forget(_ path: String) {
        cache.removeObject(forKey: path as NSString)
        var trimmed = path
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        cache.removeObject(forKey: trimmed as NSString)
    }

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        // apps web BuzzDock : dessinées depuis l'icône du site (version sombre si l'option est active)
        let bundle = path.hasSuffix(".app") ? Bundle(path: path) : nil
        let custom = (bundle?.bundleIdentifier ?? "").hasPrefix("fr.buzzle.webapp.")
        var image: NSImage?
        if custom {
            if let address = bundle?.object(forInfoDictionaryKey: "BuzzWebAppURL") as? String {
                let link = WebLink(name: (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "", url: address)
                if let site = WebIconCache.shared.image(for: link) {
                    let dark = UserDefaults.standard.object(forKey: "darkSiteIcons") as? Bool ?? true
                    let source = dark ? (WebIconCache.shared.dark(for: link.host, site) ?? site) : site
                    image = WebAppMaker.render(site: source, letter: "", size: 512).flatMap(NSImage.init(data:))
                }
            }
            if image == nil { image = NSImage(contentsOfFile: path + "/Contents/Resources/AppIcon.icns") }
        }
        let finalImage = crisp(image ?? NSWorkspace.shared.icon(forFile: path))
        cache.setObject(finalImage, forKey: path as NSString)
        return finalImage
    }
}

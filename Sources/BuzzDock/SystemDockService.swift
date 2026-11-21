import Foundation

/// Masque le Dock de macOS pendant que BuzzDock tourne, puis le restaure.
///
/// Principe : on active le masquage automatique du Dock système avec un délai
/// d'apparition énorme (1000 s), il ne surgit donc jamais. Les réglages d'origine
/// sont sauvegardés et remis à l'identique à l'arrêt.
enum SystemDockService {
    private static let backupKey = "systemDockBackup"
    private static let domain = "com.apple.dock"

    static func hide() {
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: backupKey) == nil {
            var backup: [String: Any] = [:]
            if let value = CFPreferencesCopyAppValue("autohide" as CFString, domain as CFString) {
                backup["autohide"] = value
            }
            if let value = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain as CFString) {
                backup["autohide-delay"] = value
            }
            if let value = CFPreferencesCopyAppValue("no-bouncing" as CFString, domain as CFString) {
                backup["no-bouncing"] = value
            }
            backup["saved"] = true
            defaults.set(backup, forKey: backupKey)
        }
        run("/usr/bin/defaults", ["write", domain, "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", domain, "autohide-delay", "-float", "1000"])
        // une app qui réclame l'attention (notification) ne fait plus rebondir ni ressortir le Dock d'Apple
        run("/usr/bin/defaults", ["write", domain, "no-bouncing", "-bool", "true"])
        run("/usr/bin/killall", ["Dock"])
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard let backup = defaults.dictionary(forKey: backupKey) else { return }

        if let autohide = backup["autohide"] as? Bool {
            run("/usr/bin/defaults", ["write", domain, "autohide", "-bool", autohide ? "true" : "false"])
        } else {
            run("/usr/bin/defaults", ["delete", domain, "autohide"])
        }
        if let delay = backup["autohide-delay"] as? Double {
            run("/usr/bin/defaults", ["write", domain, "autohide-delay", "-float", String(delay)])
        } else {
            run("/usr/bin/defaults", ["delete", domain, "autohide-delay"])
        }
        if let bouncing = backup["no-bouncing"] as? Bool {
            run("/usr/bin/defaults", ["write", domain, "no-bouncing", "-bool", bouncing ? "true" : "false"])
        } else {
            run("/usr/bin/defaults", ["delete", domain, "no-bouncing"])
        }
        run("/usr/bin/killall", ["Dock"])
        defaults.removeObject(forKey: backupKey)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

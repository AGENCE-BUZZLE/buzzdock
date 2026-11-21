import AppKit
import Combine
import IOKit.ps
import QuickLookThumbnailing

// MARK: Processeur, batterie, réseau

/// Mesures système rafraîchies toutes les 2 secondes (API publiques, aucune permission).
@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var battery: Double?
    @Published private(set) var charging = false
    @Published private(set) var downBytesPerSecond: Double = 0
    @Published private(set) var upBytesPerSecond: Double = 0

    private let host = mach_host_self()
    private var lastTicks: (used: UInt64, total: UInt64)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private var timer: Timer?

    private init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        if let value = sampleCPU() { cpu = value }
        sampleBattery()
        sampleNetwork()
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        defer { lastTicks = (used, total) }
        guard let last = lastTicks, total > last.total, used >= last.used else { return nil }
        return Double(used - last.used) / Double(total - last.total)
    }

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                battery = Double(current) / Double(maximum)
            }
            charging = description[kIOPSIsChargingKey] as? Bool ?? false
        }
    }

    private func sampleNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return }
        defer { freeifaddrs(addresses) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var cursor = addresses
        while let ifa = cursor?.pointee {
            if let address = ifa.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.ifa_data, String(cString: ifa.ifa_name).hasPrefix("en") {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                inBytes += UInt64(stats.ifi_ibytes)
                outBytes += UInt64(stats.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }

        let now = Date()
        if let last = lastNet {
            let elapsed = now.timeIntervalSince(last.at)
            if elapsed > 0 {
                downBytesPerSecond = inBytes >= last.inBytes ? Double(inBytes - last.inBytes) / elapsed : 0
                upBytesPerSecond = outBytes >= last.outBytes ? Double(outBytes - last.outBytes) / elapsed : 0
            }
        }
        lastNet = (inBytes, outBytes, now)
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kilo = bytesPerSecond / 1024
        if kilo < 1000 { return String(format: "%.1f Ko/s", kilo) }
        return String(format: "%.1f Mo/s", kilo / 1024)
    }
}

// MARK: Morceau en cours (Spotify ou Musique)

/// Lit le morceau en cours par AppleScript (macOS demande une fois l'autorisation d'automatisation).
/// Tout passe par `osascript` sur une file en arrière-plan : une demande d'autorisation en attente
/// ne peut jamais figer le Dock. Un lecteur n'est interrogé que s'il est déjà ouvert.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    struct Track: Equatable {
        var title: String
        var artist: String
        var position: Double
        var duration: Double
        var isPlaying: Bool
        var player: String
        var artworkURL: String
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?

    private var sampledAt = Date()
    private var artworkKey: String?
    private var timer: Timer?
    private var polling = false
    private let queue = DispatchQueue(label: "fr.buzzle.buzzdock.nowplaying", qos: .utility)

    nonisolated private static let spotifyScript = """
        tell application "Spotify"
            if player state is not stopped then
                set t to current track
                return (name of t) & "|||" & (artist of t) & "|||" & (player position as text) & "|||" & (duration of t as text) & "|||" & (artwork url of t) & "|||" & (player state as text)
            end if
        end tell
        return ""
        """

    nonisolated private static let musicScript = """
        tell application "Music"
            if player state is not stopped then
                set t to current track
                return (name of t) & "|||" & (artist of t) & "|||" & (player position as text) & "|||" & (duration of t as text) & "|||" & "" & "|||" & (player state as text)
            end if
        end tell
        return ""
        """

    private init() {
        // Premier relevé un peu après le démarrage, jamais pendant
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func elapsed(at date: Date) -> Double {
        guard let track else { return 0 }
        let extra = track.isPlaying ? date.timeIntervalSince(sampledAt) : 0
        return min(track.duration, track.position + extra)
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ command: String) {
        guard let player = track?.player else { return }
        let source = "tell application \"\(player)\" to \(command)"
        queue.async {
            _ = Self.osascript(source)
            DispatchQueue.main.async { [weak self] in self?.poll() }
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func poll() {
        guard !polling else { return }
        let spotify = isRunning("com.spotify.client")
        let music = isRunning("com.apple.Music")
        guard spotify || music else {
            if track != nil { track = nil }
            updateArtwork()
            return
        }
        polling = true
        queue.async {
            var result: Track?
            if spotify {
                result = Self.query(Self.spotifyScript, player: "Spotify")
            }
            if result?.isPlaying != true, music,
               let found = Self.query(Self.musicScript, player: "Music"), found.isPlaying || result == nil {
                result = found
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.polling = false
                self.sampledAt = Date()
                if self.track != result { self.track = result }
                self.updateArtwork()
            }
        }
    }

    private func updateArtwork() {
        guard let track else {
            artwork = nil
            artworkKey = nil
            return
        }
        let key = track.player + track.title + track.artist
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil

        if track.player == "Spotify", let url = URL(string: track.artworkURL), url.scheme == "https" {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard let self, self.artworkKey == key else { return }
                    self.artwork = image
                }
            }.resume()
        } else if track.player == "Music" {
            queue.async {
                let output = Self.osascript("tell application \"Music\" to get raw data of artwork 1 of current track")
                let data = output.flatMap(Self.decodeAppleScriptData)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.artworkKey == key, let data else { return }
                    self.artwork = NSImage(data: data)
                }
            }
        }
    }

    // MARK: Outils (hors fil principal)

    nonisolated private static func query(_ source: String, player: String) -> Track? {
        guard let output = osascript(source), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }
        func number(_ text: String) -> Double {
            Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var duration = number(parts[3])
        if player == "Spotify" { duration /= 1000 } // Spotify donne la durée en millisecondes
        return Track(
            title: parts[0],
            artist: parts[1],
            position: number(parts[2]),
            duration: duration,
            isPlaying: parts[5].contains("playing"),
            player: player,
            artworkURL: parts[4]
        )
    }

    /// Lance osascript et renvoie sa sortie (bloquant : à appeler sur la file d'arrière-plan).
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
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Décode « «data PNGf89504E47…» » renvoyé par AppleScript.
    nonisolated private static func decodeAppleScriptData(_ text: String) -> Data? {
        guard let open = text.range(of: "«data "),
              let close = text.range(of: "»", range: open.upperBound..<text.endIndex) else { return nil }
        let hex = Array(text[open.upperBound..<close.lowerBound].dropFirst(4))
        var data = Data(capacity: hex.count / 2)
        var index = 0
        while index + 1 < hex.count {
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: Miniatures (pile Téléchargements)

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    @Published private(set) var images: [URL: NSImage] = [:]
    private var pending = Set<URL>()

    func image(for url: URL, size: CGFloat) -> NSImage {
        if let image = images[url] { return image }
        if !pending.contains(url) {
            pending.insert(url)
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async { self?.images[url] = image }
            }
        }
        return IconCache.icon(for: url.path)
    }
}

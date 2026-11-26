// Myskef — the window.
//
// This is a SwiftUI front end for Resources/myskef-core.sh, which does the
// real work (Wine engine, bottle, DXVK, Epic downloads via legendary). Every
// button runs one core command and reads its output line by line:
//   STATUS: …   progress text            ERROR: …   something went wrong
//   key=value   status values            INSTALLED / OWNED <TAB> …  game lists
//   ACCOUNT=…   Epic account name        NEED_LOGIN  Epic login required
//   DONE / FAILED (n)                    end of the command
//
// Built on your Mac the first time Myskef opens (see Contents/MacOS/Myskef).

import SwiftUI
import AppKit
import Darwin

// MARK: - Paths

enum Paths {
    static let resources: URL = {
        if let r = ProcessInfo.processInfo.environment["MYSKEF_RES"], !r.isEmpty {
            return URL(fileURLWithPath: r)
        }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }()
    static let core = resources.appendingPathComponent("myskef-core.sh")
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Myskef")
    static let legendaryConfig = support.appendingPathComponent("legendary-config")
    static let log = support.appendingPathComponent("logs/myskef.log")
}

let epicLoginURL = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!

// MARK: - Model

enum GameSource: String, Hashable {
    case epic = "Epic"
    case steam = "Steam"
}

struct Game: Identifiable, Hashable {
    let id: String          // Epic app name, or "steam:<appid>"
    var title: String
    var version: String = ""
    var updateAvailable: Bool = false
    var size: Int64 = 0
    var path: String = ""
    var source: GameSource = .epic
    var appID: String = ""  // Steam app id
    var fullyInstalled: Bool = true
}

struct WinProgram: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

/// Files macOS asks Myskef to open (Open With, Dock icon). They can arrive
/// before the window exists, so they wait here until the model picks them up.
enum OpenRequests {
    static var handler: (([URL]) -> Void)? = nil
    static var pending: [URL] = []
    static func add(_ urls: [URL]) {
        if let h = handler { h(urls) } else { pending += urls }
    }
    static func drain() {
        guard !pending.isEmpty, let h = handler else { return }
        let urls = pending; pending = []
        h(urls)
    }
}

struct LogLine: Identifiable {
    let id: Int
    let text: String
    var routine: Bool = false   // from a background check (status, library refresh…)
}

/// A newer Myskef found on the update channel.
struct UpdateInfo: Equatable {
    let version: String
    let url: String
    let shaURL: String
    let notes: String
}

/// Plain-language description of each graphics layer, used in Settings, Game settings and the Guide.
struct GraphicsModeInfo: Identifiable {
    let id: String
    let name: String
    let route: String
    let summary: String
    let bestFor: String
    let watchOut: String

    static let all: [GraphicsModeInfo] = [
        GraphicsModeInfo(
            id: "dxvk", name: "DXVK", route: "DirectX → Vulkan → Metal",
            summary: "The most widely used translator. It turns a game's DirectX 9, 10 or 11 graphics into Vulkan, and MoltenVK turns that into Metal, the Mac's graphics system.",
            bestFor: "Most games. The safe default, and what Steam's own window uses.",
            watchOut: "Two steps, so a little more work for the processor. Some Unity games run better with the launch option -force-vulkan."),
        GraphicsModeInfo(
            id: "dxmt", name: "DXMT", route: "DirectX 11 → Metal",
            summary: "Translates DirectX 11 straight into Metal in one step, so the processor has less to do.",
            bestFor: "DirectX 11 games that are limited by the processor, like Bloons TD 6.",
            watchOut: "Newer and less tested: some games show glitches or crash. DirectX 11 only."),
        GraphicsModeInfo(
            id: "d3dmetal", name: "D3DMetal", route: "DirectX 11/12 → Metal (Apple)",
            summary: "Apple's own translator, from its Game Porting Toolkit. Often the fastest for big 3D games, and the only option here for DirectX 12.",
            bestFor: "Demanding 3D games limited by graphics (like Raft) and DirectX 12 games.",
            watchOut: "Per game only. It brings its own older Wine and a separate Windows setup: a 230 MB download, plus a second copy of Steam for Steam games. Apple's licence applies."),
        GraphicsModeInfo(
            id: "wined3d", name: "Wine built-in", route: "DirectX → OpenGL",
            summary: "Wine's own translator.",
            bestFor: "Old DirectX 9 games and simple programs, when nothing else works.",
            watchOut: "Usually the slowest. A last resort."),
    ]
    static func info(_ id: String) -> GraphicsModeInfo? { all.first { $0.id == id } }
}

/// A short card describing one graphics layer.
struct GraphicsModeCard: View {
    let info: GraphicsModeInfo
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(info.name).font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                Text(info.route).font(.caption).foregroundColor(.secondary)
            }
            Text(info.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Label(info.bestFor, systemImage: "hand.thumbsup.fill")
                .font(.caption).foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
            Label(info.watchOut, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

/// A switch with a one-line explanation under it.
struct ExplainedToggle: View {
    let title: String
    let text: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What could be slowing the Mac down while a game runs.
struct MacHealth: Equatable {
    var hot = false         // macOS is slowing the processor down to cool off
    var lowMemory = false   // memory is full, so the Mac is using the disk instead
    var lowPower = false    // Low Power Mode is on

    var short: String? {
        if lowPower && !hot && !lowMemory { return "Low Power Mode is on: games run slower" }
        if hot && lowMemory { return "Mac is hot and out of memory" }
        if hot { return "Mac is hot: macOS is slowing it down" }
        if lowMemory { return "Memory is full: close other apps" }
        return nil
    }
    var advice: String? {
        var parts: [String] = []
        if lowMemory {
            parts.append("Your Mac has run out of memory and is using the disk instead, which makes games stutter. Close Chrome and other apps; if it stays slow, quit and restart the game.")
        }
        if hot {
            parts.append("Your Mac is hot, so macOS is slowing it down to cool off. Plug it in, keep it on a hard surface, and take a short break if it keeps happening.")
        }
        if lowPower {
            parts.append("Low Power Mode is on, which slows the processor down. Turn it off in System Settings → Battery while you play.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Memory pressure (1 normal, 2 warning, 4 critical) and swap in use (MB).
    static func readMemory() -> (pressure: Int32, swapMB: Double) {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 { level = 0 }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let used = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? Double(swap.xsu_used) / 1_048_576 : 0
        return (level, used)
    }
}

/// Where a game is after you press Play.
enum PlayState: Equatable {
    case starting(String)   // Myskef is preparing (detail = latest step)
    case opening            // handed to Windows; waiting for the game to show up
    case running
    case failed(String)     // why it didn't start
}

struct RunningTask {
    var title: String
    var detail: String = ""
    var progress: Double? = nil      // 0...1 when known
    var finished: Bool = false
    var failed: Bool = false
}

/// The activity log lives on its own, so new log lines only redraw the log
/// window and not the whole app. Lines are handed over in batches.
final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published private(set) var lines: [LogLine] = []
    private var pending: [LogLine] = []
    private var flushScheduled = false
    private var nextID = 0
    func append(_ s: String, routine: Bool = false) {          // main thread only
        pending.append(LogLine(id: nextID, text: s, routine: routine))
        nextID += 1
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flush() }
    }
    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var all = lines + pending
        pending.removeAll()
        if all.count > 3000 { all.removeFirst(all.count - 3000) }
        lines = all
    }
}

final class Myskef: ObservableObject, @unchecked Sendable {
    @Published var status: [String: String] = [:]
    @Published var installed: [Game] = []
    @Published var owned: [Game] = Myskef.cachedOwned()
    @Published var ownedProgress: String? = nil
    @Published var ownedOffline = false
    var ownedRefreshedThisSession = false

    /// The Epic library from last time, so it shows instantly while Epic is asked again.
    static func cachedOwned() -> [Game] {
        guard let rows = UserDefaults.standard.array(forKey: "ownedCache") as? [[String]] else { return [] }
        return rows.compactMap { $0.count == 2 ? Game(id: $0[0], title: $0[1]) : nil }
    }
    @Published var steamGames: [Game] = []
    @Published var steamOwned: [Game] = []
    @Published var settingsGame: Game? = nil
    @Published var loadingSteamOwned = false
    @Published var account: String? = nil
    @Published var loadedStatus = false
    @Published var loadingOwned = false
    @Published var task: RunningTask? = nil
    @Published var alert: String? = nil
    @Published var showLogin = false
    @Published var showLog = false
    @Published var gameRunning = false
    @Published var lastStarted: String? = nil
    @Published var playStates: [String: PlayState] = [:]
    @Published var health = MacHealth()
    @Published var update: UpdateInfo? = nil
    @Published var updateDismissed = false
    @Published var updatesConfigured = true
    private var updateTimer: Timer?
    private var swapAtGameStart: Double? = nil
    private var openingSince: [String: Date] = [:]
    private var runningSince: [String: Date] = [:]
    @Published var lastPlayedID: String? = UserDefaults.standard.string(forKey: "lastPlayedID")
    @Published var programs: [WinProgram] = []
    @Published var recentPrograms: [String] = UserDefaults.standard.stringArray(forKey: "recentPrograms") ?? []
    @Published var openPage: SidebarPage? = nil     // asks the window to switch page
    /// The game shown big at the top of the Library: the last one played.
    var heroGame: Game? {
        let all = libraryGames
        return all.first { $0.id == lastPlayedID } ?? all.first
    }

    private var imageCache: [String: URL?] = [:]
    private var afterLogin: (() -> Void)? = nil
    private var pollTimer: Timer? = nil

    var busy: Bool { if let t = task { return !t.finished } else { return false } }
    var engineOK: Bool { status["engine_ok"] == "yes" }
    var isSetUp: Bool { status["bottle"] == "yes" && (status["engine"] ?? "none") != "none" }
    var steamInstalled: Bool { status["steam"] == "yes" }
    /// Everything that can be played: Epic games plus installed Steam games.
    var libraryGames: [Game] {
        (installed + steamGames).sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    init() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollRunning()
        }
        // look for a newer Myskef shortly after opening, then every 6 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.autoCheckForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.autoCheckForUpdates()
        }
        // files opened with Finder's "Open With → Myskef" or dropped on the Dock icon
        OpenRequests.handler = { [weak self] urls in
            guard let self = self, let u = urls.first else { return }
            self.openPage = .programs
            self.runProgram(u, copy: UserDefaults.standard.bool(forKey: "copyPrograms"))
        }
        DispatchQueue.main.async { OpenRequests.drain() }
    }

    // MARK: Windows programs (.exe / .msi)

    static let runnableExtensions: Set<String> = ["exe", "msi", "bat", "cmd", "lnk"]

    func runProgram(_ url: URL, copy: Bool = false) {
        let ext = url.pathExtension.lowercased()
        guard Myskef.runnableExtensions.contains(ext) else {
            alert = "“\(url.lastPathComponent)” isn't a Windows program. Myskef can run files ending in .exe, .msi or .bat."
            return
        }
        var args = ["run"]
        if copy && ext != "lnk" { args.append("--copy") }
        args.append(url.path)
        var ranPath = url.path
        let name = url.deletingPathExtension().lastPathComponent
        job(ext == "msi" ? "Installing \(name)" : "Starting \(name)", args, onSuccess: { [weak self] in
            guard let self = self else { return }
            if ext != "lnk" { self.remember(ranPath) }
            self.gameRunning = true
            self.loadPrograms()
        }, onLine: { l in
            if l.hasPrefix("PROGRAM_PATH=") { ranPath = String(l.dropFirst(13)) }
        })
    }

    // MARK: Updates

    private func autoCheckForUpdates() {
        if UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool == false { return }
        checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) {
        var version = "", url = "", shaURL = "", notes = "", none = ""
        core(["update-check"], line: { l in
            if l.hasPrefix("UPDATE_VERSION=") { version = String(l.dropFirst(15)) }
            else if l.hasPrefix("UPDATE_URL=") { url = String(l.dropFirst(11)) }
            else if l.hasPrefix("UPDATE_SHA_URL=") { shaURL = String(l.dropFirst(15)) }
            else if l.hasPrefix("UPDATE_NOTES=") {
                let b64 = String(l.dropFirst(13))
                if let d = Data(base64Encoded: b64) { notes = String(decoding: d, as: UTF8.self) }
            }
            else if l.hasPrefix("UPDATE_NONE=") { none = String(l.dropFirst(12)) }
        }, done: { [weak self] _ in
            guard let self = self else { return }
            self.updatesConfigured = !none.hasPrefix("not-configured")
            if !version.isEmpty && !url.isEmpty {
                let info = UpdateInfo(version: version, url: url, shaURL: shaURL, notes: notes)
                if self.update != info { self.updateDismissed = false }
                self.update = info
                if manual { self.updateDismissed = false }
            } else if manual {
                if none.hasPrefix("not-configured") {
                    self.alert = "This copy of Myskef isn't connected to an update channel yet."
                } else if none.hasPrefix("unreachable") {
                    self.alert = "Couldn't reach the update server. Check your internet connection and try again."
                } else {
                    self.alert = "You have the latest Myskef (\(self.status["version"] ?? ""))."
                }
            }
        })
    }

    func installUpdate() {
        guard let u = update else { return }
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        job("Updating Myskef to \(u.version)", ["update-install", u.url, u.shaURL, pid], onSuccess: {
            // the installer swaps the app once this window has closed, then reopens Myskef
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
        })
    }

    /// Packs this copy of Myskef (with its window already built) plus a read-me into a zip for friends.
    func shareMyskef() {
        let panel = NSSavePanel()
        panel.title = "Share Myskef"
        panel.message = "Myskef makes a zip you can send to friends (AirDrop, WhatsApp, a USB stick…). It contains the app and a “Read me first” guide. None of your games, accounts or settings are included."
        panel.nameFieldStringValue = "Myskef.zip"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var made: String? = nil
        job("Making a copy to share", ["share", url.path], onSuccess: {
            if let m = made { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m)]) }
        }, onLine: { l in
            if l.hasPrefix("SHARE_PATH=") { made = String(l.dropFirst(11)) }
        })
    }

    func chooseProgram(copy: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows program"
        panel.message = "Pick an .exe, .msi or .bat file to run with Myskef."
        panel.prompt = "Run"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { runProgram(url, copy: copy) }
    }

    private func remember(_ path: String) {
        var list = recentPrograms.filter { $0 != path }
        list.insert(path, at: 0)
        recentPrograms = Array(list.prefix(12))
        UserDefaults.standard.set(recentPrograms, forKey: "recentPrograms")
    }

    func forget(_ path: String) {
        recentPrograms.removeAll { $0 == path }
        UserDefaults.standard.set(recentPrograms, forKey: "recentPrograms")
    }

    func loadPrograms() {
        var list: [WinProgram] = []
        core(["programs"], line: { l in
            let f = l.components(separatedBy: "\t")
            if f.count >= 3 && f[0] == "PROGRAM" { list.append(WinProgram(name: f[1], path: f[2])) }
        }, done: { [weak self] _ in
            self?.programs = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        })
    }

    // MARK: running core commands

    /// Runs `myskef-core.sh <args>`; calls `line` for each output line (on the
    /// main thread) and `done` with the exit status when it ends.
    func core(_ args: [String], line: ((String) -> Void)? = nil, done: ((Int32) -> Void)? = nil) {
        let routine = Myskef.isRoutine(args)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.core.path] + args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let reader = LineReader()
        let handle = pipe.fileHandleForReading
        let deliver: ([String]) -> Void = { [weak self] lines in
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                for l in lines {
                    self?.appendLog(l, routine: routine)
                    line?(l)
                }
            }
        }
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            deliver(reader.feed(d))
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            // give the last output a moment to arrive, then finish
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                handle.readabilityHandler = nil
                deliver(reader.finish())
                DispatchQueue.main.async { done?(code) }
            }
        }
        do {
            try p.run()
        } catch {
            appendLog("Couldn't start Myskef's core: \(error.localizedDescription)")
            done?(127)
        }
    }

    private func appendLog(_ s: String, routine: Bool = false) { LogStore.shared.append(s, routine: routine) }

    /// Background checks that would bury the interesting lines in the activity log.
    static func isRoutine(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if ["status", "running", "steam-owned", "steam-games", "programs", "update-check"].contains(first) { return true }
        if first == "epic", args.count > 1, ["owned", "whoami", "installed"].contains(args[1]) { return true }
        return false
    }

    /// A long job shown in the activity bar.
    func job(_ title: String, _ args: [String], onSuccess: (() -> Void)? = nil, onLine: ((String) -> Void)? = nil,
             onFailure: ((String) -> Void)? = nil) {
        guard !busy else {
            alert = "Myskef is still busy with “\(task?.title ?? "something")”. Wait for it to finish first."
            return
        }
        task = RunningTask(title: title, detail: "Starting…")
        var errors: [String] = []
        var needLogin = false
        core(args, line: { [weak self] l in
            guard let self = self else { return }
            if l.hasPrefix("ERROR: ") { errors.append(String(l.dropFirst(7))) }
            if l == "NEED_LOGIN" { needLogin = true }
            self.parseProgress(l)
            onLine?(l)
            if l.hasPrefix("ACCOUNT=") { self.account = String(l.dropFirst(8)) }
        }, done: { [weak self] code in
            guard let self = self else { return }
            self.task?.finished = true
            self.task?.failed = code != 0
            if code == 0 {
                self.task?.detail = "Done"
                self.task?.progress = 1
                onSuccess?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if self?.task?.finished == true && self?.task?.failed == false { self?.task = nil }
                }
            } else if needLogin {
                self.task = nil
                self.afterLogin = { [weak self] in self?.job(title, args, onSuccess: onSuccess, onLine: onLine, onFailure: onFailure) }
                self.showLogin = true
                onFailure?("Sign in to Epic, then press Play again.")
            } else {
                self.task?.detail = errors.last ?? "Something went wrong. Open the details to see what happened."
                if let f = onFailure {
                    f(errors.last ?? "Something went wrong.")   // shown on the game itself, no pop-up
                } else {
                    self.alert = errors.last ?? "“\(title)” didn't finish. Click “Details” in the bar at the bottom to see what happened."
                }
            }
            self.refresh()
        })
    }

    private func parseProgress(_ l: String) {
        if l.hasPrefix("STATUS: ") {
            task?.detail = String(l.dropFirst(8))
        } else if l.hasPrefix(">>> ") {
            task?.detail = String(l.dropFirst(4))
        } else if let pct = firstMatch(#"Progress: ([0-9.]+)%"#, in: l), let v = Double(pct) {
            task?.progress = min(max(v / 100, 0), 1)
            var d = String(format: "%.0f%%", v)
            if let eta = firstMatch(#"ETA: ([0-9:]+)"#, in: l) { d += " · about \(eta) left" }
            task?.detail = d
        } else if l.contains("Waiting for installation to finish") {
            task?.detail = "Finishing up…"
        } else if l.contains("Preparing download") {
            task?.detail = "Preparing download…"
        }
    }

    // MARK: status

    private var refreshing = false, refreshAgain = false
    /// One status check at a time; asks made meanwhile are merged into one more.
    func refresh() {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        var st: [String: String] = [:]
        var games: [Game] = []
        var steam: [Game] = []
        var acct: String? = nil
        core(["status"], line: { l in
            if l.hasPrefix("STEAMGAME\t") {
                let f = l.components(separatedBy: "\t")
                if f.count >= 6 {
                    steam.append(Game(id: "steam:" + f[1], title: f[2], size: Int64(f[3]) ?? 0,
                                      path: f[5], source: .steam, appID: f[1],
                                      fullyInstalled: f[4] == "1"))
                }
            } else if l.hasPrefix("INSTALLED\t") {
                let f = l.components(separatedBy: "\t")
                if f.count >= 7 {
                    games.append(Game(id: f[1], title: f[2], version: f[3],
                                      updateAvailable: f[4] == "True",
                                      size: Int64(f[5]) ?? 0, path: f[6]))
                }
            } else if l.hasPrefix("ACCOUNT=") {
                acct = String(l.dropFirst(8))
            } else if let eq = l.firstIndex(of: "=") {
                let key = String(l[..<eq])
                if !key.isEmpty && !key.contains(" ") && !key.contains("\t") {
                    st[key] = String(l[l.index(after: eq)...])
                }
            }
        }, done: { [weak self] _ in
            guard let self = self else { return }
            self.status = st
            self.installed = games.sorted { $0.title.lowercased() < $1.title.lowercased() }
            self.steamGames = steam.sorted { $0.title.lowercased() < $1.title.lowercased() }
            self.account = acct
            self.gameRunning = st["running"] == "yes"
            self.loadedStatus = true
            self.refreshing = false
            if self.refreshAgain { self.refreshAgain = false; self.refresh() }
        })
    }

    /// Is a Windows program running? Checked quietly every few seconds.
    func pollRunning() {
        guard loadedStatus else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [Paths.core.path, "running"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let running = String(decoding: data, as: UTF8.self).contains("running=yes")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updatePlayStates(running: running)
                self.updateHealth(running: running)
                if self.gameRunning != running {
                    let stopped = self.gameRunning && !running
                    self.gameRunning = running
                    // e.g. Steam was closed after downloading something: update the library
                    if stopped && !self.busy { self.refresh() }
                }
            }
        }
    }

    func loadOwned() {
        guard !loadingOwned else { return }
        loadingOwned = true
        ownedProgress = "Connecting to Epic…"
        ownedOffline = false
        var games: [Game] = []
        var needLogin = false, offline = false
        var lastMessage = ""
        core(["epic", "owned"], line: { [weak self] l in
            if l.hasPrefix("OWNED\t") {
                let f = l.components(separatedBy: "\t")
                if f.count >= 3 { games.append(Game(id: f[1], title: f[2])) }
            } else if l.hasPrefix("STATUS: ") {
                self?.ownedProgress = String(l.dropFirst(8))
            } else if l == "NEED_LOGIN" {
                needLogin = true
            } else if l == "OFFLINE" {
                offline = true
            } else if !l.hasPrefix("[") && !l.hasPrefix("=====") && !l.trimmingCharacters(in: .whitespaces).isEmpty {
                lastMessage = l
            }
        }, done: { [weak self] code in
            guard let self = self else { return }
            self.loadingOwned = false
            self.ownedProgress = nil
            if needLogin {
                self.afterLogin = { [weak self] in self?.loadOwned() }
                self.showLogin = true
            } else if code == 0 {
                self.imageCache.removeAll()
                self.owned = games.sorted { $0.title.lowercased() < $1.title.lowercased() }
                UserDefaults.standard.set(self.owned.map { [$0.id, $0.title] }, forKey: "ownedCache")
            } else if offline {
                self.ownedOffline = true
                if self.owned.isEmpty {
                    self.alert = "Can't reach Epic's servers. Check your internet connection (or VPN) and try again."
                }
            } else if self.owned.isEmpty {
                self.alert = lastMessage.isEmpty
                    ? "Couldn't load your Epic library. Check your internet connection and try again."
                    : "Couldn't load your Epic library: \(lastMessage)"
            }
        })
    }

    // MARK: actions

    func play(_ g: Game) {
        guard !busy else {
            alert = "Myskef is still busy with “\(task?.title ?? "something")”. Wait for it to finish first."
            return
        }
        lastStarted = g.title
        lastPlayedID = g.id
        UserDefaults.standard.set(g.id, forKey: "lastPlayedID")
        // only one game at a time is tracked
        for (id, st) in playStates where id != g.id && st != .running { playStates[id] = nil }
        playStates[g.id] = .starting("Getting ready…")
        let args = g.source == .steam ? ["steam-play", g.appID] : ["play", g.id, g.title]
        job("Starting \(g.title)", args, onSuccess: { [weak self] in
            guard let self = self else { return }
            self.gameRunning = true
            self.playStates[g.id] = .opening
            self.openingSince[g.id] = Date()
            self.pollRunning()
        }, onLine: { [weak self] l in
            guard let self = self, l.hasPrefix("STATUS: ") else { return }
            switch self.playStates[g.id] {
            case .starting(_)?, .failed(_)?:   // .failed: the retry after signing in to Epic
                self.playStates[g.id] = .starting(String(l.dropFirst(8)))
            default: break
            }
        }, onFailure: { [weak self] why in
            self?.playStates[g.id] = .failed(why)
        })
    }

    /// Clears a "didn't start" note (e.g. after looking at it).
    func dismissPlayState(_ g: Game) { playStates[g.id] = nil }

    /// Checks memory and heat while a game runs (both make a game slower over time).
    private func updateHealth(running: Bool) {
        guard running else {
            swapAtGameStart = nil
            if health != MacHealth() { health = MacHealth() }
            return
        }
        let mem = MacHealth.readMemory()
        if swapAtGameStart == nil { swapAtGameStart = mem.swapMB }
        let swapGrowth = mem.swapMB - (swapAtGameStart ?? mem.swapMB)
        let thermal = ProcessInfo.processInfo.thermalState
        let h = MacHealth(hot: thermal == .serious || thermal == .critical,
                          lowMemory: mem.pressure >= 2 || swapGrowth > 1500,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if h != health { health = h }
    }

    /// Moves games along Opening → Running → closed, from the "is anything running?" check.
    private func updatePlayStates(running: Bool) {
        let now = Date()
        for (id, st) in playStates {
            switch st {
            case .opening:
                if running {
                    playStates[id] = .running
                    runningSince[id] = now
                } else if let t = openingSince[id], now.timeIntervalSince(t) > 90 {
                    playStates[id] = .failed("The game didn't open. Open the activity log to see why.")
                }
            case .running:
                if !running {
                    let short = runningSince[id].map { now.timeIntervalSince($0) < 20 } ?? false
                    playStates[id] = short ? .failed("The game closed right after starting. Open the activity log to see why.") : nil
                    runningSince[id] = nil
                }
            default:
                break
            }
        }
    }
    func installSteam() {
        job("Installing Steam", ["steam-install"]) { [weak self] in self?.openSteam() }
    }
    func openSteam() {
        job("Opening Steam", ["steam-open"]) { [weak self] in self?.gameRunning = true }
    }
    func setSteamRender(_ mode: String) {
        status["steam_render"] = mode
        core(["set", "STEAM_RENDER", mode], done: { [weak self] _ in
            guard let self = self else { return }
            if self.status["steam_running"] == "yes" || self.gameRunning {
                self.job("Restarting Steam", ["steam-restart"]) { [weak self] in self?.gameRunning = true }
            }
        })
    }
    /// Every game in the Steam library (installed or not), from Steam's own cache.
    func loadSteamOwned() {
        guard !loadingSteamOwned else { return }
        loadingSteamOwned = true
        var games: [Game] = []
        core(["steam-owned"], line: { l in
            if l.hasPrefix("STEAMOWNED\t") {
                let f = l.components(separatedBy: "\t")
                if f.count >= 3 {
                    games.append(Game(id: "steam:" + f[1], title: f[2], source: .steam, appID: f[1]))
                }
            }
        }, done: { [weak self] _ in
            guard let self = self else { return }
            self.loadingSteamOwned = false
            self.steamOwned = games.sorted { $0.title.lowercased() < $1.title.lowercased() }
        })
    }
    /// Asks Steam to install a game; Steam shows its own Install window.
    func getSteamGame(_ g: Game) {
        job("Opening Steam to install \(g.title)", ["steam-get", g.appID]) { [weak self] in
            self?.gameRunning = true
            self?.alert = "Steam will show an Install window for \(g.title). Click Install there. When the download finishes, close Steam or press refresh, and it shows up in your Library."
        }
    }
    /// Library rows: every owned game, plus installed ones the cache missed.
    var steamLibrary: [Game] {
        var byID: [String: Game] = [:]
        for g in steamOwned { byID[g.appID] = g }
        for g in steamGames { byID[g.appID] = g }   // installed info wins
        return byID.values.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }
    /// Saves a game's own graphics layer and launch options.
    func setGame(_ g: Game, gfx: String, args: String) {
        let gfxKey = "GAME_\(g.id)_GFX", argsKey = "GAME_\(g.id)_ARGS"
        status[gfxKey] = gfx
        status[argsKey] = args
        let saveArgs: () -> Void = { [weak self] in self?.core(["set", argsKey, args]) }
        if gfx == "dxmt" && (status["dxmt"] ?? "no") == "no" {
            job("Installing DXMT for \(g.title)", ["set", gfxKey, gfx], onSuccess: saveArgs)
        } else if gfx == "d3dmetal" && (status["d3dmetal"] ?? "no") == "no" {
            job("Installing D3DMetal for \(g.title)", ["set", gfxKey, gfx], onSuccess: { [weak self] in
                self?.status["d3dmetal"] = "yes"
                saveArgs()
            })
        } else {
            core(["set", gfxKey, gfx], done: { _ in saveArgs() })
        }
    }
    func uninstallSteamGame(_ g: Game) {
        job("Opening Steam to remove \(g.title)", ["steam-uninstall", g.appID])
    }
    func artURL(_ g: Game, tall: Bool = false) -> URL? {
        if g.source == .steam {
            let file = tall ? "library_600x900.jpg" : "header.jpg"
            return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(g.appID)/\(file)")
        }
        return imageURL(for: g.id, tall: tall)
    }
    func install(_ g: Game) {
        job("Downloading \(g.title)", ["epic", "install", g.id])
    }
    func update(_ g: Game) {
        job("Updating \(g.title)", ["epic", "update", g.id])
    }
    func uninstall(_ g: Game) {
        job("Removing \(g.title)", ["epic", "uninstall", g.id])
    }
    func setup() { job("Setting up Myskef", ["setup"]) }
    func updateEngine() { job("Updating the Wine engine", ["update-engine"]) }
    func forceQuit() {
        job("Closing Windows programs", ["force-quit"]) { [weak self] in
            self?.gameRunning = false
            self?.playStates.removeAll()
        }
    }

    func set(_ key: String, _ value: String) {
        let statusKey: String
        switch key {
        case "FPS_HUD": statusKey = "fps_hud"
        case "FPS_CAP": statusKey = "fps_cap"
        case "DEBUG": statusKey = "debug"
        case "FAST_SUBMIT": statusKey = "fast_submit"
        case "AVX": statusKey = "avx"
        case "LOW_LATENCY": statusKey = "low_latency"
        case "UNITY_NOLOG": statusKey = "unity_nolog"
        case "CLOSE_STEAM": statusKey = "close_steam"
        case "VSYNC": statusKey = "vsync"
        default: statusKey = key.lowercased()
        }
        status[statusKey] = value
        if key == "GRAPHICS" {
            job(value == "dxvk" ? "Switching to DXVK" : value == "dxmt" ? "Switching to DXMT" : "Switching to Wine's built-in graphics", ["set", key, value])
        } else {
            core(["set", key, value])
        }
    }

    func login(code: String, completion: @escaping (String?) -> Void) {
        var acct: String? = nil
        var message: String? = nil
        core(["epic", "login-code", code], line: { l in
            if l.hasPrefix("ACCOUNT=") { acct = String(l.dropFirst(8)) }
            if l.hasPrefix("That code didn't work") || l.hasPrefix("Epic said:") || l.hasPrefix("FAILED:") {
                message = l
            }
        }, done: { [weak self] code in
            guard let self = self else { return }
            if code == 0, let a = acct {
                self.account = a
                completion(nil)
                let next = self.afterLogin
                self.afterLogin = nil
                self.refresh()
                next?()
            } else {
                completion(message ?? "That didn't work. Get a fresh code and try again.")
            }
        })
    }

    func logout() {
        core(["epic", "logout"], done: { [weak self] _ in
            self?.account = nil
            self?.owned = []
        })
    }

    func requireLogin(then action: @escaping () -> Void) {
        if account != nil { action(); return }
        afterLogin = action
        showLogin = true
    }

    func cancelLogin() {
        afterLogin = nil
        showLogin = false
    }

    // MARK: pictures from Epic's store data (downloaded by legendary)

    func imageURL(for appName: String, tall: Bool = false) -> URL? {
        let key = appName + (tall ? "#tall" : "#wide")
        if let cached = imageCache[key] { return cached }
        let file = Paths.legendaryConfig.appendingPathComponent("metadata/\(appName).json")
        var result: URL? = nil
        if let data = try? Data(contentsOf: file),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let meta = root["metadata"] as? [String: Any],
           let images = meta["keyImages"] as? [[String: Any]] {
            let order = tall
                ? ["DieselGameBoxTall", "OfferImageTall", "Thumbnail", "DieselGameBox"]
                : ["DieselGameBox", "DieselStoreFrontWide", "OfferImageWide", "DieselGameBoxTall", "Thumbnail"]
            for type in order {
                if let img = images.first(where: { ($0["type"] as? String) == type }),
                   let s = img["url"] as? String, let u = URL(string: s) {
                    result = u
                    break
                }
            }
        }
        imageCache[key] = result
        return result
    }
}

/// Splits a stream of bytes into lines (thread-safe).
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(LineReader.clean(chunk))
        }
        return lines
    }

    func finish() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let last = LineReader.clean(buffer)
        buffer.removeAll()
        return [last]
    }

    private static func clean(_ d: Data) -> String {
        String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
    }
}

/// First capture group of `pattern` in `s`.
func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
    return ns.substring(with: m.range(at: 1))
}

func formatBytes(_ n: Int64) -> String {
    n > 0 ? ByteCountFormatter.string(fromByteCount: n, countStyle: .file) : ""
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(contentsOf: Paths.resources.appendingPathComponent("Myskef.icns")) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRequests.add(urls.filter { $0.isFileURL })
    }
}

@main
struct MyskefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = Myskef()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 96 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup("Myskef") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Games") {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Force Quit Windows Programs") { model.forceQuit() }
                Divider()
                Button("Show Activity Log") { model.showLog = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Look

enum SidebarPage: String, CaseIterable, Hashable {
    case library = "Library"
    case epic = "Epic Games"
    case steam = "Steam"
    case programs = "Programs"
    case guide = "Guide"
    case settings = "Settings"
    case tools = "Tools"

    var icon: String {
        switch self {
        case .library: return "square.grid.2x2.fill"
        case .epic: return "bag.fill"
        case .steam: return "cloud.fill"
        case .programs: return "shippingbox.fill"
        case .guide: return "book.fill"
        case .settings: return "gearshape.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        }
    }
}

enum Theme {
    static let orange = Color(red: 1.0, green: 0.52, blue: 0.18)
    static let pink = Color(red: 0.98, green: 0.30, blue: 0.62)
    static let purple = Color(red: 0.55, green: 0.32, blue: 1.0)
    static let background = Color(red: 0.05, green: 0.05, blue: 0.08)
    static let panel = Color.white.opacity(0.05)
    static let panelStroke = Color.white.opacity(0.08)
    static let brand = LinearGradient(colors: [orange, pink, purple],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandHorizontal = LinearGradient(colors: [orange, pink, purple],
                                                startPoint: .leading, endPoint: .trailing)
}

let brandGradient = Theme.brand

/// Dark background with two soft glows in the brand colours.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            GeometryReader { geo in
                ZStack {
                    RadialGradient(colors: [Theme.orange.opacity(0.20), .clear],
                                   center: UnitPoint(x: 0.05, y: 0.0),
                                   startRadius: 0, endRadius: max(geo.size.width, 600) * 0.55)
                    RadialGradient(colors: [Theme.purple.opacity(0.24), .clear],
                                   center: UnitPoint(x: 1.0, y: 1.0),
                                   startRadius: 0, endRadius: max(geo.size.width, 600) * 0.65)
                }
            }
        }
        .drawingGroup()      // drawn once as a flat picture
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Big rounded title used at the top of every page.
struct PageTitle: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

/// The main gradient "Play" style button.
struct GlowButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 17 : 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, large ? 30 : 18)
            .padding(.vertical, large ? 13 : 8)
            .background(Capsule().fill(Theme.brandHorizontal))
            .shadow(color: Theme.pink.opacity(configuration.isPressed ? 0.2 : 0.5), radius: large ? 18 : 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet glassy secondary button.
struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A rounded translucent panel.
struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.panelStroke))
    }
}

// MARK: - Layout

struct ContentView: View {
    @EnvironmentObject var model: Myskef
    @State private var page: SidebarPage = UserDefaults.standard.bool(forKey: "seenGuide") ? .library : .guide

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
                .frame(width: 232)
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                if let u = model.update, !model.updateDismissed {
                    UpdateBanner(info: u)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Group {
                    switch page {
                    case .library: LibraryView(page: $page)
                    case .epic: EpicView()
                    case .steam: SteamView()
                    case .programs: ProgramsView()
                    case .guide: GuideView()
                    case .settings: SettingsView()
                    case .tools: ToolsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(page)
                }

                if model.task != nil {
                    ActivityBar()
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.task != nil)
            .animation(.easeOut(duration: 0.18), value: page)
        }
        .background(AppBackground())
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { Myskef.runnableExtensions.contains($0.pathExtension.lowercased()) }) else {
                model.alert = "Drop a Windows program here: a file ending in .exe, .msi or .bat."
                return false
            }
            page = .programs
            model.runProgram(u, copy: UserDefaults.standard.bool(forKey: "copyPrograms"))
            return true
        }
        .onChange(of: model.openPage) { p in
            if let p = p { page = p; model.openPage = nil }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.pink)
        .sheet(isPresented: $model.showLogin) { LoginSheet().environmentObject(model) }
        .sheet(isPresented: $model.showLog) { LogSheet().environmentObject(model) }
        .sheet(item: $model.settingsGame) { g in GameSettingsSheet(game: g).environmentObject(model) }
        .alert("Myskef", isPresented: Binding(get: { model.alert != nil },
                                               set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { }
            Button("Show details") { model.showLog = true }
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear { model.refresh() }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: Myskef
    @Binding var page: SidebarPage
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarHeader()
                .padding(.top, 38)
                .padding(.bottom, 22)
            ForEach(SidebarPage.allCases, id: \.self) { p in
                SidebarItem(page: p,
                            selected: page == p,
                            badge: p == .library && model.libraryGames.count > 0 ? "\(model.libraryGames.count)" : nil,
                            namespace: selection) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { page = p }
                }
            }
            Spacer()
            Button { model.showLog = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22)
                    Text("Activity log").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.task != nil && model.task?.finished != true {
                        ProgressView().controlSize(.mini)
                    } else if model.task?.failed == true {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                    }
                }
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help("See what Myskef is doing (⇧⌘L)")
            .padding(.bottom, 6)
            if model.gameRunning {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                        .shadow(color: .green, radius: 4)
                    Text("Game running").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Button("Stop") { model.forceQuit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.pink)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.10)))
                .padding(.bottom, 6)
            }
            AccountChip()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
        .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1), alignment: .trailing)
    }
}

struct SidebarItem: View {
    let page: SidebarPage
    let selected: Bool
    let badge: String?
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: page.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                Text(page.rawValue)
                    .font(.system(size: 14, weight: selected ? .bold : .medium, design: .rounded))
                Spacer()
                if let b = badge {
                    Text(b)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.25 : 0.1)))
                }
            }
            .foregroundColor(selected ? .white : .white.opacity(hovering ? 0.9 : 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Theme.brandHorizontal)
                        .shadow(color: Theme.pink.opacity(0.45), radius: 10, y: 3)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 11)
                .fill(Theme.brand)
                .frame(width: 40, height: 40)
                .overlay(
                    Text("M")
                        .font(.system(size: 23, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                )
                .shadow(color: Theme.pink.opacity(0.5), radius: 10, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Myskef")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text("PLAY ANYTHING")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct AccountChip: View {
    @EnvironmentObject var model: Myskef
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(model.account == nil ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(Theme.brand))
                Text(String((model.account ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.account ?? "Not logged in")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("Epic Games").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            if model.account == nil {
                Button("Log in") { model.showLogin = true }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelStroke))
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var model: Myskef
    @Binding var page: SidebarPage
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !model.loadedStatus {
                    HStack { Spacer(); ProgressView("Loading your games…"); Spacer() }.padding(.top, 140)
                } else if !model.isSetUp {
                    Banner(icon: "sparkles", color: Theme.pink,
                           title: "Let's set up Myskef",
                           text: "Myskef downloads the free Wine engine and creates a private Windows space (a “bottle”) for your games. It takes a few minutes, once.",
                           button: "Set up", action: { model.setup() })
                        .padding(.top, 30)
                } else {
                    if !model.engineOK {
                        Banner(icon: "arrow.down.circle.fill", color: Theme.orange,
                               title: "Engine update available",
                               text: "Your Wine engine (\(model.status["engine"] ?? "?")) is too old for newer games: they start but ignore mouse clicks.",
                               button: "Update engine", action: { model.updateEngine() })
                    }
                    if let hero = model.heroGame {
                        HeroBanner(game: hero)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        PageTitle(title: "Your games",
                                  subtitle: model.libraryGames.isEmpty ? "" : "\(model.libraryGames.count) ready to play")
                        Spacer()
                        Button { model.refresh() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    if model.libraryGames.isEmpty {
                        EmptyLibrary(page: $page)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(model.libraryGames) { g in GameCard(game: g) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 110)
        }
    }
}

struct HeroBanner: View {
    @EnvironmentObject var model: Myskef
    let game: Game
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: model.artURL(game), title: "")
                .scaleEffect(hovering ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.6), value: hovering)
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.35), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.65), .clear],
                           startPoint: .leading, endPoint: .center)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Tag(text: model.lastPlayedID == game.id ? "CONTINUE PLAYING" : "FEATURED", filled: true)
                    Tag(text: game.source.rawValue.uppercased(), filled: false)
                }
                Text(game.title)
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !gameInfo.isEmpty {
                    Text(gameInfo)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                HStack(spacing: 12) {
                    PlayButton(game: game, large: true)
                    if model.gameRunning && model.playStates[game.id] == nil {
                        Button("Stop") { model.forceQuit() }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
                .padding(.top, 6)
                if model.gameRunning, let advice = model.health.advice {
                    Label(advice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            .padding(30)
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .onHover { hovering = $0 }
    }

    var gameInfo: String {
        var parts: [String] = []
        if !game.version.isEmpty { parts.append("Version \(game.version)") }
        let size = formatBytes(game.size)
        if !size.isEmpty { parts.append(size) }
        return parts.joined(separator: "  ·  ")
    }
}

struct Tag: View {
    let text: String
    let filled: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(1.2)
            .foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background {
                if filled {
                    Capsule().fill(Theme.brandHorizontal)
                } else {
                    Capsule().fill(Color.black.opacity(0.45))
                }
            }
            .overlay(Capsule().stroke(Color.white.opacity(filled ? 0 : 0.2)))
    }
}

struct Banner: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    let button: String
    let action: () -> Void
    @EnvironmentObject var model: Myskef

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(color.opacity(0.85)))
                .shadow(color: color.opacity(0.6), radius: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text(text).font(.system(size: 13)).foregroundColor(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(GlowButtonStyle())
                .disabled(model.busy)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.35)))
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var model: Myskef
    @Binding var page: SidebarPage
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(Theme.brand)
                .shadow(color: Theme.pink.opacity(0.5), radius: 16)
            Text("No games yet")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
            Text("Download games you own on Epic straight into Myskef, or add Steam.")
                .foregroundColor(.white.opacity(0.6))
            HStack(spacing: 12) {
                Button("Browse my Epic games") { page = .epic }
                    .buttonStyle(GlowButtonStyle())
                Button("Set up Steam") { page = .steam }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.panelStroke))
    }
}

/// Game artwork that always fits exactly the space it's given (cropped to fill).
struct Artwork: View {
    let url: URL?
    let title: String
    var body: some View {
        Theme.brand
            .overlay(
                Text(title)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding()
            )
            .overlay {
                if let url = url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .clipped()
    }
}

struct GameCard: View {
    @EnvironmentObject var model: Myskef
    let game: Game
    @State private var hovering = false
    @State private var confirmRemove = false

    var subtitle: String {
        var parts: [String] = []
        if !game.fullyInstalled { parts.append("Updating in Steam") }
        if !game.version.isEmpty { parts.append("v\(game.version)") }
        let size = formatBytes(game.size)
        if !size.isEmpty { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Artwork(url: model.artURL(game), title: game.title)
                    .scaleEffect(hovering ? 1.07 : 1.0)
                Color.black.opacity(hovering ? 0.35 : 0)
                if hovering && model.playStates[game.id] == nil {
                    Button {
                        model.play(game)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .black))
                            .foregroundColor(.white)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(Theme.brand))
                            .shadow(color: Theme.pink.opacity(0.7), radius: 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 150)
            .clipped()
            .overlay(alignment: .topLeading) {
                Tag(text: game.source.rawValue.uppercased(), filled: false).padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if game.updateAvailable {
                    Tag(text: "UPDATE", filled: true).padding(10)
                }
            }
            .overlay(alignment: .bottom) {
                if model.playStates[game.id] != nil {
                    PlayButton(game: game, compact: true)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                }
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Play") { model.play(game) }
                    Button("Game settings…") { model.settingsGame = game }
                    if game.source == .steam {
                        Button("Open Steam") { model.openSteam() }
                        Button("Show files in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.path)])
                        }
                        Divider()
                        Button("Uninstall in Steam…") { model.uninstallSteamGame(game) }
                    } else {
                        Button("Check for updates") { model.update(game) }
                        Button("Show files in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.path)])
                        }
                        Divider()
                        Button("Remove from Mac…", role: .destructive) { confirmRemove = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.busy)
            }
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(hovering ? 0.08 : 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(hovering ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.panelStroke),
                        lineWidth: hovering ? 2 : 1)
        }
        .shadow(color: hovering ? Theme.pink.opacity(0.35) : .black.opacity(0.3),
                radius: hovering ? 20 : 10, y: hovering ? 10 : 5)
        .scaleEffect(hovering ? 1.025 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .confirmationDialog("Remove \(game.title) from this Mac?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.uninstall(game) }
        } message: {
            Text("You still own it on Epic and can download it again any time. Your game progress is saved to your Ninja Kiwi / Epic account.")
        }
    }
}

// MARK: - Epic Games

struct EpicView: View {
    @EnvironmentObject var model: Myskef
    @State private var search = ""

    var filtered: [Game] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.owned : model.owned.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(title: "Epic Games", subtitle: "Games you own on Epic, downloaded straight into Myskef")
                Spacer()
                if model.account != nil {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button { model.loadOwned() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh")
                        .disabled(model.loadingOwned)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 14)

            if model.account == nil && model.loadedStatus {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 54)).foregroundColor(.secondary)
                    Text("Log in to see your Epic games").font(.title2.weight(.semibold))
                    Text("Myskef downloads games you own straight from Epic. You don't need the Epic Games Launcher.")
                        .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Log in with Epic") { model.requireLogin { model.loadOwned() } }
                        .buttonStyle(GlowButtonStyle(large: true))
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
                Spacer()
            } else if model.loadingOwned && model.owned.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.ownedProgress ?? "Loading your Epic library…").font(.headline)
                    Text("The first time can take a minute or two: Epic sends details for every game you own, including free ones.")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity).padding(.top, 70)
                Spacer()
            } else {
                if model.loadingOwned || model.ownedOffline {
                    HStack(spacing: 8) {
                        if model.loadingOwned { ProgressView().controlSize(.small) }
                        else { Image(systemName: "wifi.exclamationmark").foregroundColor(Theme.orange) }
                        Text(model.loadingOwned ? (model.ownedProgress ?? "Updating your library…")
                                                : "Can't reach Epic right now. Showing your library from last time.")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 32).padding(.bottom, 6)
                }
                List(filtered) { g in
                    OwnedRow(game: g)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 18)
                .padding(.bottom, 90)
            }
        }
        .onAppear {
            // the saved list shows at once; ask Epic again in the background
            if model.account != nil && !model.loadingOwned && (model.owned.isEmpty || !model.ownedRefreshedThisSession) {
                model.ownedRefreshedThisSession = true
                model.loadOwned()
            }
        }
    }
}

struct OwnedRow: View {
    @EnvironmentObject var model: Myskef
    let game: Game
    var installedGame: Game? { model.installed.first { $0.id == game.id } }

    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: model.imageURL(for: game.id, tall: true), title: "")
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline)
                if let ig = installedGame {
                    Text("Installed · version \(ig.version)").font(.caption).foregroundColor(.green)
                } else {
                    Text("Not installed").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let ig = installedGame {
                PlayButton(game: ig)
            } else {
                Button {
                    model.install(game)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .disabled(model.busy)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Steam

struct SteamView: View {
    @EnvironmentObject var model: Myskef

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(title: "Steam", subtitle: "Your Windows Steam games, inside Myskef")
                    Spacer()
                    if model.steamInstalled {
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh")
                        Button {
                            model.openSteam()
                        } label: {
                            Label("Open Steam", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(GlowButtonStyle())
                        .disabled(model.busy)
                    }
                }

                if !model.loadedStatus {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
                } else if !model.steamInstalled {
                    SteamIntro()
                } else {
                    SteamLibraryList()
                }

                if model.steamInstalled {
                    SteamDrawingPicker()
                    SteamTips()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 110)
        }
        .onAppear { model.refresh() }
    }
}

struct SteamIntro: View {
    @EnvironmentObject var model: Myskef
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "cloud.fill").font(.system(size: 40)).foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Play your Windows Steam games").font(.title2.weight(.semibold))
                    Text("Myskef installs the Windows version of Steam into its bottle, next to your Epic games.")
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Step(n: 1, text: "Install Steam (free, about 5 minutes the first time).")
                Step(n: 2, text: "Log in inside Steam's own window. Myskef never sees your Steam password.")
                Step(n: 3, text: "Download games in Steam. They appear in Myskef's Library with a Play button.")
            }
            Button {
                model.installSteam()
            } label: {
                Label("Install Steam", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(GlowButtonStyle(large: true))
            .disabled(model.busy || !model.isSetUp)
            if !model.isSetUp {
                Text("Set up Myskef first (Library page).").font(.caption).foregroundColor(.secondary)
            }
            Text("Tip: if a game also has a Mac version, the regular Mac Steam app runs it faster. Don't stay logged in to both Steams at once, or Steam will log one of them out.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }
}

struct SteamRow: View {
    @EnvironmentObject var model: Myskef
    let game: Game

    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: model.artURL(game), title: "")
                .frame(width: 107, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline)
                Text(game.path.isEmpty ? "Not installed"
                     : (game.fullyInstalled ? formatBytes(game.size) : "Downloading or updating in Steam"))
                    .font(.caption).foregroundColor(game.path.isEmpty ? .secondary : .green)
            }
            Spacer()
            if game.path.isEmpty {
                Button {
                    model.getSteamGame(game)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .disabled(model.busy)
            } else {
                PlayButton(game: game)
            }
        }
        .padding(.vertical, 10)
    }
}

struct SteamLibraryList: View {
    @EnvironmentObject var model: Myskef
    @State private var search = ""

    var rows: [Game] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.steamLibrary
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Steam library").font(.title3.weight(.semibold))
                if model.loadingSteamOwned {
                    ProgressView().controlSize(.small).padding(.leading, 6)
                }
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button { model.loadSteamOwned() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload your Steam library")
                    .disabled(model.loadingSteamOwned)
            }
            if rows.isEmpty {
                Text(model.loadingSteamOwned
                     ? "Loading your Steam library…"
                     : "No games found. Open Steam and log in once; your library shows up here after that.")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { g in
                        SteamRow(game: g)
                        if g.id != rows.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                Text("Install opens Steam's own Install window; Myskef never sees your Steam password.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear {
            if model.steamOwned.isEmpty { model.loadSteamOwned() }
        }
    }
}

struct SteamDrawingPicker: View {
    @EnvironmentObject var model: Myskef
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Steam window drawing", selection: Binding(
                get: { model.status["steam_render"] ?? "gpu" },
                set: { model.setSteamRender($0) })) {
                Text("GPU").tag("gpu")
                Text("Software").tag("software")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .disabled(model.busy)
            Text("If Steam's window stays blank or black, switch to Software. It only changes how Steam's own window is drawn, not your games.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

struct SteamTips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Good to know").font(.headline)
            Text("• Myskef adjusts how Steam draws its window so it shows up under Wine. Your games aren't affected.")
            Text("• The Steam overlay is turned off because it crashes games under Wine.")
            Text("• If Steam's window stays black or stuck, use Force quit (Tools), then open Steam again.")
            Text("• Close Steam to refresh this list after downloading a game, or press the refresh button.")
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Per-game settings

struct GameSettingsSheet: View {
    @EnvironmentObject var model: Myskef
    let game: Game
    @State private var gfx = "default"
    @State private var args = ""

    var globalName: String {
        switch model.status["graphics"] ?? "dxvk" {
        case "dxmt": return "DXMT"
        case "wined3d": return "Wine built-in"
        default: return "DXVK"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Artwork(url: model.artURL(game), title: "")
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title).font(.system(size: 18, weight: .heavy, design: .rounded))
                    Text("Game settings").foregroundColor(.secondary)
                }
            }
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Graphics layer").font(.headline)
                    Picker("", selection: $gfx) {
                        Text("Default (\(globalName))").tag("default")
                        Text("DXMT: DirectX → Metal (fastest, experimental)").tag("dxmt")
                        Text("DXVK: DirectX → Vulkan → Metal (most tested)").tag("dxvk")
                        Text("D3DMetal: Apple's own DirectX → Metal (best for 3D games)").tag("d3dmetal")
                        Text("Wine built-in").tag("wined3d")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    if let info = GraphicsModeInfo.info(gfx == "default" ? (model.status["graphics"] ?? "dxvk") : gfx) {
                        GraphicsModeCard(info: info, compact: true)
                    }
                    Text(game.source == .steam
                         ? "DXVK: Steam starts the game as usual. DXMT or Wine built-in: Myskef starts the game itself while Steam runs in the background. If the game crashes or looks wrong, switch back to DXVK."
                         : "If the game crashes or looks wrong, switch back to DXVK. More in the Guide page.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if gfx == "d3dmetal" {
                        Text(game.source == .steam
                             ? "D3DMetal runs in its own Windows setup with a second copy of Steam (about 230 MB once, plus Steam). It uses the same game files, so nothing is downloaded twice. The first time, sign in to Steam in the window that opens. Launch options from Steam's Properties don't carry over: put them here."
                             : "D3DMetal runs in its own Windows setup (about 230 MB, downloaded once). Your game files stay where they are.")
                            .font(.caption).foregroundColor(Theme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Launch options").font(.headline)
                    TextField("e.g. -force-vulkan", text: $args)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text(game.source == .steam
                         ? "Used when Myskef starts the game (DXMT or Wine built-in). On DXVK, Steam's own launch options apply instead (right-click the game in Steam → Properties)."
                         : "Passed to the game when it starts. Unity games understand -force-vulkan, -force-d3d11, -screen-width 1280 -screen-height 800.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.settingsGame = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setGame(game, gfx: gfx, args: args.trimmingCharacters(in: .whitespaces))
                    model.settingsGame = nil
                }
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 500)
        .onAppear {
            gfx = model.status["GAME_\(game.id)_GFX"] ?? "default"
            if !["default", "dxmt", "dxvk", "wined3d"].contains(gfx) { gfx = "default" }
            args = model.status["GAME_\(game.id)_ARGS"] ?? ""
        }
    }
}

// MARK: - Login

struct LoginSheet: View {
    @EnvironmentObject var model: Myskef
    @State private var code = ""
    @State private var working = false
    @State private var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill").font(.largeTitle).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Log in to Epic Games").font(.title2.weight(.bold))
                    Text("Use the account you bought your games with.").foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Step(n: 1, text: "Open Epic's login page and log in.")
                Button("Open Epic login page") { _ = NSWorkspace.shared.open(epicLoginURL) }
                    .padding(.leading, 30)
                Step(n: 2, text: "You'll see a short page of text. Copy the code after \"authorizationCode\" (or copy the whole page).")
                Step(n: 3, text: "Paste it here:")
                TextField("authorizationCode", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .padding(.leading, 30)
                    .onSubmit(submit)
            }
            if let m = message {
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Codes work once and expire after a few minutes. Your login stays on this Mac only.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Log in") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    func submit() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !working else { return }
        working = true
        message = nil
        model.login(code: c) { err in
            working = false
            if let err = err {
                message = err
                code = ""
            } else {
                model.showLogin = false
            }
        }
    }
}

struct Step: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
                .foregroundColor(.white)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: Myskef
    @State private var confirmReset = false

    var engineText: String {
        guard let e = model.status["engine"] else { return "…" }
        return e == "none" ? "Not installed" : "Wine " + e
    }

    var body: some View {
        Form {
            Section("Graphics") {
                Picker("Graphics layer for all games", selection: Binding(
                    get: { model.status["graphics"] ?? "dxvk" },
                    set: { model.set("GRAPHICS", $0) })) {
                    Text("DXVK: DirectX → Vulkan → Metal (most tested)").tag("dxvk")
                    Text("DXMT: DirectX 11 → Metal (fewer steps, experimental)").tag("dxmt")
                    Text("Wine built-in: DirectX → OpenGL (last resort)").tag("wined3d")
                }
                .disabled(model.busy)
                if let info = GraphicsModeInfo.info(model.status["graphics"] ?? "dxvk") {
                    GraphicsModeCard(info: info, compact: true)
                }
                Text("Used by every game set to “Default”. Each game can pick its own (including Apple's D3DMetal) in its ⋯ menu → Game settings. Steam's own window always uses DXVK. The Guide page compares them all.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Speed") {
                ExplainedToggle(title: "Close Steam when you play an Epic game",
                                text: "Steam's window is a full web browser. If it's only sitting in the background, closing it gives the game more memory.",
                                isOn: Binding(get: { model.status["close_steam"] != "off" },
                                              set: { model.set("CLOSE_STEAM", $0 ? "on" : "off") }))
                ExplainedToggle(title: "Turn off Unity games' own log",
                                text: "Unity games like BTD6 and Raft can write thousands of warnings to a file; skipping that keeps long sessions smoother.",
                                isOn: Binding(get: { model.status["unity_nolog"] != "off" },
                                              set: { model.set("UNITY_NOLOG", $0 ? "on" : "off") }))
                ExplainedToggle(title: "Faster frame hand-off to Metal",
                                text: "Sends finished frames on without waiting. Turn off only if a game flickers.",
                                isOn: Binding(get: { model.status["fast_submit"] != "off" },
                                              set: { model.set("FAST_SUBMIT", $0 ? "on" : "off") }))
                Picker(selection: Binding(
                    get: { model.status["fps_cap"] ?? "off" },
                    set: { model.set("FPS_CAP", $0) })) {
                    Text("Off").tag("off")
                    Text("60 FPS").tag("60")
                    Text("30 FPS").tag("30")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frame-rate cap")
                        Text("A cap keeps a MacBook cooler, so it doesn't slow itself down in long sessions.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Section("Responsiveness") {
                ExplainedToggle(title: "Low input delay",
                                text: "Stops games preparing frames ahead of time, so your clicks show up sooner.",
                                isOn: Binding(get: { model.status["low_latency"] != "off" },
                                              set: { model.set("LOW_LATENCY", $0 ? "on" : "off") }))
                ExplainedToggle(title: "Force VSync off",
                                text: "Shows each frame right away instead of waiting for the screen. Lowest delay, but you may see tearing lines.",
                                isOn: Binding(get: { model.status["vsync"] == "off" },
                                              set: { model.set("VSYNC", $0 ? "off" : "game") }))
                Text("These two and the frame cap work for DirectX games on DXVK (not DXMT, and not Unity games started with -force-vulkan). Changes apply the next time a game starts; for Steam games, quit Steam first.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Extras") {
                ExplainedToggle(title: "Show FPS counter in games",
                                text: "Apple's Metal HUD in the corner of the game: frames per second and how busy the graphics chip is.",
                                isOn: Binding(get: { model.status["fps_hud"] == "on" },
                                              set: { model.set("FPS_HUD", $0 ? "on" : "off") }))
                ExplainedToggle(title: "Tell games the processor supports AVX",
                                text: "Only for the rare game that refuses to start without AVX. Leave off otherwise.",
                                isOn: Binding(get: { model.status["avx"] == "on" },
                                              set: { model.set("AVX", $0 ? "on" : "off") }))
            }

            Section("Engine") {
                LabeledContent("Wine engine") {
                    HStack {
                        Text(engineText)
                        if model.loadedStatus && model.status["engine"] != "none" {
                            Image(systemName: model.engineOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(model.engineOK ? .green : .orange)
                        }
                    }
                }
                if model.loadedStatus && !model.engineOK && model.status["engine"] != "none" {
                    Button("Update engine") { model.updateEngine() }.disabled(model.busy)
                }
                Button("Set up / repair Myskef") { model.setup() }.disabled(model.busy)
            }

            Section("Epic Games account") {
                LabeledContent("Logged in as", value: model.account ?? "Not logged in")
                if model.account != nil {
                    Button("Log out") { model.logout() }
                } else {
                    Button("Log in") { model.showLogin = true }
                }
            }

            Section("Troubleshooting") {
                ExplainedToggle(title: "Detailed logging",
                                text: "Records much more in the activity log, to find out why a game crashes. Slows games down: turn it off afterwards.",
                                isOn: Binding(get: { model.status["debug"] == "on" },
                                              set: { model.set("DEBUG", $0 ? "on" : "off") }))
                Button("Show activity log") { model.showLog = true }
                Button("Open full log file") { _ = NSWorkspace.shared.open(Paths.log) }
                Button("Reset bottle…", role: .destructive) { confirmReset = true }
                    .disabled(model.busy)
            }

            Section("About") {
                LabeledContent("Myskef", value: model.status["version"] ?? "")
                if model.updatesConfigured {
                    ExplainedToggle(title: "Check for updates automatically",
                                    text: "Myskef looks for a new version when it opens and every few hours, and asks before installing.",
                                    isOn: Binding(get: { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true },
                                                  set: { UserDefaults.standard.set($0, forKey: "autoUpdateCheck"); model.objectWillChange.send() }))
                    HStack {
                        Button("Check for updates now") { model.checkForUpdates(manual: true) }
                        if let u = model.update {
                            Button("Install \(u.version)") { model.installUpdate() }
                                .disabled(model.busy || model.gameRunning)
                        }
                    }
                }
                Text("Built with free software: Wine (LGPL), Gcenx's macOS Wine builds, DXVK-macOS (zlib), DXMT (LGPL), MoltenVK (Apache 2.0), legendary (GPL-3.0) and, if you choose it, Apple's D3DMetal (Apple's licence). Myskef isn't affiliated with Apple, Epic Games, Valve or any game studio.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 18)
        .padding(.bottom, 80)
        .confirmationDialog("Reset the bottle?", isPresented: $confirmReset) {
            Button("Delete bottle", role: .destructive) {
                model.job("Resetting the bottle", ["reset-bottle"])
            }
        } message: {
            Text("This deletes Myskef's Windows space, including the Epic launcher and every downloaded game. Game progress saved to your accounts isn't affected.")
        }
    }
}

// MARK: - Tools

struct ToolsView: View {
    @EnvironmentObject var model: Myskef
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(title: "Tools", subtitle: "Extra controls for Myskef's Windows bottle")
                LazyVGrid(columns: columns, spacing: 16) {
                    ToolTile(icon: "square.and.arrow.up", title: "Share Myskef with friends",
                             text: "Make a zip with the app and a read-me. No games, accounts or settings are included.") {
                        model.shareMyskef()
                    }
                    ToolTile(icon: "app.badge", title: "Run a Windows program",
                             text: "Open any .exe or .msi with Myskef.") {
                        model.chooseProgram(copy: UserDefaults.standard.bool(forKey: "copyPrograms"))
                    }
                    ToolTile(icon: "bag", title: "Epic Games Launcher",
                             text: "Open Epic's own launcher (not needed to play).") {
                        model.job("Opening the Epic Games Launcher", ["open-epic"])
                    }
                    ToolTile(icon: "slider.horizontal.3", title: "Wine settings",
                             text: "Windows version, audio, drives (winecfg).") {
                        model.job("Opening Wine settings", ["winecfg"])
                    }
                    ToolTile(icon: "internaldrive", title: "Open C: drive",
                             text: "See the bottle's files in Finder.") {
                        model.core(["open-c"])
                    }
                    ToolTile(icon: "xmark.octagon", title: "Force quit",
                             text: "Close every Windows program in Myskef.") { model.forceQuit() }
                    ToolTile(icon: "puzzlepiece.extension", title: "Fix Epic Online Services",
                             text: "Fixes the purple banner in the Epic launcher.") {
                        model.job("Fixing Epic Online Services", ["fix-eos"])
                    }
                    ToolTile(icon: "doc.text.magnifyingglass", title: "Activity log",
                             text: "See what Myskef has been doing.") { model.showLog = true }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 110)
        }
    }
}

// MARK: - Programs (.exe / .msi)

struct ProgramsView: View {
    @EnvironmentObject var model: Myskef
    @AppStorage("copyPrograms") private var copyFirst = false
    @State private var targeted = false

    var recent: [String] {
        model.recentPrograms.filter { FileManager.default.fileExists(atPath: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "Programs", subtitle: "Run any Windows .exe or .msi on your Mac")

                // drop zone
                Button { model.chooseProgram(copy: copyFirst) } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.on.square.fill")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(Theme.brand)
                        Text(targeted ? "Drop to run it" : "Drop an .exe or .msi here")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                        Text("or click to choose a file. Installers (.msi or setup .exe) install the program into Myskef; it then shows up below.")
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                    .background(RoundedRectangle(cornerRadius: 22).fill(targeted ? Theme.pink.opacity(0.12) : Theme.panel))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(targeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white.opacity(0.18)),
                                          style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first else { return false }
                    model.runProgram(u, copy: copyFirst)
                    return true
                } isTargeted: { targeted = $0 }

                Toggle(isOn: $copyFirst) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep a copy inside Myskef")
                        Text("Copies the file into C:\\Myskef Uploads before running it, so it keeps working after you delete the download. Leave this off for programs that need the other files in their folder.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if !model.programs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Installed programs").font(.title3.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(model.programs) { p in
                                ProgramRow(name: p.name, detail: p.path.hasSuffix(".lnk") || p.path.hasSuffix(".LNK") ? "Installed in Myskef" : "Kept in Myskef",
                                           icon: "app.fill") {
                                    model.runProgram(URL(fileURLWithPath: p.path))
                                }
                                if p.id != model.programs.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    }
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recently run").font(.title3.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(recent, id: \.self) { path in
                                let url = URL(fileURLWithPath: path)
                                ProgramRow(name: url.deletingPathExtension().lastPathComponent,
                                           detail: url.deletingLastPathComponent().path
                                               .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                           icon: url.pathExtension.lowercased() == "msi" ? "shippingbox" : "terminal",
                                           onForget: { model.forget(path) },
                                           onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                                    model.runProgram(url)
                                }
                                if path != recent.last { Divider() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    }
                }

                Text("Programs use the graphics layer from Settings. Tip: in Finder you can also right-click an .exe → Open With → Myskef, or drop it on Myskef's window.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 110)
        }
        .onAppear { model.loadPrograms() }
        .onChange(of: model.gameRunning) { _ in model.loadPrograms() }
    }
}

struct ProgramRow: View {
    @EnvironmentObject var model: Myskef
    let name: String
    let detail: String
    let icon: String
    var onForget: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil
    let run: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.brand))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline).lineLimit(1)
                Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if onReveal != nil || onForget != nil {
                Menu {
                    if let r = onReveal { Button("Show in Finder", action: r) }
                    if let f = onForget { Button("Remove from list", action: f) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
            Button("Run", action: run)
                .buttonStyle(GlowButtonStyle())
                .disabled(model.busy)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Guide

struct GuideView: View {
    @EnvironmentObject var model: Myskef

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(title: "Guide", subtitle: "How Myskef works, and how to get the most out of it")

                Group {
                GuideSection(icon: "sparkles", title: "What Myskef does") {
                    Text("Windows games are made for Windows and for Intel processors. Myskef runs them on your Mac by putting three translators between the game and your Mac:")
                    ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        GuideChip(text: "Game (.exe)")
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        GuideChip(text: "Wine: Windows → macOS")
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        GuideChip(text: "Rosetta 2: Intel → Apple chip")
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        GuideChip(text: "Graphics layer: DirectX → Metal")
                    }
                    }
                    Text("Everything lives in a private “Windows bottle” inside your Library folder, so it never touches the rest of your Mac. Translation costs some speed: a game won't run quite as fast as a native Mac version would, and games that are heavy on the processor feel it most.")
                }

                GuideSection(icon: "play.circle.fill", title: "Getting started") {
                    GuideStep(n: 1, text: "Myskef downloads what it needs the first time (the Wine engine, about 1 GB). If something is missing later, use Settings → Set up / repair Myskef.")
                    GuideStep(n: 2, text: "Epic Games: click Log in, sign in on Epic's website, and paste the code it shows. Then download a game and press Play.")
                    GuideStep(n: 3, text: "Steam: click Install Steam and sign in inside Steam's own window. Install games in Steam or from Myskef's Steam list, then press Play.")
                    GuideStep(n: 4, text: "Anything else: drag an .exe or .msi file onto Myskef (Programs page). Programs that an installer adds appear there too.")
                }

                GuideSection(icon: "cpu", title: "Graphics layers: which one to pick") {
                    Text("Games draw with Microsoft's DirectX; Macs only understand Apple's Metal. A graphics layer translates between them. You choose one in Settings (for every game) or per game in its ⋯ menu → Game settings.")
                    ForEach(GraphicsModeInfo.all) { info in GraphicsModeCard(info: info) }
                    Text("Rule of thumb: start with DXVK. If a game is slow, try DXMT; for big 3D games, try D3DMetal. If a game crashes or looks wrong, switch back to DXVK. Turn on the FPS counter in Settings to compare.")
                        .font(.callout.weight(.semibold))
                }

                GuideSection(icon: "circle.dashed", title: "What the Play button tells you") {
                    GuideRow(color: Theme.orange, title: "Starting…", text: "Myskef is getting the game ready. The small line shows the current step.")
                    GuideRow(color: Theme.orange, title: "Opening the game…", text: "The game has been started; its window can take up to a minute to appear.")
                    GuideRow(color: .green, title: "Running", text: "The game is open. Stop closes it. If the dot turns orange, your Mac is hot, out of memory or in Low Power Mode: hover for what to do.")
                    GuideRow(color: .red, title: "Didn't start", text: "Shows why. Log opens the activity log, Retry tries again.")
                }

                }
                Group {
                GuideSection(icon: "slider.horizontal.3", title: "The settings, in plain words") {
                    GuideTerm(title: "FPS counter", text: "Shows frames per second in the corner of the game. Higher is smoother.")
                    GuideTerm(title: "Frame-rate cap", text: "Stops the game going above 30 or 60 FPS. Keeps a MacBook cooler, so it doesn't slow itself down in long sessions.")
                    GuideTerm(title: "Low input delay", text: "Stops games preparing frames ahead of time, so clicks show up sooner.")
                    GuideTerm(title: "Force VSync off", text: "Shows each frame immediately instead of waiting for the screen. Lowest delay, but you may see tearing lines.")
                    GuideTerm(title: "Unity games' own log off", text: "Unity games (BTD6, Raft…) can write thousands of warnings to a file. Skipping that keeps long sessions smoother.")
                    GuideTerm(title: "Close Steam for Epic games", text: "Steam's window is a full web browser. If it's only sitting in the background, Myskef closes it when you start an Epic game, so the game gets that memory.")
                    GuideTerm(title: "Faster frame hand-off", text: "Sends finished frames to Metal without waiting. Turn off only if a game flickers.")
                    GuideTerm(title: "AVX", text: "Only for the rare game that refuses to start on processors without AVX. Leave off otherwise.")
                    GuideTerm(title: "Launch options", text: "Extra words passed to a game when it starts, set per game. For Unity games: -force-vulkan, -force-d3d11, -screen-width 1280 -screen-height 800.")
                }

                GuideSection(icon: "speedometer", title: "Getting more FPS") {
                    GuideStep(n: 1, text: "Plug your Mac in and turn off Low Power Mode.")
                    GuideStep(n: 2, text: "Close Chrome and other heavy apps. Windows games plus translation need a lot of memory.")
                    GuideStep(n: 3, text: "Lower the game's resolution and graphics settings. Fewer pixels is the biggest win.")
                    GuideStep(n: 4, text: "Try another graphics layer (above) and compare with the FPS counter.")
                    GuideStep(n: 5, text: "If a game gets slower over a long session, restart it: that clears memory that builds up.")
                }

                GuideSection(icon: "wrench.and.screwdriver.fill", title: "If something goes wrong") {
                    GuideTerm(title: "A game won't start", text: "Look at the reason on its Play button and in the activity log (bottom of the sidebar, ⇧⌘L). Then try another graphics layer.")
                    GuideTerm(title: "“Epic isn't reachable”", text: "Your network is blocking or slowing Epic (common on school or public Wi-Fi, or with a VPN). Myskef starts the game offline instead; try another network for online features.")
                    GuideTerm(title: "Steam's window is black", text: "In the Steam page, switch Steam's drawing to Software and reopen Steam.")
                    GuideTerm(title: "Clicks don't work in a game", text: "Settings → Update engine. Newer Wine versions fix this for Unity games.")
                    GuideTerm(title: "The window didn't build", text: "Myskef falls back to a simple menu. Click Copy error and send it to whoever gave you Myskef.")
                    GuideTerm(title: "Start over", text: "Settings → Reset bottle deletes the Windows space and its games. Your game progress saved online isn't affected.")
                }

                GuideSection(icon: "internaldrive.fill", title: "Storage") {
                    Text("Everything is in ~/Library/Application Support/Myskef: the engine (about 1 GB), the Windows bottle and every downloaded game. Uninstall games inside Myskef to free space. Deleting the Myskef app does not delete that folder: delete it too to remove everything.")
                    Button("Show the Myskef folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.log.deletingLastPathComponent().deletingLastPathComponent()])
                    }
                    .buttonStyle(GlassButtonStyle())
                }

                GuideSection(icon: "lock.fill", title: "Your accounts and privacy") {
                    Text("Myskef never sees your Steam password: you sign in inside Steam's own window. For Epic you sign in on Epic's website and paste a one-time code. Both sign-ins stay on your Mac. Myskef only talks to Epic, Steam and the sites it downloads its parts from.")
                }

                GuideSection(icon: "heart.fill", title: "Made from free software") {
                    Text("Wine (LGPL), Gcenx's macOS Wine builds, DXVK (zlib), DXMT (LGPL), MoltenVK (Apache 2.0), legendary (GPL-3.0) and, if you choose it, Apple's D3DMetal (Apple's licence). Myskef isn't affiliated with Apple, Epic Games, Valve or any game studio; you need to own the games you play.")
                }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 110)
        }
        .onAppear { UserDefaults.standard.set(true, forKey: "seenGuide") }
    }
}

struct GuideSection<Content: View>: View {
    let icon: String
    let title: String
    let content: Content
    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon; self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
    }
}

struct GuideChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .fixedSize()
    }
}

struct GuideStep: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.brand))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GuideRow: View {
    let color: Color
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
            (Text(title).bold() + Text("  " + text).foregroundColor(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GuideTerm: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(text).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ToolTile: View {
    @EnvironmentObject var model: Myskef
    let icon: String
    let title: String
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Theme.brand))
                    .shadow(color: Theme.pink.opacity(hovering ? 0.6 : 0.25), radius: hovering ? 12 : 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.white)
                    Text(text).font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(hovering ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(hovering ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.panelStroke), lineWidth: hovering ? 1.5 : 1))
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Activity bar & log

/// Play button that turns into the game's status after you press it:
/// Starting… → Opening… → Running (with Stop), or "Didn't start" with the reason.
struct PlayButton: View {
    @EnvironmentObject var model: Myskef
    let game: Game
    var large = false
    var compact = false     // small spaces (game cards): icons instead of words

    var body: some View {
        switch model.playStates[game.id] {
        case .starting(let detail)?:
            StatusPill(color: Theme.orange, spinner: true, title: "Starting…", detail: detail, large: large)
                .onTapGesture { model.showLog = true }
                .help("Click to see the activity log")
        case .opening?:
            StatusPill(color: Theme.orange, spinner: true, title: "Opening the game…",
                       detail: "The window can take up to a minute", large: large)
                .onTapGesture { model.showLog = true }
                .help("Click to see the activity log")
        case .running?:
            HStack(spacing: 8) {
                StatusPill(color: model.health.short == nil ? .green : Theme.orange, spinner: false, title: "Running",
                           detail: model.health.short ?? (compact ? nil : "Playing now"), large: large)
                    .help(model.health.advice ?? "The game is running.")
                Button { model.forceQuit() } label: {
                    if compact { Image(systemName: "stop.fill") } else { Text("Stop") }
                }
                .buttonStyle(GlassButtonStyle())
                .help("Close the game (and every other Windows program in Myskef)")
            }
        case .failed(let why)?:
            HStack(spacing: 8) {
                StatusPill(color: .red, spinner: false, title: "Didn't start", detail: compact ? "Click for the log" : why, large: large)
                    .onTapGesture { model.showLog = true }
                    .help(why + "\nClick to see the activity log.")
                if !compact {
                    Button("Log") { model.showLog = true }
                        .buttonStyle(GlassButtonStyle())
                }
                Button { model.play(game) } label: {
                    if compact { Image(systemName: "arrow.clockwise") } else { Label("Retry", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(GlowButtonStyle(large: false))
                .disabled(model.busy)
                .help("Try again")
            }
        case nil:
            Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(GlowButtonStyle(large: large))
                .disabled(model.busy)
        }
    }
}

struct StatusPill: View {
    let color: Color
    let spinner: Bool
    let title: String
    let detail: String?
    var large = false

    var body: some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(color).frame(width: 9, height: 9).shadow(color: color, radius: 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: large ? 15 : 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                if let d = detail, !d.isEmpty {
                    Text(d)
                        .font(.system(size: large ? 11 : 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, large ? 16 : 12)
        .padding(.vertical, large ? 10 : 6)
        .frame(maxWidth: large ? 360 : 240, alignment: .leading)
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// "A new Myskef is available" — shown at the top of every page until updated or dismissed.
struct UpdateBanner: View {
    @EnvironmentObject var model: Myskef
    @State private var showNotes = false
    let info: UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Myskef \(info.version) is available").font(.headline)
                    Text("You have \(model.status["version"] ?? "an older version"). Updating takes a few seconds; your games and settings stay.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !info.notes.isEmpty {
                    Button(showNotes ? "Hide changes" : "What's new") { showNotes.toggle() }
                        .buttonStyle(GlassButtonStyle())
                }
                Button("Later") { model.updateDismissed = true }
                    .buttonStyle(GlassButtonStyle())
                Button("Update now") { model.installUpdate() }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(model.busy || model.gameRunning)
                    .help(model.gameRunning ? "Close your game first" : "Download and install the update")
            }
            if showNotes {
                ScrollView {
                    Text(info.notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.pink.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }
}

struct ActivityBar: View {
    @EnvironmentObject var model: Myskef

    var body: some View {
        if let t = model.task {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(t.finished ? AnyShapeStyle(t.failed ? Color.red : Color.green) : AnyShapeStyle(Theme.brand))
                        .frame(width: 34, height: 34)
                    if t.finished {
                        Image(systemName: t.failed ? "xmark" : "checkmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.white)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(t.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    if let p = t.progress, !t.finished {
                        GradientProgress(value: p).frame(width: 300, height: 6)
                    }
                    Text(t.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Button("Details") { model.showLog = true }
                    .buttonStyle(GlassButtonStyle())
                if t.finished {
                    Button { model.task = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 620)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .padding(.horizontal, 24)
        }
    }
}

struct GradientProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Theme.brandHorizontal)
                    .frame(width: max(6, geo.size.width * CGFloat(min(max(value, 0), 1))))
                    .shadow(color: Theme.pink.opacity(0.6), radius: 6)
                    .animation(.easeOut(duration: 0.4), value: value)
            }
        }
    }
}

struct LogSheet: View {
    @EnvironmentObject var model: Myskef
    @ObservedObject private var store = LogStore.shared
    @AppStorage("logHideRoutine") private var hideRoutine = true
    @State private var follow = true
    @State private var search = ""

    var shown: [LogLine] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.lines.filter { l in
            (!hideRoutine || !l.routine || l.text.hasPrefix("ERROR")) &&
            (q.isEmpty || l.text.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity log").font(.headline)
                if let t = model.task {
                    HStack(spacing: 6) {
                        if !t.finished { ProgressView().controlSize(.mini) }
                        Text(t.finished ? (t.failed ? "Failed: \(t.title)" : "Done: \(t.title)") : "\(t.title): \(t.detail)")
                            .font(.caption).foregroundColor(t.failed ? .red : .secondary).lineLimit(1)
                    }
                }
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 150)
                Toggle("Hide background checks", isOn: $hideRoutine).toggleStyle(.checkbox)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                    .help("Keep scrolling to the newest line")
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map { $0.text }.joined(separator: "\n"), forType: .string)
                }
                Button("Open log file") { _ = NSWorkspace.shared.open(Paths.log) }
                Button("Close") { model.showLog = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { l in
                            Text(verbatim: l.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(l.text.hasPrefix("ERROR") || l.text.hasPrefix("FAILED") ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(l.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: store.lines.count) { _ in
                    if follow, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 520)
    }
}

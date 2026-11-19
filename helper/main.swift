// OPEN_UP — a Spotlight-style "open with…" picker for macOS.
//
// One self-contained app. It receives files from macOS (double-click / `open -a`),
// ranks apps for the file type (your rules → past picks → macOS suggestions), shows
// the bundled picker page in a floating borderless window, and launches what you pick.
//
// The UI is HTML in Contents/Resources/ui, served through a private `openup://`
// URL scheme. Pages reach the app's data through a message bridge, not the network:
// nothing listens on a port.
//
// Run with no files → settings window.
// CLI: OpenUp --set-default md pdf ...   make OPEN_UP the default for those types
//      OpenUp --snapshot pick|settings out.png   render a page to PNG (for development)

import Cocoa
import UniformTypeIdentifiers
import WebKit

func displayName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

func normExt(_ s: String?) -> String {
    var e = (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    while e.hasPrefix(".") { e.removeFirst() }
    return e.isEmpty ? "(none)" : e
}

func extOf(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension
    return name.hasPrefix(".") && !name.dropFirst().contains(".") ? "(none)" : normExt(ext)
}

func jsonString(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: - state (rules, learned picks, app index)

struct AppInfo: Codable { var name: String; var bundleId: String? }
struct Pick: Codable { var count: Int; var last: Double }

struct State: Codable {
    var apps: [String: AppInfo] = [:]       // app path -> info
    var rules: [String: [String]] = [:]     // ext -> ranked app paths ("*" = any type)
    var picks: [String: [String: Pick]] = [:] // ext -> app path -> pick stats
    var learn = true

    enum CodingKeys: String, CodingKey { case apps, rules, picks, settings }
    struct Settings: Codable { var learn: Bool? }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        apps = (try? c.decodeIfPresent([String: AppInfo].self, forKey: .apps)) ?? [:]
        rules = (try? c.decodeIfPresent([String: [String]].self, forKey: .rules)) ?? [:]
        picks = (try? c.decodeIfPresent([String: [String: Pick]].self, forKey: .picks)) ?? [:]
        learn = (try? c.decodeIfPresent(Settings.self, forKey: .settings))?.learn ?? true
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(apps, forKey: .apps)
        try c.encode(rules, forKey: .rules)
        try c.encode(picks, forKey: .picks)
        try c.encode(Settings(learn: learn), forKey: .settings)
    }
}

struct Session { let files: [String]; let ext: String; let candidates: [[String: String]] }

final class Store {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OPEN_UP", isDirectory: true)
    static let file = dir.appendingPathComponent("state.json")

    var state = State()
    var sessions: [String: Session] = [:]

    init() {
        if let data = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) { try? data.write(to: Self.file, options: .atomic) }
    }

    func name(_ path: String, _ fallback: String? = nil) -> String {
        if let n = state.apps[path]?.name, !n.isEmpty { return n }
        return fallback ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Score apps for an extension. Same formula as before:
    /// rule #i = 1000 - 10i (any-type rules 400 - 10i), each past pick 5 (+3 if in the last week),
    /// macOS suggestion 1–2 (macOS lists better handlers first).
    func rank(_ ext: String, _ candidates: [[String: String]]) -> (ranked: [[String: Any]], others: [[String: Any]]) {
        var score: [String: Double] = [:]
        var reasons: [String: [String]] = [:]
        var names: [String: String] = [:]
        for c in candidates { if let p = c["path"] { names[p] = c["name"] } }
        func bump(_ p: String, _ pts: Double, _ why: String) { score[p, default: 0] += pts; reasons[p, default: []].append(why) }

        for (scope, label, base) in [(ext, "rule", 1000.0), ("*", "any-type rule", 400.0)] {
            for (i, p) in (state.rules[scope] ?? []).enumerated() { bump(p, base - Double(i) * 10, "\(label) #\(i + 1)") }
        }
        if state.learn {
            let now = Date().timeIntervalSince1970
            for (p, pk) in state.picks[ext] ?? [:] {
                var pts = Double(pk.count) * 5
                if now - pk.last < 7 * 86400 { pts += 3 }
                if pts > 0 { bump(p, pts, "used \(pk.count)x") }
            }
        }
        let n = Double(max(candidates.count, 1))
        for (i, c) in candidates.enumerated() { if let p = c["path"] { bump(p, 1 + (n - Double(i)) / n, "macOS") } }

        let ranked = score.keys.sorted {
            score[$0]! != score[$1]! ? score[$0]! > score[$1]! : name($0, names[$0]).lowercased() < name($1, names[$1]).lowercased()
        }.map { p -> [String: Any] in
            ["path": p, "name": name(p, names[p]), "score": (score[p]! * 100).rounded() / 100, "reasons": reasons[p]!]
        }
        let others = state.apps.filter { score[$0.key] == nil }
            .map { ["path": $0.key, "name": $0.value.name] as [String: Any] }
            .sorted { ($0["name"] as! String).lowercased() < ($1["name"] as! String).lowercased() }
        return (ranked, others)
    }

    func newSession(files: [String], candidates: [[String: String]]) -> String {
        if sessions.count > 50 { sessions.removeAll() }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        sessions[id] = Session(files: files, ext: extOf(files[0]), candidates: candidates)
        return id
    }

    func recordPick(ext: String, app: String, always: Bool) {
        var pk = state.picks[ext]?[app] ?? Pick(count: 0, last: 0)
        if state.learn { pk.count += 1 }
        pk.last = Date().timeIntervalSince1970
        state.picks[ext, default: [:]][app] = pk
        if always { state.rules[ext] = [app] + (state.rules[ext] ?? []).filter { $0 != app } }
        save()
    }

    /// The pages' `/api/...` calls land here. Returns (status, JSON object).
    func api(method: String, path: String, body: [String: Any]) -> (Int, Any) {
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        // parts: ["api", route, arg?]
        guard parts.first == "api", parts.count >= 2 else { return (404, ["error": "not found"]) }
        let route = parts[1], arg = parts.count > 2 ? parts[2] : nil

        switch (method, route) {
        case ("GET", "state"):
            let data = (try? JSONEncoder().encode(state)) ?? Data("{}".utf8)
            return (200, (try? JSONSerialization.jsonObject(with: data)) ?? [:])
        case ("GET", "session"):
            guard let id = arg, let s = sessions[id] else { return (404, ["error": "session expired"]) }
            let r = rank(s.ext, s.candidates)
            return (200, ["id": id, "ext": s.ext, "files": s.files, "ranked": r.ranked, "others": r.others])
        case ("GET", "rank"):
            let ext = normExt(arg)
            return (200, ["ext": ext, "ranked": rank(ext, []).ranked])
        case ("POST", "pick"):
            guard let app = body["app"] as? String, app.hasSuffix(".app") else { return (400, ["error": "bad app"]) }
            recordPick(ext: normExt(body["ext"] as? String), app: app, always: body["always"] as? Bool ?? false)
            return (200, ["ok": true])
        case ("POST", "rules"):
            let raw = body["ext"] as? String
            let ext = raw == "*" ? "*" : normExt(raw)
            let apps = (body["apps"] as? [Any] ?? []).compactMap { $0 as? String }.filter { $0.hasSuffix(".app") }
            if apps.isEmpty { state.rules.removeValue(forKey: ext) } else { state.rules[ext] = apps }
            save()
            return (200, ["ok": true])
        case ("POST", "picks"):  // /api/picks/reset
            if let e = body["ext"] as? String, !e.isEmpty { state.picks.removeValue(forKey: normExt(e)) } else { state.picks = [:] }
            save()
            return (200, ["ok": true])
        case ("POST", "settings"):
            if let l = body["learn"] as? Bool { state.learn = l }
            save()
            return (200, ["ok": true])
        default:
            return (404, ["error": "not found"])
        }
    }
}

let store = Store()

// MARK: - app index and macOS suggestions

func scanApps() -> [String: AppInfo] {
    let fm = FileManager.default
    let roots = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]
    var out: [String: AppInfo] = [:]
    let myID = Bundle.main.bundleIdentifier

    func visit(_ dir: String, depth: Int) {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for item in items where !item.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(item)
            if item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard out[url.path] == nil else { continue }
                let bid = Bundle(url: url)?.bundleIdentifier
                if bid == myID { continue }
                out[url.path] = AppInfo(name: displayName(url), bundleId: bid)
            } else if depth > 0 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: depth - 1) }
            }
        }
    }
    for r in roots { visit(r, depth: 1) }
    return out
}

func candidates(for file: URL) -> [[String: String]] {
    let me = Bundle.main.bundleURL.standardizedFileURL.path
    var seen = Set<String>()
    return NSWorkspace.shared.urlsForApplications(toOpen: file).compactMap { url in
        let p = url.standardizedFileURL.path
        guard p != me, Bundle(url: url)?.bundleIdentifier != Bundle.main.bundleIdentifier, !seen.contains(p) else { return nil }
        seen.insert(p)
        return ["path": p, "name": displayName(url)]
    }
}

func setDefault(ext: String, done: @escaping (String) -> Void) {
    guard let type = UTType(filenameExtension: ext), !type.isDynamic else {
        done("macOS has no registered type for .\(ext), so it can't have a default app.")
        return
    }
    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { err in
        DispatchQueue.main.async {
            done(err.map { "Failed for .\(ext): \($0.localizedDescription)" } ?? "OPEN_UP is now the default for .\(ext)")
        }
    }
}

// MARK: - bundled UI

/// Serves Contents/Resources/ui over openup://app/...
final class UIScheme: NSObject, WKURLSchemeHandler {
    static let pages = ["/": "settings.html", "/settings": "settings.html", "/pick": "pick.html"]
    static let mimes = ["html": "text/html", "css": "text/css", "otf": "font/otf", "woff2": "font/woff2"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let ui = Bundle.main.resourceURL?.appendingPathComponent("ui", isDirectory: true).standardizedFileURL else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = url.path.isEmpty ? "/" : url.path
        let name = Self.pages[path] ?? String(path.dropFirst())
        let file = ui.appendingPathComponent(name).standardizedFileURL
        // Only files inside Contents/Resources/ui, of the types above.
        guard file.path.hasPrefix(ui.path + "/"), let mime = Self.mimes[file.pathExtension.lowercased()],
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                    textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Routes the pages' fetch("/api/...") calls to the app instead of the network.
let fetchShim = """
(() => {
  const real = window.fetch.bind(window);
  window.fetch = async (input, opts = {}) => {
    const url = typeof input === "string" ? input : input.url;
    const path = url.replace(/^openup:\\/\\/app/, "");
    if (!path.startsWith("/api/")) return real(input, opts);
    const out = await window.webkit.messageHandlers.api.postMessage({
      path: path.split("?")[0], method: (opts.method || "GET").toUpperCase(), body: opts.body ? JSON.parse(opts.body) : {}
    });
    return new Response(out.body, { status: out.status, headers: { "Content-Type": "application/json" } });
  };
})();
"""

let uiBase = "openup://app"

// MARK: - windows

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The picker: a Spotlight-style panel. `.nonactivatingPanel` lets it take keyboard focus
/// without OPEN_UP having to become the frontmost app (newer macOS often refuses that).
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply,
    WKNavigationDelegate, NSWindowDelegate {
    var queue: [[URL]] = []
    var gotFiles = false
    var picker: PickerPanel?
    var clickMonitors: [Any] = []
    var pickerWeb: WKWebView?
    var currentFiles: [URL] = []
    var settings: NSWindow?
    var ignoreResignUntil = Date.distantPast
    let scheme = UIScheme()
    var snapshotMode = false

    func applicationDidFinishLaunching(_ note: Notification) {
        if snapshotMode { return }
        buildMenu()
        rescan(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !self.gotFiles { self.showSettings() }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        gotFiles = true
        var groups: [String: [URL]] = [:]
        var order: [String] = []
        for u in urls {
            let e = u.pathExtension.lowercased()
            if groups[e] == nil { order.append(e) }
            groups[e, default: []].append(u)
        }
        queue.append(contentsOf: order.map { groups[$0]! })
        if picker?.isVisible != true { next() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if picker?.isVisible != true { showSettings() }
        return true
    }

    func maybeQuit() {
        if picker?.isVisible != true && settings == nil && queue.isEmpty { NSApp.terminate(nil) }
    }

    func rescan(_ done: ((Int) -> Void)?) {
        DispatchQueue.global(qos: .utility).async {
            let apps = scanApps()
            DispatchQueue.main.async {
                store.state.apps = apps
                store.save()
                done?(apps.count)
            }
        }
    }

    func makeWeb(frame: NSRect) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: "openup")
        cfg.userContentController.add(self, name: "openup")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "api")
        cfg.userContentController.addUserScript(WKUserScript(source: fetchShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: frame, configuration: cfg)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    // MARK: picker

    func next() {
        guard !queue.isEmpty else {
            hidePicker()
            maybeQuit()
            return
        }
        let files = queue.removeFirst()
        currentFiles = files
        let id = store.newSession(files: files.map(\.path), candidates: candidates(for: files[0]))
        showPicker(session: id)
    }

    func showPicker(session: String) {
        if picker == nil {
            let w = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 240),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.becomesKeyOnlyIfNeeded = false
            w.hidesOnDeactivate = false
            w.level = .floating
            w.backgroundColor = .black
            w.hasShadow = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.isMovableByWindowBackground = true
            w.delegate = self
            let web = makeWeb(frame: w.contentView!.bounds)
            w.contentView!.addSubview(web)
            picker = w
            pickerWeb = web
        }
        guard let w = picker, let web = pickerWeb else { return }
        web.load(URLRequest(url: URL(string: "\(uiBase)/pick?s=\(session)")!))
        positionPicker(height: w.frame.height)
        // An app we just launched may grab focus a moment after this picker appears;
        // don't count that as a click-away.
        ignoreResignUntil = Date().addingTimeInterval(1.0)
        activateApp()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(web)
        watchClicksOutside()
    }

    func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Any mouse click outside the picker dismisses it, whether or not the picker had focus:
    /// a global monitor sees clicks in other apps and on the desktop, a local one sees clicks
    /// in OPEN_UP's other windows (settings).
    func watchClicksOutside() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.dismissPicker() }) {
            clickMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            if let self, e.window !== self.picker { self.dismissPicker() }
            return e
        }) {
            clickMonitors.append(l)
        }
    }

    func hidePicker() {
        picker?.orderOut(nil)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    /// Click-away / esc: skip this file; any queued files get their own picker.
    func dismissPicker() {
        guard picker?.isVisible == true else { return }
        hidePicker()
        next()
    }

    /// Spotlight-ish: horizontally centered, top edge about a fifth of the way down the screen.
    func positionPicker(height: CGFloat) {
        guard let w = picker, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let h = min(max(height, 120), v.height * 0.8)
        let top = v.maxY - v.height * 0.22
        w.setFrame(NSRect(x: v.midX - w.frame.width / 2, y: top - h, width: w.frame.width, height: h), display: true)
    }

    func launch(app: URL, files: [URL]) {
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err {
                DispatchQueue.main.async {
                    let a = NSAlert(error: err)
                    a.messageText = "Couldn't open with \(displayName(app))"
                    a.runModal()
                }
            }
        }
    }

    // MARK: settings

    func showSettings() {
        if let s = settings {
            activateApp()
            s.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "OPEN_UP"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        let web = makeWeb(frame: w.contentView!.bounds)
        w.contentView!.addSubview(web)
        web.load(URLRequest(url: URL(string: uiBase + "/")!))
        w.center()
        settings = w
        activateApp()
        w.makeKeyAndOrderFront(nil)
    }

    /// Clicking outside the picker (another window, the desktop, another app) dismisses it,
    /// like Spotlight. Counts as cancel for this file; any queued files get their own picker.
    func windowDidResignKey(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === picker, Date() > ignoreResignUntil else { return }
        dismissPicker()
    }

    func windowWillClose(_ note: Notification) {
        if (note.object as? NSWindow) === settings {
            settings = nil
            DispatchQueue.main.async { self.maybeQuit() }
        }
    }

    // MARK: bridge

    func reply(_ web: WKWebView?, _ obj: [String: Any]) {
        web?.evaluateJavaScript("window.onNative && window.onNative(\(jsonString(obj)))")
    }

    /// Only our own bundled pages may talk to the app.
    func trusted(_ message: WKScriptMessage) -> Bool {
        message.frameInfo.isMainFrame && message.frameInfo.securityOrigin.protocol == "openup"
    }

    /// fetch("/api/...") from the pages.
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard trusted(message), let msg = message.body as? [String: Any], let path = msg["path"] as? String else {
            replyHandler(["status": 403, "body": jsonString(["error": "forbidden"])], nil)
            return
        }
        let (status, obj) = store.api(method: msg["method"] as? String ?? "GET", path: path, body: msg["body"] as? [String: Any] ?? [:])
        replyHandler(["status": status, "body": jsonString(obj)], nil)
    }

    /// Native actions from the pages.
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard trusted(message), let msg = message.body as? [String: Any], let type = msg["type"] as? String else { return }
        let web = message.webView
        let fromPicker = web === pickerWeb

        switch type {
        case "open":
            guard fromPicker, let path = msg["app"] as? String, path.hasSuffix(".app"),
                  FileManager.default.fileExists(atPath: path) else {
                NSSound.beep()
                return
            }
            // Only open the files macOS handed us; never paths supplied by the page.
            let files = currentFiles
            hidePicker()
            launch(app: URL(fileURLWithPath: path), files: files)
            next()
        case "cancel":
            if fromPicker {
                dismissPicker()
            } else {
                settings?.close()
            }
        case "resize":
            guard let h = msg["height"] as? Double else { return }
            if fromPicker {
                positionPicker(height: CGFloat(h))
            } else if snapshotMode, let w = web?.window {
                w.setContentSize(NSSize(width: w.frame.width, height: CGFloat(h)))  // snapshot what the real window would show
            }
        case "setDefault":
            if let ext = msg["ext"] as? String { setDefault(ext: ext) { self.reply(web, ["message": $0]) } }
        case "rescan":
            rescan { n in self.reply(web, ["message": "Indexed \(n) apps", "reload": true]) }
        default:
            break
        }
    }

    // A hidden main menu so ⌘C/⌘V/⌘W/⌘Q work even though there's no Dock icon.
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit OPEN_UP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

// MARK: - development: render a page offscreen to a PNG

final class Snapshotter: NSObject, WKNavigationDelegate {
    let out: String
    init(out: String) { self.out = out }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {  // let fonts + fetches settle
            webView.takeSnapshot(with: nil) { img, err in
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("snapshot failed: \(err?.localizedDescription ?? "?")"); exit(1)
                }
                try? png.write(to: URL(fileURLWithPath: self.out))
                print("wrote \(self.out)")
                exit(0)
            }
        }
    }
}

// MARK: - entry

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--set-default") {
    let exts = args[(i + 1)...].map { normExt($0) }
    if exts.isEmpty { print("usage: OpenUp --set-default md pdf txt ..."); exit(1) }
    let group = DispatchGroup()
    for e in exts {
        group.enter()
        setDefault(ext: e) { print($0); group.leave() }
    }
    group.notify(queue: .main) { exit(0) }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

if let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 {
    let page = args[i + 1], out = args[i + 2]
    let size = page == "pick" ? NSSize(width: 660, height: 300) : NSSize(width: 1000, height: 720)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let web = delegate.makeWeb(frame: NSRect(origin: .zero, size: size))
    delegate.snapshotMode = true
    let snap = Snapshotter(out: out)
    web.navigationDelegate = snap
    w.contentView!.addSubview(web)
    w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    w.orderBack(nil)
    var url = uiBase + "/"
    if page == "pick" {
        store.state.apps = scanApps()
        let f = args.count > i + 3 ? args[i + 3] : NSHomeDirectory() + "/example.md"
        let id = store.newSession(files: [f], candidates: candidates(for: URL(fileURLWithPath: f)))
        url = "\(uiBase)/pick?s=\(id)"
    }
    web.load(URLRequest(url: URL(string: url)!))
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(snap) { app.run() }
    exit(0)
}

app.setActivationPolicy(.accessory)
app.run()

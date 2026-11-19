// OPEN_UP Mac helper.
//
// The UI and all the logic live in the Docker container. This helper is a thin
// native shell: it receives files from macOS (double-click / `open -a`), asks
// the container to rank apps, shows the container's picker page in a floating
// borderless window, and launches the app you choose.
//
// Run with no files → settings window.
// CLI: OpenUp --set-default md pdf ...  → make OPEN_UP the default for those types.

import Cocoa
import UniformTypeIdentifiers
import WebKit

let serverBase = UserDefaults.standard.string(forKey: "serverURL") ?? "http://127.0.0.1:7777"

func displayName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

// MARK: - networking

func request(_ path: String, _ body: Any? = nil, done: @escaping ([String: Any]?, Error?) -> Void) {
    var req = URLRequest(url: URL(string: serverBase + path)!)
    req.timeoutInterval = 3
    if let body {
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    URLSession.shared.dataTask(with: req) { data, _, err in
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        DispatchQueue.main.async { done(json, err) }
    }.resume()
}

// MARK: - app inventory

func scanApps() -> [[String: String]] {
    let fm = FileManager.default
    let roots = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]
    var seen = Set<String>()
    var out: [[String: String]] = []
    let myID = Bundle.main.bundleIdentifier

    func visit(_ dir: String, depth: Int) {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for item in items where !item.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(item)
            if item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                let bid = Bundle(url: url)?.bundleIdentifier ?? ""
                if bid == myID { continue }
                out.append(["path": url.path, "name": displayName(url), "bundleId": bid])
            } else if depth > 0 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    visit(path, depth: depth - 1)
                }
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

// MARK: - windows

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var queue: [[URL]] = []
    var gotFiles = false
    var picker: KeyWindow?
    var pickerWeb: WKWebView?
    var currentFiles: [URL] = []
    var settings: NSWindow?
    var ignoreResignUntil = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        pushInventory(nil)
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

    // MARK: picker

    func next() {
        guard !queue.isEmpty else {
            picker?.orderOut(nil)
            maybeQuit()
            return
        }
        let files = queue.removeFirst()
        currentFiles = files
        let body: [String: Any] = ["files": files.map(\.path), "candidates": candidates(for: files[0])]
        request("/api/session", body) { json, err in
            if let id = json?["id"] as? String {
                self.showPicker(session: id)
            } else {
                self.fallback(files: files)
            }
        }
    }

    func makeWeb(frame: NSRect) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "openup")
        let web = WKWebView(frame: frame, configuration: cfg)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func showPicker(session: String) {
        if picker == nil {
            let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
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
        web.load(URLRequest(url: URL(string: "\(serverBase)/pick?s=\(session)")!))
        positionPicker(height: w.frame.height)
        // An app we just launched may grab focus a moment after this picker appears;
        // don't count that as a click-away.
        ignoreResignUntil = Date().addingTimeInterval(1.0)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(web)
    }

    /// Spotlight-ish: horizontally centered, top edge about a quarter down the screen.
    func positionPicker(height: CGFloat) {
        guard let w = picker, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let h = min(max(height, 120), v.height * 0.8)
        let top = v.maxY - v.height * 0.22
        w.setFrame(NSRect(x: v.midX - w.frame.width / 2, y: top - h, width: w.frame.width, height: h), display: true)
    }

    /// Container unreachable: plain native alert with macOS's suggestions.
    func fallback(files: [URL]) {
        let cands = Array(candidates(for: files[0]).prefix(3))
        let alert = NSAlert()
        alert.messageText = "OPEN_UP server isn't running"
        alert.informativeText = "Start it with `docker compose up -d` in the open_up folder.\n\nOpen \(files[0].lastPathComponent) with:"
        for c in cands { alert.addButton(withTitle: c["name"] ?? "?") }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if r >= 0 && r < cands.count, let p = cands[r]["path"] {
            launch(app: URL(fileURLWithPath: p), files: files)
        }
        next()
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
            NSApp.activate(ignoringOtherApps: true)
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
        web.load(URLRequest(url: URL(string: serverBase + "/")!))
        w.center()
        settings = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Clicking outside the picker (another window, the desktop, another app) dismisses it,
    /// like Spotlight. Counts as cancel for this file; any queued files get their own picker.
    func windowDidResignKey(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === picker, w.isVisible, Date() > ignoreResignUntil else { return }
        w.orderOut(nil)
        next()
    }

    func windowWillClose(_ note: Notification) {
        if (note.object as? NSWindow) === settings {
            settings = nil
            DispatchQueue.main.async { self.maybeQuit() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        let html = """
        <body style="background:#000;color:#eee;font:20px Menlo,monospace;padding:30px">
        <p>&gt; OPEN_UP SERVER NOT REACHABLE AT \(serverBase)</p>
        <p>&gt; run: <b>docker compose up -d</b> in the open_up folder, then reopen.</p>
        <p>&gt; press esc to close<span style="animation:b 1s steps(1) infinite">_</span></p>
        <style>@keyframes b{50%{opacity:0}}</style>
        <script>document.onkeydown=e=>{if(e.key==='Escape')webkit.messageHandlers.openup.postMessage({type:'cancel'})}</script>
        </body>
        """
        webView.loadHTMLString(html, baseURL: nil)
        if webView === pickerWeb { positionPicker(height: 200) }
    }

    // MARK: bridge

    func pushInventory(_ done: ((Int) -> Void)?) {
        DispatchQueue.global(qos: .utility).async {
            let apps = scanApps()
            DispatchQueue.main.async {
                request("/api/apps", ["apps": apps]) { json, _ in done?(json?["count"] as? Int ?? -1) }
            }
        }
    }

    func reply(_ web: WKWebView?, _ obj: [String: Any]) {
        guard let web, let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.onNative && window.onNative(\(s))")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msg = message.body as? [String: Any], let type = msg["type"] as? String else { return }
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
            picker?.orderOut(nil)
            launch(app: URL(fileURLWithPath: path), files: files)
            next()
        case "cancel":
            if fromPicker {
                picker?.orderOut(nil)
                next()
            } else {
                settings?.close()
            }
        case "resize":
            if fromPicker, let h = msg["height"] as? Double { positionPicker(height: CGFloat(h)) }
        case "setDefault":
            if let ext = msg["ext"] as? String { setDefault(ext: ext) { self.reply(web, ["message": $0]) } }
        case "rescan":
            pushInventory { n in self.reply(web, ["message": "Indexed \(n) apps", "reload": true]) }
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

// MARK: - entry

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--set-default") {
    let exts = args[(i + 1)...].map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
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
app.setActivationPolicy(.accessory)
app.run()

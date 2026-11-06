import AppKit
import ApplicationServices
import Darwin
import Foundation
import Security

// Annex's helper inside the workspace (installed at /usr/local/libexec/annex/AnnexHelper.app).
//
//   AnnexHelper serve    in the account's session (LaunchAgent): answers on a socket in the account's Library;
//                        needs the Accessibility permission to see the focused field and to type
//   AnnexHelper client   as root over SSH: relays one JSON line from stdin to the helper and its answer to stdout,
//                        but only if the program answering on the socket is this installed helper (nothing else in
//                        the workspace can pose as it and receive a password)
//
// Requests: {"op":"status"} {"op":"focus"} {"op":"fill","host":"...","kind":"username|password|code",
// "username":"...","password":"...","code":"..."}. Answers never contain what was typed.

let helperVersion = "9"
let guestUser = "annex"

func socketPath(home: String) -> String { "\(home)/Library/Application Support/AnnexHelper/helper.sock" }

func reply(_ object: [String: Any]) -> Data {
    ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)) + Data([0x0A])
}

// MARK: Accessibility

enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let p = attribute(element, kAXParentAttribute) else { return nil }
        return (p as! AXUIElement)
    }

    /// Chrome, if it is the app in front. Found through LaunchServices and asked through accessibility: a
    /// background app like this one gets no activation news (NSWorkspace's frontmost app goes stale), and the
    /// system-wide element sometimes has no focused app at all. Chrome builds the accessibility tree of web pages
    /// only for assistive apps; AXManualAccessibility asks for it.
    static func chromeApp() -> AXUIElement? { frontChrome()?.app }

    /// The Chrome in front and its process. Only the real Google Chrome counts (by code signature, not by name),
    /// started without command line switches (switches could turn off certificate checks or log the traffic).
    static func frontChrome() -> (app: AXUIElement, pid: pid_t)? {
        for chrome in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
            let pid = chrome.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            enableWebAccessibility(app)
            if (attribute(app, kAXFrontmostAttribute) as? Bool) == true { return (app, pid) }
        }
        return nil
    }

    /// Asks Chrome for the accessibility tree of its web pages (as VoiceOver does); Chrome builds it on demand.
    static func enableWebAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The focused element in Chrome, if Chrome has the keyboard focus. Right after the tree was asked for, Chrome
    /// may need a moment to build it.
    static func chromeFocus(wait: Double = 4) -> (app: AXUIElement, element: AXUIElement)? {
        guard let app = chromeApp() else { return nil }
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if let f = attribute(app, kAXFocusedUIElementAttribute) { return (app, f as! AXUIElement) }
            usleep(150_000)
        } while Date() < deadline
        return nil
    }

    /// The page an element belongs to, only if that is the tab's own page (not a frame inside another page: the
    /// outer page could move the focus away from the frame while typing).
    static func topLevelWebArea(of element: AXUIElement) -> (area: AXUIElement, url: URL)? {
        guard let found = webArea(of: element) else { return nil }
        var current = parent(found.area)
        var depth = 0
        while let e = current, depth < 80 {
            if string(e, kAXRoleAttribute) == "AXWebArea" { return nil }
            current = parent(e)
            depth += 1
        }
        return found
    }

    /// The web page an element belongs to and its URL.
    static func webArea(of element: AXUIElement) -> (area: AXUIElement, url: URL)? {
        var current: AXUIElement? = element
        var depth = 0
        while let e = current, depth < 80 {
            if string(e, kAXRoleAttribute) == "AXWebArea" {
                if let u = attribute(e, kAXURLAttribute) {
                    if CFGetTypeID(u) == CFURLGetTypeID() { return (e, (u as! CFURL) as URL) }
                    if let s = u as? String, let url = URL(string: s) { return (e, url) }
                }
                return nil
            }
            current = parent(e)
            depth += 1
        }
        return nil
    }

    static func isTextField(_ e: AXUIElement) -> Bool {
        let role = string(e, kAXRoleAttribute)
        return role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField"
    }

    static func isSecure(_ e: AXUIElement) -> Bool { string(e, kAXSubroleAttribute) == "AXSecureTextField" }

    /// "password", "code" or "username" for a text field; codes are recognized by their label.
    static func kind(_ e: AXUIElement) -> String {
        if isSecure(e) { return "password" }
        let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute,
                     "AXDOMIdentifier"].compactMap { string(e, $0) }.joined(separator: " ").lowercased()
        let codeWords = ["code", "otp", "2fa", "token", "verification", "bestätigung", "einmal", "pin", "authenticator"]
        if codeWords.contains(where: { label.contains($0) }) && !label.contains("postal") && !label.contains("zip") {
            return "code"
        }
        return "username"
    }

    /// Text fields of a page in document order (bounded walk).
    static func fields(in area: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack: [AXUIElement] = [area]
        var visited = 0
        while let e = stack.popLast(), visited < 6000 {
            visited += 1
            if isTextField(e) {
                let enabled = (attribute(e, kAXEnabledAttribute) as? Bool) ?? true
                if enabled { out.append(e) }
                continue
            }
            stack.append(contentsOf: children(e).reversed())
        }
        return out
    }

    static func focus(_ e: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func isEmpty(_ e: AXUIElement) -> Bool { ((attribute(e, kAXValueAttribute) as? String) ?? "").isEmpty }
}

// MARK: Typing

enum Keyboard {
    /// Its own event state: what the user (or screen sharing) holds down doesn't mix into these events.
    static let source = CGEventSource(stateID: .privateState)
    static let command: CGKeyCode = 0x37
    /// The verified Chrome: key events go to this process only, never to whatever app has the focus meanwhile.
    nonisolated(unsafe) static var target: pid_t = 0

    static func send(_ e: CGEvent?) {
        guard let e, target > 0 else { return }
        e.postToPid(target)
    }

    static func event(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        e?.flags = flags
        send(e)
        usleep(8000)
    }

    static func post(_ key: CGKeyCode) {
        event(key, down: true, flags: [])
        event(key, down: false, flags: [])
    }

    /// Command plus a key, pressed and released like a person would (Command down, key, key up, Command up), so no
    /// modifier stays behind for the characters that follow.
    static func commandPlus(_ key: CGKeyCode) {
        event(command, down: true, flags: .maskCommand)
        event(key, down: true, flags: .maskCommand)
        event(key, down: false, flags: .maskCommand)
        event(command, down: false, flags: [])
    }

    /// Types any text (also characters the keyboard layout doesn't have) as Unicode key events without modifiers.
    static func type(_ text: String) {
        for unit in text.utf16 {
            var u = unit
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                send(e)
            }
            usleep(12000)
        }
    }

    static func selectAll() { commandPlus(0x00) }
    static func returnKey() { post(0x24) }
}

// MARK: Requests

func hostMatches(_ url: URL, _ host: String) -> Bool {
    guard let h = url.host?.lowercased(), url.scheme?.lowercased() == "https" else { return false }
    return h == host.lowercased()
}

/// A website a sign-in may go to: https (the certificate proves the site) on a domain name. Not an address, not
/// localhost or a name without a dot: a page the agent serves itself must not pass as a website.
func signInSite(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "https", let raw = url.host?.lowercased(), !raw.isEmpty else { return nil }
    let host = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    guard host.contains("."), !host.hasSuffix(".localhost"), host != "localhost", !host.hasSuffix(".local"),
          !host.contains(":"), host.rangeOfCharacter(from: CharacterSet.letters) != nil else { return nil }
    // dotted numbers (an IPv4 address) are no domain
    if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }
    return host
}

// MARK: Code signatures

enum Signature {
    static let chrome = "anchor apple generic and identifier \"com.google.Chrome\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
    static let helper = "anchor apple generic and identifier \"dev.marquart.annex.guest-helper\" and certificate leaf[subject.OU] = \"S3725YB7V6\""

    static func valid(_ attributes: [CFString: Any], _ requirement: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    static func valid(pid: pid_t, _ requirement: String) -> Bool { valid([kSecGuestAttributePid: pid], requirement) }

    static func valid(token: audit_token_t, _ requirement: String) -> Bool {
        var t = token
        return valid([kSecGuestAttributeAudit: Data(bytes: &t, count: MemoryLayout<audit_token_t>.size)], requirement)
    }

    /// The switches a process was started with (KERN_PROCARGS2), without the program path; nil if unreadable.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }  // the executable path
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return Array(args.dropFirst())
    }

    /// Why this Chrome may not get a sign-in (nil: it may).
    static func chromeProblem(_ pid: pid_t) -> String? {
        guard valid(pid: pid, chrome) else { return "the app in front calls itself Chrome but isn't Google Chrome" }
        guard let args = arguments(of: pid) else { return "Chrome's start options can't be checked" }
        if args.contains(where: { !$0.hasPrefix("-psn_") }) {
            return "Chrome was started with extra options; quit it and open it from the Dock"
        }
        return scriptingProblem()
    }

    /// A Chrome profile that allows JavaScript from Apple Events (View > Developer) lets any app run script in the
    /// sign-in page. Chrome has no policy for it, so the helper looks into the profiles before every sign-in.
    static func scriptingProblem() -> String? {
        let chromeDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let profiles = (try? FileManager.default.contentsOfDirectory(at: chromeDir, includingPropertiesForKeys: nil)) ?? []
        for profile in profiles {
            for file in ["Preferences", "Secure Preferences"] {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let browser = json["browser"] as? [String: Any] else { continue }
                if (browser["allow_javascript_apple_events"] as? Bool) == true {
                    return "Chrome allows JavaScript from Apple Events (View > Developer); turn it off, then try again"
                }
            }
        }
        return nil
    }
}

/// Why there is no Chrome focus, step by step (for the agent's error message and for diagnosis).
func focusProblem() -> String {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
    guard let chrome = running.first else { return "Chrome is not running" }
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    var front: CFTypeRef?
    let e1 = AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &front)
    guard e1 == .success else { return "Chrome doesn't answer accessibility requests (AX error \(e1.rawValue))" }
    guard (front as? Bool) == true else { return "Chrome is not the app in front" }
    var focused: CFTypeRef?
    let e2 = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
    return "nothing in Chrome has the keyboard focus (AX error \(e2.rawValue))"
}

func currentFocus() -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["ok": false, "error": "the helper is not allowed to use accessibility"] }
    guard let chrome = AX.frontChrome() else { return ["ok": true, "kind": "none", "error": focusProblem()] }
    if let problem = Signature.chromeProblem(chrome.pid) { return ["ok": true, "kind": "none", "error": problem] }
    guard let (_, element) = AX.chromeFocus() else {
        return ["ok": true, "kind": "none", "error": focusProblem()]
    }
    guard AX.isTextField(element) else { return ["ok": true, "kind": "none", "error": "the focus is not in a text field"] }
    guard let (_, url) = AX.webArea(of: element) else {
        return ["ok": true, "kind": "none", "error": "the field is not on a website"]
    }
    guard AX.topLevelWebArea(of: element) != nil else {
        return ["ok": true, "kind": "none", "error": "the field is inside a frame of another page; open the sign-in page itself"]
    }
    guard let host = signInSite(url) else {
        return ["ok": true, "kind": "none", "error": "Annex signs in only on https websites with a domain name"]
    }
    return ["ok": true, "kind": AX.kind(element), "host": host, "app": "Google Chrome"]
}

/// Waits up to `seconds` for a password field on a page of `host` (two-step sign-ins show it after "Next").
func waitForPasswordField(host: String, seconds: Double) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        usleep(400_000)
        guard let app = AX.chromeApp(), let window = AX.attribute(app, kAXFocusedWindowAttribute) else { continue }
        var stack: [AXUIElement] = [window as! AXUIElement]
        var visited = 0
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            guard AX.string(e, kAXRoleAttribute) == "AXWebArea" else {
                stack.append(contentsOf: AX.children(e))
                continue
            }
            guard let u = AX.attribute(e, kAXURLAttribute), CFGetTypeID(u) == CFURLGetTypeID(),
                  hostMatches((u as! CFURL) as URL, host) else { continue }
            if let field = AX.fields(in: e).first(where: AX.isSecure) { return field }
        }
    }
    return nil
}

func fill(_ r: [String: Any]) -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["ok": false, "error": "the helper is not allowed to use accessibility"] }
    guard let host = r["host"] as? String, let kind = r["kind"] as? String else { return ["ok": false, "error": "bad request"] }
    let username = r["username"] as? String, password = r["password"] as? String, code = r["code"] as? String
    // The real Chrome must be in front; keys go to its process only.
    guard let chrome = AX.frontChrome() else { return ["ok": false, "error": "Chrome is not in front any more"] }
    if let problem = Signature.chromeProblem(chrome.pid) { return ["ok": false, "error": problem] }
    Keyboard.target = chrome.pid
    defer { Keyboard.target = 0 }
    // The focus must still be where the user approved it: a text field of the same kind on the tab's own page of
    // the same website.
    guard let (_, element) = AX.chromeFocus(), AX.isTextField(element),
          let (area, url) = AX.topLevelWebArea(of: element), hostMatches(url, host) else {
        return ["ok": false, "error": "the focus moved away from the sign-in field on \(host)"]
    }
    /// Right before Return: still the same field on the same page, Chrome still in front. Otherwise what was typed
    /// is taken out again and nothing is submitted.
    func stillThere(_ field: AXUIElement) -> Bool {
        guard let front = AX.frontChrome(), front.pid == chrome.pid, let (_, now) = AX.chromeFocus(wait: 1),
              CFEqual(now, field), let (_, u) = AX.topLevelWebArea(of: now), hostMatches(u, host) else { return false }
        return true
    }
    func submit(_ field: AXUIElement, _ filled: [String]) -> [String: Any] {
        guard stillThere(field) else {
            Keyboard.selectAll(); Keyboard.post(0x33)  // delete
            return ["ok": false, "error": "the focus moved while typing; nothing was submitted"]
        }
        Keyboard.returnKey()
        return ["ok": true, "filled": filled, "submitted": true, "host": host]
    }
    guard AX.kind(element) == kind || (kind == "username" && AX.kind(element) == "code") else {
        return ["ok": false, "error": "a different field has the focus now"]
    }
    var filled: [String] = []
    switch kind {
    case "code":
        guard let code, !code.isEmpty else { return ["ok": false, "error": "no code in the answer"] }
        Keyboard.selectAll(); Keyboard.type(code); filled.append("code")
        return submit(element, filled)

    case "password":
        guard let password, !password.isEmpty else { return ["ok": false, "error": "no password in the answer"] }
        // An empty user name field before the password field on the same page gets the user name first.
        if let username, !username.isEmpty {
            let fields = AX.fields(in: area)
            if let index = fields.firstIndex(where: { CFEqual($0, element) }),
               let before = fields[..<index].last(where: { !AX.isSecure($0) && AX.isEmpty($0) }),
               AX.focus(before) {
                usleep(150_000)
                Keyboard.type(username); filled.append("user name")
                guard AX.focus(element) else { return ["ok": false, "error": "could not return to the password field"] }
                usleep(150_000)
            }
        }
        // Check once more right before typing the secret.
        guard let (_, now) = AX.chromeFocus(), CFEqual(now, element), AX.isSecure(now) else {
            return ["ok": false, "error": "the focus moved away from the password field"]
        }
        Keyboard.selectAll(); Keyboard.type(password); filled.append("password")
        return submit(element, filled)

    default:  // username
        guard let username, !username.isEmpty else { return ["ok": false, "error": "no user name in the answer"] }
        Keyboard.selectAll(); Keyboard.type(username); filled.append("user name")
        guard let password, !password.isEmpty else { return submit(element, filled) }
        // Same page: the next password field after the user name field. Otherwise submit and wait for the
        // password step on the same website.
        let fields = AX.fields(in: area)
        var target: AXUIElement?
        if let index = fields.firstIndex(where: { CFEqual($0, element) }) {
            target = fields[(index + 1)...].first(where: AX.isSecure)
        }
        if target == nil {
            guard stillThere(element) else {
                Keyboard.selectAll(); Keyboard.post(0x33)
                return ["ok": false, "error": "the focus moved while typing; nothing was submitted"]
            }
            Keyboard.returnKey()
            target = waitForPasswordField(host: host, seconds: 12)
            guard target != nil else {
                return ["ok": true, "filled": filled, "submitted": true, "host": host,
                        "error": "no password field appeared on \(host); if the next page asks for it, call sign_in there"]
            }
        }
        guard let field = target, AX.focus(field) else {
            return ["ok": false, "filled": filled, "error": "could not move to the password field"]
        }
        usleep(250_000)
        guard let front = AX.frontChrome(), front.pid == chrome.pid, let (_, now) = AX.chromeFocus(), CFEqual(now, field),
              let (_, u2) = AX.topLevelWebArea(of: now), hostMatches(u2, host) else {
            return ["ok": false, "filled": filled, "error": "the password field is not on \(host) any more"]
        }
        Keyboard.selectAll(); Keyboard.type(password); filled.append("password")
        return submit(field, filled)
    }
}

/// Closes the notifications on screen (macOS shows "background activity" alerts after every start that cover the top
/// right of the screen): runs each notification's own "close" action through accessibility. Returns how many it
/// closed and the actions it found.
func dismissNotifications() -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["ok": false, "error": "the helper is not allowed to use accessibility"] }
    var closed = 0
    var actionsSeen = Set<String>()
    for nc in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui") {
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        var stack: [AXUIElement] = ((AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []) + AX.children(app)
        var visited = 0
        var notifications: [AXUIElement] = []
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            // Notification items have an identifier that is a UUID (widgets have "widget-local:...")
            if AX.string(e, kAXRoleAttribute) == "AXGroup", let id = AX.string(e, kAXIdentifierAttribute),
               UUID(uuidString: id) != nil {
                notifications.append(e)
                continue
            }
            stack.append(contentsOf: AX.children(e))
        }
        for n in notifications {
            var names: CFArray?
            guard AXUIElementCopyActionNames(n, &names) == .success, let list = names as? [String] else { continue }
            for name in list { actionsSeen.insert(String(name.prefix(60))) }
            if let close = list.first(where: { a in
                let l = a.lowercased()
                return l.contains("schließen") || l.contains("close") || l.contains("clear") || l.contains("löschen")
            }), AXUIElementPerformAction(n, close as CFString) == .success {
                closed += 1
            }
        }
    }
    return ["ok": true, "closed": closed, "actions": Array(actionsSeen).sorted()]
}

func handle(_ line: Data) -> Data {
    guard let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = r["op"] as? String else {
        return reply(["ok": false, "error": "bad request"])
    }
    switch op {
    case "status": return reply(["ok": true, "trusted": AXIsProcessTrusted(), "version": helperVersion])
    case "focus": return reply(currentFocus())
    case "fill":
        // Accessibility calls and key events belong on the main thread.
        var out: [String: Any] = [:]
        DispatchQueue.main.sync { out = fill(r) }
        return reply(out)
    case "dismiss-notifications":
        var out: [String: Any] = [:]
        DispatchQueue.main.sync { out = dismissNotifications() }
        return reply(out)
    case "prompt":
        // Puts the helper into the Accessibility list in System Settings (macOS shows its own question too).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return reply(["ok": true, "trusted": AXIsProcessTrustedWithOptions(options)])
    default: return reply(["ok": false, "error": "unknown op"])
    }
}

// MARK: Socket

func readLine(_ fd: Int32, limit: Int = 1 << 16) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < limit {
        let n = read(fd, &byte, 1)
        if n <= 0 { return data.isEmpty ? nil : data }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    return data
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n <= 0 { return }
            offset += n
        }
    }
}

func makeAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
    }
    return addr
}

func serve() -> Never {
    let home = NSHomeDirectory()
    let path = socketPath(home: home)
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = makeAddress(path)
    let old = umask(0o077)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(old)
    guard rc == 0, listen(fd, 4) == 0 else {
        FileHandle.standardError.write(Data("cannot listen on \(path): \(errno)\n".utf8))
        exit(1)
    }
    // Ask Chrome for its web accessibility tree early and keep asking (it builds it lazily and forgets it when it
    // restarts), so a sign-in finds the focused field without waiting.
    DispatchQueue.global().async {
        while true {
            if AXIsProcessTrusted() {
                for chrome in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
                    AX.enableWebAccessibility(AXUIElementCreateApplication(chrome.processIdentifier))
                }
            }
            sleep(10)
        }
    }
    DispatchQueue.global().async {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            if let line = readLine(client) { writeAll(client, handle(line)) }
            close(client)
        }
    }
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
    exit(0)
}

/// Root's side: relay one request, but only to the installed helper.
func client() -> Never {
    guard let pw = getpwnam(guestUser) else { print(String(decoding: reply(["ok": false, "error": "no account"]), as: UTF8.self)); exit(1) }
    let home = String(cString: pw.pointee.pw_dir)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = makeAddress(socketPath(home: home))
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    func fail(_ s: String) -> Never {
        FileHandle.standardOutput.write(reply(["ok": false, "error": s]))
        exit(1)
    }
    guard rc == 0 else { fail("the helper is not running (no one logged in, or it was stopped)") }
    // Who answers? It must be the signed helper (checked by code signature through the kernel's audit token, not
    // by a path a process can borrow), running as the account, and this program must be the installed one.
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { fail("cannot identify the helper") }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == pw.pointee.pw_uid, token.val.1 == pw.pointee.pw_uid,
          Signature.valid(token: token, Signature.helper), me.hasPrefix("/usr/local/libexec/annex/") else {
        fail("something other than the installed helper listens on its socket")
    }
    guard let line = readLine(STDIN_FILENO) else { fail("no request") }
    writeAll(fd, line + Data([0x0A]))
    var tv = timeval(tv_sec: 60, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard let answer = readLine(fd) else { fail("no answer from the helper") }
    FileHandle.standardOutput.write(answer + Data([0x0A]))
    exit(0)
}

switch CommandLine.arguments.dropFirst().first {
case "client": client()
case "serve", .none: serve()
default:
    FileHandle.standardError.write(Data("usage: AnnexHelper serve | client\n".utf8))
    exit(2)
}

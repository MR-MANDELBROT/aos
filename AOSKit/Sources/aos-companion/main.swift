import AOSKit
import Foundation

// The iPhone app's end of the companion API (Docs/COMPANION.md). The phone runs `aos-companion serve` in an SSH exec
// channel as the user: JSON lines on stdin and stdout. Everything goes to the aOS app over its agent socket (the app
// is started if it isn't running). Nothing is logged: answers to sign-ins pass straight through.

setvbuf(stdout, nil, _IOLBF, 0)

let outputLock = NSLock()
func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    outputLock.withLock {
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}

func answer(_ id: Any?, ok: Bool, _ fields: [String: Any] = [:], error: String? = nil) {
    var o = fields
    if let id { o["id"] = id }
    o["ok"] = ok
    if let error { o["error"] = error }
    send(o)
}

/// The app answers in `text`; for companion operations that is a JSON object.
func object(_ response: AgentResponse) -> [String: Any] {
    guard let data = response.text.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["text": response.text] }
    return o
}

final class Link: @unchecked Sendable {
    private var client: AgentClient?
    private let lock = NSLock()

    /// One request to the app; reconnects (starting the app) once if the connection broke.
    func call(_ build: (inout AgentRequest) -> Void) throws -> AgentResponse {
        try lock.withLock {
            for attempt in 0..<2 {
                do {
                    if client == nil { client = try AgentClient.connectStartingApp() }
                    return try client!.send(build)
                } catch {
                    client = nil
                    if attempt == 1 { throw error }
                }
            }
            throw SocketError.closed
        }
    }
}

guard CommandLine.arguments.dropFirst().first == "serve" else {
    FileHandle.standardError.write(Data("usage: aos-companion serve\n".utf8))
    exit(2)
}

let requests = Link()
let events = Link()  // its own connection: a long poll blocks it
var device = "iPhone"
var subscribed = false

/// Forwards the app's events to the phone for as long as stdin is open.
func pollEvents() {
    var since = 0
    var failures = 0
    while true {
        do {
            let response = try events.call { r in
                r.op = "companion.events"; r.since = since; r.seconds = 25; r.device = device
            }
            failures = 0
            let o = object(response)
            for e in (o["events"] as? [[String: Any]]) ?? [] {
                var event = e
                event.removeValue(forKey: "seq")
                send(event)
            }
            if let seq = o["seq"] as? Int { since = seq }
        } catch {
            failures += 1
            send(["event": "mac", "state": "unavailable", "detail": error.localizedDescription])
            Thread.sleep(forTimeInterval: min(Double(failures) * 2, 15))
        }
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let op = r["op"] as? String else {
        answer(nil, ok: false, error: "bad request")
        continue
    }
    let id = r["id"]
    do {
        switch op {
        case "hello":
            if let d = r["device"] as? String, !d.isEmpty { device = String(d.prefix(80)) }
            let o = object(try requests.call { $0.op = "companion.hello"; $0.device = device })
            answer(id, ok: true, o)
        case "status":
            let response = try requests.call { $0.op = "companion.status"; $0.device = device }
            answer(id, ok: response.ok, object(response), error: response.ok ? nil : response.text)
        case "subscribe":
            if !subscribed {
                subscribed = true
                Thread.detachNewThread { pollEvents() }
            }
            answer(id, ok: true)
        case "screen":
            let target = (r["target"] as? String) == "workspace" ? "workspace" : "mac"
            let response = try requests.call { $0.op = "companion.screen"; $0.target = target }
            answer(id, ok: response.ok, response.ok ? object(response) : [:], error: response.ok ? nil : response.text)
        case "signin.answer":
            let response = try requests.call { q in
                q.op = "signin.answer"
                q.request = r["request"] as? String
                q.username = r["username"] as? String
                q.password = r["password"] as? String
                q.totp = r["totp"] as? String
                q.decline = r["decline"] as? Bool
                q.device = device
            }
            answer(id, ok: response.ok, error: response.ok ? nil : response.text)
        case "type":
            let response = try requests.call { q in
                q.op = "companion.type"; q.text = r["text"] as? String; q.device = device
            }
            answer(id, ok: response.ok, error: response.ok ? nil : response.text)
        case "help.done":
            let response = try requests.call { q in
                q.op = "help.done"; q.request = r["request"] as? String; q.device = device
            }
            answer(id, ok: response.ok, error: response.ok ? nil : response.text)
        case "approval.answer":
            let response = try requests.call { q in
                q.op = "approval.answer"; q.request = r["request"] as? String; q.allowed = r["allowed"] as? Bool
                q.device = device
            }
            answer(id, ok: response.ok, error: response.ok ? nil : response.text)
        default:
            answer(id, ok: false, error: "unknown op \(op)")
        }
    } catch {
        answer(id, ok: false, error: "\(Brand.name) on the Mac doesn't answer: \(error.localizedDescription)")
    }
}
exit(0)

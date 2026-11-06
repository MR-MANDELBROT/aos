import AOSKit
import Foundation

// The iPhone app's end of the companion API (Docs/COMPANION.md). The phone runs `aos-companion serve` in an SSH exec
// channel as the user: JSON lines on stdin and stdout. Everything goes to the aOS app over its agent socket (the app
// is started if it isn't running). Nothing is logged: answers to sign-ins pass straight through.
//
// This program proves nothing: anyone on the Mac can run it. The phone signs its requests (`auth`) and the app checks
// them; this only passes the signatures on. Events: a signed `subscribe` gets a subscription from the app, kept here
// in memory only, and the polls for events carry it.

setvbuf(stdout, nil, _IOLBF, 0)

let outputLock = NSLock()
func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    outputLock.withLock {
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}

func answer(_ id: Any?, ok: Bool, _ fields: [String: Any] = [:], error: String? = nil, code: String? = nil) {
    var o = fields
    if let id { o["id"] = id }
    o["ok"] = ok
    if let error { o["error"] = error }
    if let code { o["code"] = code }
    send(o)
}

/// Answers the phone with the app's response: its fields on success, its text (and code) as the error otherwise.
func relay(_ id: Any?, _ response: AgentResponse, fields: Bool = false) {
    answer(id, ok: response.ok, response.ok && fields ? object(response) : [:],
           error: response.ok ? nil : response.text, code: response.ok ? nil : response.code)
}

/// The app answers in `text`; for companion operations that is a JSON object.
func object(_ response: AgentResponse) -> [String: Any] {
    guard let data = response.text.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["text": response.text] }
    return o
}

/// The phone's signature, passed on unchanged.
func auth(_ r: [String: Any]) -> CompanionAuth? {
    guard let a = r["auth"] as? [String: Any], let key = a["key"] as? String, let ts = a["ts"] as? Int,
          let nonce = a["nonce"] as? String, let sig = a["sig"] as? String else { return nil }
    return CompanionAuth(key: key, ts: ts, nonce: nonce, sig: sig)
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

/// The subscription for the event polls (set by a signed subscribe, cleared when the app ends it).
final class Subscription: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var started = false

    var current: String? { lock.withLock { token } }
    func set(_ value: String?) { lock.withLock { token = value } }
    func clear(_ value: String) { lock.withLock { if token == value { token = nil } } }
    /// True the first time only: the poll thread starts once.
    func start() -> Bool { lock.withLock { defer { started = true }; return !started } }
}

guard CommandLine.arguments.dropFirst().first == "serve" else {
    FileHandle.standardError.write(Data("usage: aos-companion serve\n".utf8))
    exit(2)
}

let requests = Link()
let events = Link()  // its own connection: a long poll blocks it
let subscription = Subscription()

/// Forwards the app's events to the phone for as long as stdin is open.
func pollEvents() {
    var since = 0
    var failures = 0
    while true {
        guard let token = subscription.current else {
            Thread.sleep(forTimeInterval: 0.5)
            continue
        }
        do {
            let response = try events.call { r in
                r.op = "companion.events"; r.since = since; r.seconds = 25; r.subscription = token
            }
            failures = 0
            if !response.ok {
                if response.code == "subscription-ended" {
                    // The app restarted or the subscription ran out: the phone subscribes again (signed).
                    subscription.clear(token)
                    send(["event": "subscription", "state": "ended"])
                } else {
                    Thread.sleep(forTimeInterval: 2)
                }
                continue
            }
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
    let signature = auth(r)
    do {
        switch op {
        case "hello":
            let response = try requests.call { $0.op = "companion.hello"; $0.auth = signature }
            relay(id, response, fields: true)
        case "status":
            let response = try requests.call { $0.op = "companion.status"; $0.auth = signature }
            relay(id, response, fields: true)
        case "subscribe":
            let response = try requests.call { $0.op = "companion.subscribe"; $0.auth = signature }
            if response.ok, let token = object(response)["subscription"] as? String {
                subscription.set(token)
                if subscription.start() { Thread.detachNewThread { pollEvents() } }
                answer(id, ok: true)
            } else {
                relay(id, response)
            }
        case "screen":
            let target = (r["target"] as? String) == "workspace" ? "workspace" : "mac"
            let response = try requests.call { $0.op = "companion.screen"; $0.target = target; $0.auth = signature }
            relay(id, response, fields: true)
        case "signin.answer":
            let response = try requests.call { q in
                q.op = "signin.answer"
                q.request = r["request"] as? String
                q.host = r["host"] as? String
                q.username = r["username"] as? String
                q.password = r["password"] as? String
                q.totp = r["totp"] as? String
                q.login = r["login"] as? String
                q.decline = r["decline"] as? Bool
                q.auth = signature
            }
            relay(id, response)
        case "type":
            let response = try requests.call { q in
                q.op = "companion.type"; q.text = r["text"] as? String; q.auth = signature
            }
            relay(id, response)
        case "help.done":
            let response = try requests.call { q in
                q.op = "help.done"; q.request = r["request"] as? String; q.auth = signature
            }
            relay(id, response)
        case "approval.answer":
            let response = try requests.call { q in
                q.op = "approval.answer"; q.request = r["request"] as? String; q.allowed = r["allowed"] as? Bool
                q.auth = signature
            }
            relay(id, response)
        default:
            answer(id, ok: false, error: "unknown op \(op)")
        }
    } catch {
        answer(id, ok: false, error: "\(Brand.name) on the Mac doesn't answer: \(error.localizedDescription)")
    }
}
exit(0)

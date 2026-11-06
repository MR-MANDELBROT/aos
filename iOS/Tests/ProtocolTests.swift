import Foundation
import Testing
@testable import aOS

struct CompanionProtocolTests {
    private func text(_ request: CompanionRequest, id: Int) throws -> String {
        String(decoding: try request.line(id: id), as: UTF8.self)
    }

    @Test func requestLines() throws {
        #expect(try text(.hello(app: "0.1.0", device: "Max\u{2019}s iPhone"), id: 1)
                == "{\"app\":\"0.1.0\",\"device\":\"Max\u{2019}s iPhone\",\"id\":1,\"op\":\"hello\"}\n")
        #expect(try text(.status, id: 2) == "{\"id\":2,\"op\":\"status\"}\n")
        #expect(try text(.subscribe, id: 3) == "{\"id\":3,\"op\":\"subscribe\"}\n")
        #expect(try text(.screen(target: .workspace), id: 4) == "{\"id\":4,\"op\":\"screen\",\"target\":\"workspace\"}\n")
        #expect(try text(.signInAnswer(request: "r1", username: "max", password: "p\"w/\n", totp: "123456"), id: 5)
                == "{\"id\":5,\"op\":\"signin.answer\",\"password\":\"p\\\"w/\\n\",\"request\":\"r1\",\"totp\":\"123456\",\"username\":\"max\"}\n")
        #expect(try text(.signInAnswer(request: "r1", username: "max", password: "pw", totp: nil), id: 6)
                == "{\"id\":6,\"op\":\"signin.answer\",\"password\":\"pw\",\"request\":\"r1\",\"username\":\"max\"}\n")
        #expect(try text(.signInDecline(request: "r1"), id: 7) == "{\"decline\":true,\"id\":7,\"op\":\"signin.answer\",\"request\":\"r1\"}\n")
        #expect(try text(.helpDone(request: "h1"), id: 8) == "{\"id\":8,\"op\":\"help.done\",\"request\":\"h1\"}\n")
    }

    @Test func everyRequestIsExactlyOneLine() throws {
        let line = try CompanionRequest.signInAnswer(request: "r", username: "a\nb", password: "c\r\nd", totp: nil).line(id: 1)
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
    }

    @Test func responses() throws {
        let hello = try CompanionMessage.decode(line: Data(#"{"id":1,"ok":true,"mac":"Max’s MacBook","aos":"0.2.0"}"#.utf8))
        guard case .response(let r) = hello else { Issue.record("not a response"); return }
        #expect(r.id == 1 && r.ok)
        #expect(HelloResult(r) == HelloResult(CompanionResponse(id: 1, ok: true, body: ["mac": .string("Max’s MacBook"), "aos": .string("0.2.0")])))
        #expect(HelloResult(r).mac == "Max’s MacBook")

        let status = try CompanionMessage.decode(line: Data(#"{"id":2,"ok":true,"workspace":{"state":"open","purpose":"Rechnung laden","until":"2026-11-06T12:30:00Z"},"sessions":[{"title":"Claude Code","state":"running"}]}"#.utf8))
        guard case .response(let s) = status else { Issue.record("not a response"); return }
        let ws = WorkspaceStatus(s)
        #expect(ws.state == .open)
        #expect(ws.purpose == "Rechnung laden")
        #expect(ws.until == Date(timeIntervalSince1970: 1_793_968_200))
        #expect(ws.sessions.map(\.title) == ["Claude Code"])

        let screen = try CompanionMessage.decode(line: Data(#"{"id":4,"ok":true,"host":"192.168.64.5","port":5900,"username":"aos","password":"secret"}"#.utf8))
        guard case .response(let sc) = screen else { Issue.record("not a response"); return }
        #expect(ScreenEndpoint(sc) == ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "aos", password: "secret"))

        let failed = try CompanionMessage.decode(line: Data(#"{"id":9,"ok":false,"error":"no such request"}"#.utf8))
        #expect(failed == .response(CompanionResponse(id: 9, ok: false, error: "no such request",
                                                      body: ["id": .number(9), "ok": .bool(false), "error": .string("no such request")])))
    }

    @Test func events() throws {
        let signIn = try CompanionMessage.decode(line: Data(#"{"event":"signin","request":"r7","agent":"Claude Code","host":"www.amazon.de","purpose":"Rechnung herunterladen","expires":"2026-11-06T12:00:00.250Z"}"#.utf8))
        #expect(signIn == .event(.signIn(SignInRequest(id: "r7", agent: "Claude Code", host: "www.amazon.de",
                                                       purpose: "Rechnung herunterladen",
                                                       expires: Date(timeIntervalSince1970: 1_793_966_400.25)))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"signin.closed","request":"r7","result":"filled"}"#.utf8))
                == .event(.signInClosed(request: "r7", result: .filled)))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"signin.closed","request":"r7","result":"exploded"}"#.utf8))
                == .event(.signInClosed(request: "r7", result: .unknown)))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"help","request":"h1","agent":"Codex","purpose":"Captcha","region":{"x":100,"y":200,"w":300,"h":150}}"#.utf8))
                == .event(.help(HelpRequest(id: "h1", agent: "Codex", purpose: "Captcha",
                                            region: .init(x: 100, y: 200, width: 300, height: 150)))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"help","request":"h2","agent":"Codex","purpose":"x","region":{"x":0,"y":0,"w":0,"h":0}}"#.utf8))
                == .event(.help(HelpRequest(id: "h2", agent: "Codex", purpose: "x", region: nil))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"help.closed","request":"h1"}"#.utf8)) == .event(.helpClosed(request: "h1")))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"workspace","state":"starting"}"#.utf8)) == .event(.workspace(.starting)))
    }

    @Test func unknownOrBrokenLines() throws {
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"future.thing","x":1}"#.utf8)) == .ignored)
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"signin","request":"r"}"#.utf8)) == .ignored)  // no host
        #expect(throws: CompanionMessage.DecodeError.notJSON) { try CompanionMessage.decode(line: Data("hello".utf8)) }
        #expect(throws: CompanionMessage.DecodeError.notAnObject) { try CompanionMessage.decode(line: Data("[1]".utf8)) }
    }

    @Test func lineSplitter() throws {
        var splitter = LineSplitter(limit: 16)
        #expect(try splitter.append(Data("{\"a\":".utf8)) == [])
        #expect(try splitter.append(Data("1}\r\n{\"b\":2}\n{".utf8)) == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        #expect(try splitter.append(Data("}\n".utf8)) == [Data("{}".utf8)])
        #expect(throws: LineSplitter.LineTooLong.self) { try splitter.append(Data(repeating: 0x41, count: 17)) }
    }
}

struct KeyInputTests {
    @Test func asciiTextWithShift() {
        let steps = KeyInput.steps(for: "Hi!\n")
        #expect(steps == [.keys([
            RemoteKeyStroke(0x48),  // H, shift
            RemoteKeyStroke(0x69),  // i
            RemoteKeyStroke(0x21),  // !, shift
            RemoteKeyStroke(0xff0d),  // return
        ])])
        guard case .keys(let strokes) = steps.first else { return }
        #expect(strokes.map(\.shift) == [true, false, true, false])
    }

    @Test func symbolsThatNeedShiftOnUS() {
        let shifted = "~!@#$%^&*()_+{}|:\"<>?ABCZ"
        let plain = "`1234567890-=[]\\;',./abcz "
        for c in shifted { #expect(RemoteKeyStroke(UInt32(c.asciiValue!)).shift, "\(c)") }
        for c in plain { #expect(!RemoteKeyStroke(UInt32(c.asciiValue!)).shift, "\(c)") }
    }

    @Test func charactersWithoutKeysymArePasted() {
        #expect(KeyInput.steps(for: "Grüße €") == [
            .keys([RemoteKeyStroke(0x47), RemoteKeyStroke(0x72)]),
            .paste("üß"),
            .keys([RemoteKeyStroke(0x65), RemoteKeyStroke(0x20)]),
            .paste("€"),
        ])
    }

    @Test func smartPunctuationFallsBackToASCII() {
        #expect(KeyInput.steps(for: "\u{201E}a\u{201C} \u{2013} it\u{2019}s") == KeyInput.steps(for: "\"a\" - it's"))
    }

    @Test func tabsAndLineBreaks() {
        #expect(KeyInput.steps(for: "\t\r") == [.keys([RemoteKeyStroke(0xff09), RemoteKeyStroke(0xff0d)])])
    }
}

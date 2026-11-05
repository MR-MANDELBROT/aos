@testable import AnnexKit
import XCTest

final class KeysymTests: XCTestCase {
    func testCombinations() throws {
        XCTAssertEqual(try Keysyms.combination("cmd+l"), [Keysyms.command, 0x6c])
        XCTAssertEqual(try Keysyms.combination("cmd+shift+a"), [Keysyms.command, Keysyms.shift, 0x61])
        XCTAssertEqual(try Keysyms.combination("Return"), [Keysyms.returnKey])
        XCTAssertEqual(try Keysyms.combination("+"), [0x2b])
        XCTAssertEqual(try Keysyms.combination("cmd++"), [Keysyms.command, 0x2b])
        XCTAssertEqual(try Keysyms.combination("f5"), [0xffc2])
        XCTAssertThrowsError(try Keysyms.combination("hyper+x"))
        XCTAssertThrowsError(try Keysyms.combination(""))
    }

    func testRunsSplitAsciiAndPaste() {
        XCTAssertEqual(Keysyms.runs(for: "ab"), [.keys([0x61, 0x62])])
        XCTAssertEqual(Keysyms.runs(for: "Grüße\n"),
                       [.keys([0x47, 0x72]), .paste("üß"), .keys([0x65, Keysyms.returnKey])])
        XCTAssertEqual(Keysyms.runs(for: "😀"), [.paste("😀")])
    }
}

final class GuestKitTests: XCTestCase {
    func testPoliciesArePropertyList() throws {
        let data = try ChromePolicies(keepSignedIn: ["[*.]example.com"]).plist()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["DefaultCookiesSetting"] as? Int, 4)
        XCTAssertEqual(plist?["CookiesAllowedForUrls"] as? [String], ["[*.]example.com"])
        XCTAssertEqual(plist?["RemoteDebuggingAllowed"] as? Bool, false)
    }

    func testSettingsEnvRejectsShellCharacters() {
        let kit = GuestKit(languages: ["de-DE", "en-US", "$(reboot)"], locale: "de_DE", timeZone: "Europe/Berlin;rm")
        let env = kit.settingsEnv()
        XCTAssertTrue(env.contains("LANGUAGES=\"de-DE en-US\""))
        XCTAssertTrue(env.contains("TIMEZONE=\n"))
        XCTAssertFalse(env.contains("reboot"))
    }

    func testBundleScriptRoundTrips() throws {
        let files: [(String, Data)] = [("setup.sh", Data("echo hi\n".utf8)), ("x.bin", Data([0, 1, 2, 255]))]
        let script = GuestKit.bundleScript(files: files, entry: "setup.sh")
        XCTAssertTrue(script.contains("base64 -D -o \"$K/setup.sh\""))
        // Run it locally against a fake entry (replace the run line) and check the unpacked files.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = script
            .replacingOccurrences(of: "mktemp -d /var/root/annex-kit.XXXXXX", with: "mktemp -d \(dir.path)/k.XXXXXX")
            .replacingOccurrences(of: "/bin/zsh -f \"$K/setup.sh\" \"$K\"", with: "cp \"$K/x.bin\" \(dir.path)/out.bin; cat \"$K/setup.sh\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", local]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "echo hi\n")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("out.bin")), Data([0, 1, 2, 255]))
    }

    func testGuestScriptsAreBundled() throws {
        for name in ["setup.sh", "guest-service.sh", "shutdown.sh", "finish.sh"] {
            XCTAssertFalse(try GuestKit.resource(name).isEmpty, name)
        }
    }
}

final class ExchangeTests: XCTestCase {
    var paths: Paths!

    override func setUpWithError() throws {
        paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ax-\(UUID().uuidString.prefix(8))"))
        try paths.prepare()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: paths.root) }

    func testNames() {
        XCTAssertNoThrow(try Exchange.checkName("report.pdf"))
        XCTAssertThrowsError(try Exchange.checkName("../x"))
        XCTAssertThrowsError(try Exchange.checkName(".hidden"))
        XCTAssertThrowsError(try Exchange.checkName("a/b"))
        XCTAssertThrowsError(try Exchange.checkName("a\nb"))
    }

    func testPutAndGetRefuseLinks() throws {
        let ex = Exchange(paths: paths)
        let src = paths.root.appendingPathComponent("in.txt")
        try Data("hello".utf8).write(to: src)
        _ = try ex.put(path: src.path, name: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.exchange.appendingPathComponent("in.txt").path))
        // A link planted in the exchange folder must not be followed.
        try FileManager.default.createSymbolicLink(at: paths.exchange.appendingPathComponent("evil"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try ex.get(name: "evil", keep: true))
        let text = try ex.get(name: "in.txt", keep: false)
        XCTAssertTrue(text.contains("Fetched"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.exchange.appendingPathComponent("in.txt").path))
    }

    func testForbiddenSources() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNotNil(Exchange.forbidden(home.appendingPathComponent(".ssh/id_ed25519")))
        XCTAssertNotNil(Exchange.forbidden(home.appendingPathComponent("Library/Keychains/login.keychain-db")))
        XCTAssertNotNil(Exchange.forbidden(home))
        XCTAssertNil(Exchange.forbidden(home.appendingPathComponent("Documents/report.pdf")))
    }
}

final class MCPTests: XCTestCase {
    func testInitializeAndList() {
        let server = MCPServer(paths: Paths(root: URL(fileURLWithPath: "/nonexistent")), version: "test")
        let initResult = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18"]])
        let result = initResult?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let list = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any]
        let tools = list?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set(MCPTools.operations.keys))
        let open = tools.first { $0["name"] as? String == "workspace_open" }
        XCTAssertEqual((open?["_meta"] as? [String: Any])?["anthropic/requiresUserInteraction"] as? Bool, true)
    }

    func testCallWithoutAgentIsError() {
        let server = MCPServer(paths: Paths(root: URL(fileURLWithPath: "/nonexistent")), version: "test")
        let r = server.call("workspace_status", [:])
        XCTAssertEqual(r["isError"] as? Bool, true)
    }
}

final class RFBAuthTests: XCTestCase {
    func testSPKIToPKCS1() throws {
        // Fresh RSA key; wrap its PKCS#1 public key into SubjectPublicKeyInfo the way screensharingd sends it.
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let priv = SecKeyCreateRandomKey(attrs as CFDictionary, nil)!
        let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(priv)!, nil)! as Data
        func derLength(_ n: Int) -> Data {
            n < 128 ? Data([UInt8(n)]) : (n < 256 ? Data([0x81, UInt8(n)]) : Data([0x82, UInt8(n >> 8), UInt8(n & 0xff)]))
        }
        let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = Data([0x03]) + derLength(pkcs1.count + 1) + Data([0]) + pkcs1
        let body = algorithm + bitString
        let spki = Data([0x30]) + derLength(body.count) + body
        XCTAssertEqual(try RFBAuth.spkiToPKCS1(spki), pkcs1)
        let key = try RFBAuth.rsaPublicKey(der: spki)
        XCTAssertNotNil(SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(count: 16) as CFData, nil))
    }

    func testPackIs64Bytes() {
        let p = RFBAuth.pack("annex")
        XCTAssertEqual(p.count, 64)
        XCTAssertEqual(p.prefix(6), Data("annex".utf8) + Data([0]))
    }
}

final class AgentIntegrationTests: XCTestCase {
    func testPatchJSONKeepsOtherServers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("mcp.json").path
        try Data(#"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.utf8).write(to: URL(fileURLWithPath: path))
        try AgentIntegration.patchJSON(path: path, serversKey: "mcpServers", style: .mcpServers,
                                       binary: URL(fileURLWithPath: "/Applications/Annex.app/Contents/MacOS/annex-mcp"),
                                       env: ["ANNEX_APPROVAL": "auto"])
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let servers = obj["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual((servers["annex"] as? [String: Any])?["command"] as? String, "/Applications/Annex.app/Contents/MacOS/annex-mcp")
        XCTAssertEqual(obj["theme"] as? String, "dark")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".annex-backup"))
    }

    func testPatchJSONRefusesComments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json").path
        try Data("// comment\n{\"a\":1}".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try AgentIntegration.patchJSON(path: path, serversKey: "mcpServers", style: .mcpServers,
                                                            binary: URL(fileURLWithPath: "/x"), env: [:]))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "// comment\n{\"a\":1}")
    }

    func testElicitationDeclineBlocksOpen() {
        // Client with elicitation that answers "decline": the call must not reach the app.
        let server = MCPServer(paths: Paths(root: URL(fileURLWithPath: "/nonexistent")), version: "t",
                               environment: ["ANNEX_APPROVAL": "agent"])
        _ = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["capabilities": [String: Any]()]])
        // approval "agent": goes straight to the (missing) app and fails with the app error, not a decline
        let r = server.call("workspace_open", ["purpose": "x"])
        let text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertFalse(text.contains("did not allow"))
    }
}

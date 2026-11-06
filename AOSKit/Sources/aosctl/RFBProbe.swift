import AOSKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// rfbprobe [--out DIR] [--live SECONDS] [--activity] [--only NAME]: what screen sharing in the workspace sends for each
// pixel format and encoding (development measurements). The password comes from the Keys folder, never printed.
//   --out DIR      saves each picture as DIR/<name>.png (to check the decoders by eye)
//   --live S       a live view of S seconds with the viewer's options: updates, frames, bytes per second
//   --activity     starts the screen saver in the guest during the live view (a moving picture)

@MainActor
func rfbProbe(_ args: [String], paths: Paths) async throws {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let host = VMHost(bundle: VMBundle(url: paths.vm), paths: paths)
    guard let ip = try value("--host") ?? host.guestAddress() else { fail("no guest address") }
    let password = try GuestSecrets(paths: paths).adminPassword(createIfMissing: false)
    let out = value("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let only = value("--only")

    let configs: [(String, RFBOptions)] = [
        ("raw", RFBOptions(encodings: [], exact: true)),
        ("zlib", RFBOptions(encodings: [RFBEncoding.zlib])),
        ("zrle-24", RFBOptions(encodings: [RFBEncoding.zrle])),
        ("zrle-16", RFBOptions(encodings: [RFBEncoding.zrle], format: .rgb565)),
        ("zrle-8", RFBOptions(encodings: [RFBEncoding.zrle], format: .bgr233)),
        ("agent", .agent),
        ("viewer-best", .viewer(.best)),
        ("viewer-balanced", .viewer(.balanced)),
        ("viewer-saver", .viewer(.saver)),
        ("viewer-gray", .viewer(.gray)),
        ("hextile", RFBOptions(encodings: [RFBEncoding.hextile], exact: true)),
        ("zrle-444", RFBOptions(encodings: [RFBEncoding.zrle], format: RFBPixelFormat(
            bitsPerPixel: 16, depth: 12, bigEndian: false, trueColor: true, redMax: 15, greenMax: 15, blueMax: 15,
            redShift: 8, greenShift: 4, blueShift: 0))),
        ("zrle-332in16", RFBOptions(encodings: [RFBEncoding.zrle], format: RFBPixelFormat(
            bitsPerPixel: 16, depth: 8, bigEndian: false, trueColor: true, redMax: 7, greenMax: 7, blueMax: 3,
            redShift: 5, greenShift: 2, blueShift: 0))),
        ("apple-1000", RFBOptions(encodings: [1000, RFBEncoding.zrle], exact: true)),
        ("apple-1001", RFBOptions(encodings: [1001, RFBEncoding.zrle], exact: true)),
        ("apple-1002", RFBOptions(encodings: [1002, RFBEncoding.zrle], exact: true)),
        ("cont-upd", RFBOptions(encodings: [RFBEncoding.zrle, RFBEncoding.continuousUpdates], exact: true)),
    ]
    for (name, options) in configs where only == nil || only == name {
        let client = RFBClient(host: ip, username: Brand.guestUser, password: password, options: options)
        let t0 = Date()
        do {
            try await client.connect()
            let t1 = Date()
            let image = try await client.screenshot()
            let t2 = Date()
            let stats = await client.stats
            print(String(format: "%-12@ %dx%d connect %.2fs picture %.3fs %@", name as NSString, image.width, image.height,
                         t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), stats.summary as NSString))
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png(image, to: out.appendingPathComponent("\(name).png"))
            }
            if name == "agent" { print("  server name: \(await client.serverName), server format \(await client.serverFormat.bitsPerPixel) bpp") }
        } catch {
            print("\(name): \(error.localizedDescription) after \(await client.stats.summary)")
        }
        await client.disconnect()
    }

    // --resize: the agent's connection stays open while the display changes (as when the iPhone views the
    // workspace) and back; each picture must come in the new size without a reconnect. Needs `aosctl run`.
    if args.contains("--resize") {
        let agent = RFBClient(host: ip, username: Brand.guestUser, password: password, options: .agent)
        func display(_ line: String) throws -> String {
            let socket = try LineSocketClient(path: paths.run.appendingPathComponent("display.sock"))
            return String(decoding: try socket.roundTrip(Data(line.utf8)), as: UTF8.self)
        }
        try await agent.connect()
        var image = try await agent.screenshot()
        print("agent picture \(image.width)x\(image.height)")
        for spec in ["1200 2322 2 160", "2322 1200 2 160", "reset"] {
            print("display: \(try display(spec))")
            await agent.expectNewSize()
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let t = Date()
            image = try await agent.screenshot()
            print(String(format: "agent picture %dx%d after %.2fs, still connected: %@", image.width, image.height,
                         Date().timeIntervalSince(t), "\(await agent.isConnected)"))
            if let out {
                try png(image, to: out.appendingPathComponent("resize-\(spec.replacingOccurrences(of: " ", with: "x")).png"))
            }
        }
        try await agent.click(x: 10, y: 10)
        print("click after the changes: ok, size \(await agent.width)x\(await agent.height)")
        await agent.disconnect()
    }

    if let seconds = value("--live").flatMap(Double.init) {
        let quality = RFBQuality(rawValue: value("--quality") ?? "best") ?? .best
        // --before: what the app did before (zlib with 32-bit pixels, a picture at most every 0.1 s)
        let before = args.contains("--before")
        print("live view, quality \(before ? "before" : quality.rawValue)")
        let viewer = RFBClient(host: ip, username: Brand.guestUser, password: password,
                               options: before ? RFBOptions(encodings: [RFBEncoding.zlib], exact: true) : .viewer(quality))
        let mover = RFBClient(host: ip, username: Brand.guestUser, password: password, options: .agent)
        let ssh = Provisioner(paths: paths, kit: GuestKit(policies: AgentSettings.load(paths).chromePolicies)).maintenance(host: ip)
        let asUser = "u=\(Brand.guestUser); launchctl asuser \"$(id -u $u)\" sudo -u $u"
        if args.contains("--activity") {
            _ = try? await ssh.run("\(asUser) open -a ScreenSaverEngine", timeout: 20, what: "screen saver")
        }
        // --scroll: a long text in TextEdit, scrolled by a second connection (like reading a web page)
        let scrolling = args.contains("--scroll")
        if scrolling {
            let text = (1...3000).map { "Line \($0): The quick brown fox jumps over the lazy dog, again and again and again." }
                .joined(separator: "\n")
            _ = try? await ssh.run("cat > /tmp/aos-probe.txt; chmod 644 /tmp/aos-probe.txt", input: Data(text.utf8), timeout: 20, what: "text")
            _ = try? await ssh.run("\(asUser) open -a TextEdit /tmp/aos-probe.txt", timeout: 20, what: "TextEdit")
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        var frames = 0, cursors = 0, pointers = 0, resizes = 0
        let start = Date()
        let events = viewer.events(minimumInterval: before ? 0.1 : 1.0 / 60)
        let moving = Task {
            try? await mover.connect()
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // after the input grace
            if scrolling {
                var i = 0
                while !Task.isCancelled {
                    try? await mover.scroll(x: 640, y: 400, direction: i / 40 % 2 == 0 ? .down : .up, steps: 2)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    i += 1
                }
                return
            }
            for i in 0..<10 {
                try? await mover.move(x: 200 + i * 40, y: 300 + i * 20)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let reader = Task { @MainActor in
            do {
                for try await event in events {
                    switch event {
                    case .frame:
                        frames += 1
                        viewer.framebuffer.takeChanges { _ in }
                    case .cursor(let c): cursors += 1; if cursors <= 3 { print("  cursor \(c.width)x\(c.height) hot \(c.hotX),\(c.hotY)") }
                    case .pointer(let x, let y): pointers += 1; if pointers <= 5 { print("  pointer at \(x),\(y)") }
                    case .resized(let w, let h): resizes += 1; print("  resized \(w)x\(h)")
                    case .clipboard: print("  clipboard")
                    case .bell: print("  bell")
                    }
                    if Date().timeIntervalSince(start) > seconds { break }
                }
            } catch {
                print("live: \(error.localizedDescription)")
            }
        }
        await reader.value
        moving.cancel()
        let elapsed = Date().timeIntervalSince(start)
        let stats = await viewer.stats
        print(String(format: "live %.1fs: %d updates (%.1f/s), %d frames (%.1f/s), %.0f KB/s, latency %.0f ms, cursors %d, pointer moves %d",
                     elapsed, stats.updates, Double(stats.updates) / elapsed, frames, Double(frames) / elapsed,
                     Double(stats.bytes) / elapsed / 1024, stats.lastLatency * 1000, cursors, pointers))
        print("  " + stats.summary)
        if args.contains("--activity") { _ = try? await ssh.run("killall ScreenSaverEngine", timeout: 20, what: "screen saver") }
        if scrolling { _ = try? await ssh.run("killall TextEdit", timeout: 20, what: "TextEdit") }
        await viewer.disconnect()
        await mover.disconnect()
    }
}

func png(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

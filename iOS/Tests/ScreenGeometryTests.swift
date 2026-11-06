import AOSRFB
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import aOS

/// Where the picture sits, how far the pointer goes, how scrolling feels.
struct ScreenGeometryTests {
    /// A portrait phone (402x874 points) with its safe area (62 above, 34 below).
    private func phone(_ image: CGSize, _ scaling: ScreenGeometry.Scaling = .fit) -> ScreenGeometry {
        var g = ScreenGeometry()
        g.bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        g.area = CGRect(x: 0, y: 62, width: 402, height: 778)
        g.imageSize = image
        g.scaling = scaling
        g.displayScale = 3
        g.reset()
        return g
    }

    @Test func aScreenInThePhonesShapeFillsTheSafeArea() {
        let g = phone(CGSize(width: 1200, height: 2322))
        #expect(abs(g.frame.minY - 62) < 0.5 && abs(g.frame.height - 778) < 1)
        #expect(abs(g.frame.width - 402) < 1)
        // 1206 phone pixels for 1200 remote ones: almost exactly one to one
        #expect(abs(g.pixelRatio - 1.005) < 0.01)
    }

    @Test func fitLetterboxesAndFillCovers() {
        let mac = CGSize(width: 2560, height: 1600)
        let fit = phone(mac, .fit)
        #expect(abs(fit.frame.width - 402) < 0.5)
        #expect(abs(fit.frame.midY - (62 + 778 / 2)) < 0.5)
        let fill = phone(mac, .fill)
        #expect(fill.frame.height >= 874 - 0.5)
        #expect(fill.frame.minX <= 0 && fill.frame.maxX >= 402)
        let actual = phone(mac, .actual)
        #expect(abs(actual.scale - 1.0 / 3) < 0.0001)
        #expect(abs(actual.pixelRatio - 1) < 0.0001)
    }

    @Test func touchesMapToPixelsAndBack() {
        let g = phone(CGSize(width: 1280, height: 800))
        let p = CGPoint(x: 123, y: 456)
        let back = g.view(g.remote(p))
        #expect(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001)
        #expect(g.remote(CGPoint(x: g.frame.minX, y: g.frame.minY)) == .zero)
    }

    @Test func pinchingKeepsThePixelUnderTheFingers() {
        var g = phone(CGSize(width: 1280, height: 800))
        let anchor = CGPoint(x: 300, y: 450)
        let before = g.remote(anchor)
        g.zoom(to: 4, anchor: anchor)
        let after = g.remote(anchor)
        #expect(abs(before.x - after.x) < 0.5 && abs(before.y - after.y) < 0.5)
        #expect(g.zoom == 4)
        // Never past the limits
        g.zoom(to: 100, anchor: anchor)
        #expect(g.zoom == ScreenGeometry.maximumZoom)
        g.zoom(to: 0.1, anchor: anchor)
        #expect(g.zoom == 1)
    }

    @Test func aZoomedPictureShowsNoGapsAndFollowsThePointer() {
        var g = phone(CGSize(width: 1280, height: 800))
        g.zoom(to: 4, anchor: CGPoint(x: 201, y: 451))
        g.pan = CGPoint(x: 10_000, y: -10_000)
        g.clampPan()
        #expect(g.frame.minX <= 0.5 && g.frame.maxX >= 401.5)
        // The pointer at the far right edge of the screen: the picture moves so it is visible
        let moved = g.follow(CGPoint(x: 1279, y: 400))
        #expect(moved)
        let p = g.view(CGPoint(x: 1279, y: 400))
        #expect(p.x <= 402 && p.x >= 0)
        let again = g.follow(CGPoint(x: 1279, y: 400))
        #expect(!again, "already visible: nothing moves")
    }

    @Test func focusingOnAHelpRegion() {
        var g = phone(CGSize(width: 1280, height: 800))
        let region = CGRect(x: 600, y: 300, width: 300, height: 120)
        g.focus(on: region)
        #expect(g.zoom > 1)
        let center = g.view(CGPoint(x: region.midX, y: region.midY))
        #expect(abs(center.x - 201) < 2)
    }

    // MARK: Pointer and scrolling

    @Test func slowMovesArePreciseFastOnesGoFar() {
        let a = PointerAcceleration(speed: 1)
        #expect(a.gain(velocity: 50) == 1)
        #expect(a.gain(velocity: 600) > 1.5)
        #expect(a.gain(velocity: 1500) > a.gain(velocity: 600))
        #expect(a.gain(velocity: 100_000) == PointerAcceleration.maximumGain)
        // A slow finger moves the pointer as far on the phone as the finger moved
        let d = a.remoteDelta(CGPoint(x: 10, y: 0), velocity: CGPoint(x: 40, y: 0), scale: 0.5)
        #expect(d == CGPoint(x: 20, y: 0))
        #expect(PointerAcceleration(speed: 2).gain(velocity: 50) == 2)
    }

    @Test func scrollingFollowsTheFingersOrTheWheel() {
        var natural = ScrollAccumulator(natural: true, stepLength: 10)
        // Fingers up by 25 points: 2 steps that show what's further down, 5 points kept
        let up = natural.steps(for: CGPoint(x: 0, y: -25))
        #expect(up.dy == 2 && up.dx == 0)
        let more = natural.steps(for: CGPoint(x: 0, y: -5))
        #expect(more.dy == 1)
        var wheel = ScrollAccumulator(natural: false, stepLength: 10)
        let down = wheel.steps(for: CGPoint(x: 0, y: -25))
        #expect(down.dy == -2)
        let sideways = wheel.steps(for: CGPoint(x: 31, y: 0))
        #expect(sideways.dx == 3)
    }

    @Test func aFlickGlidesAndStops() {
        var m = ScrollMomentum(velocity: CGPoint(x: 0, y: -2000))
        #expect(!m.isDone)
        var travelled: CGFloat = 0
        var frames = 0
        while !m.isDone && frames < 600 {
            travelled += m.advance(1.0 / 60).y
            frames += 1
        }
        #expect(m.isDone && frames < 600)
        // about v / ln(1/decay): 2000 / 2 = 1000 points
        #expect(travelled < -800 && travelled > -1100)
        #expect(ScrollMomentum(velocity: CGPoint(x: 0, y: 150)).isDone, "a slow lift doesn't glide")
    }
}

@MainActor
struct ScreenSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "screen-settings-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsSuitAPhone() {
        let s = AppSettings(defaults: defaults())
        #expect(s.screenQuality == .automatic)
        #expect(s.inputMode == .trackpad)
        #expect(s.matchWorkspaceShape && s.retinaWorkspace && s.naturalScrolling && s.haptics)
        #expect(s.macScaling == .fit)
        #expect(s.pointerStyle == .local)
        #expect(s.frameRate == .smooth)
    }

    @Test func choicesAreKept() {
        let d = defaults()
        let s = AppSettings(defaults: d)
        s.screenQuality = .gray
        s.macScaling = .fill
        s.pointerSpeed = 1.7
        s.naturalScrolling = false
        s.pointerStyle = .remote
        s.showsScreenStats = true
        let again = AppSettings(defaults: d)
        #expect(again.screenQuality == .gray)
        #expect(again.macScaling == .fill)
        #expect(again.pointerSpeed == 1.7)
        #expect(!again.naturalScrolling)
        #expect(again.pointerStyle == .remote)
        #expect(again.showsScreenStats)
    }

    @Test func automaticQualityFollowsTheNetwork() {
        #expect(AppSettings.ScreenQuality.automatic.resolved(cellular: false) == .best)
        #expect(AppSettings.ScreenQuality.automatic.resolved(cellular: true) == .saver)
        #expect(AppSettings.ScreenQuality.gray.resolved(cellular: false) == .gray)
        let s = AppSettings(defaults: defaults())
        s.pointerStyle = .remote
        s.frameRate = .saver
        let options = ScreenOptions(settings: s, cellular: true)
        #expect(options.quality == .saver && !options.localCursor && options.interval == 0.2)
    }

    @Test func theDisplayRequestIsSignedWithItsSize() throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let request = CompanionRequest.display(target: .workspace, size: "1200x2322@2")
        let line = try request.line(id: 3, auth: try signer.auth(for: request))
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: line).object)
        #expect(object["op"]?.string == "display")
        #expect(object["target"]?.string == "workspace")
        #expect(object["text"]?.string == "1200x2322@2")
        let fields = request.signatureFields(key: "k", ts: 1, nonce: "n")
        #expect(fields.op == "companion.display" && fields.target == "workspace")
        #expect(fields.data == CompanionSignature.dataDigest(text: "1200x2322@2"))
        // The mock Mac checks it like the real one and answers the size
        let server = MockCompanionServer(keepsSecrets: true)
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey) }
        let answer = String(decoding: try #require(server.handle(line: line)), as: UTF8.self)
        #expect(answer.contains("\"ok\":true") && answer.contains("\"width\":1200"))
    }
}

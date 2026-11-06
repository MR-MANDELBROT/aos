import AOSRFB
import CoreGraphics
import Foundation

// The workspace's display while the iPhone watches it: in the phone's shape (companion op `display`,
// Docs/COMPANION.md), and back to its own size when the phone stops renewing the request. The agent's tools keep
// working: they take the screen as it is, and pictures larger than the workspace's own are scaled down for the agent
// (its coordinates are scaled back up).

extension WorkspaceController {
    /// Seconds a phone's display request lasts; the phone renews it while it shows the workspace.
    static let displayLease: TimeInterval = 45

    /// The longest side of the agent's pictures: the workspace's own screen (1280x800) needs no scaling.
    static let agentPictureSide = 1280.0

    /// Screen pixels times this are the agent's picture pixels.
    static func agentScale(width: Int, height: Int) -> Double {
        let side = Double(max(width, height))
        return side > agentPictureSide ? agentPictureSide / side : 1
    }

    func agentScale(_ client: RFBClient) async -> Double {
        Self.agentScale(width: await client.width, height: await client.height)
    }

    /// The picture as the agent gets it.
    func agentView(_ image: CGImage) -> CGImage {
        let f = Self.agentScale(width: image.width, height: image.height)
        return f < 1 ? ScreenImage.scaled(image, by: f) ?? image : image
    }

    /// Tells the agent why the screen has another shape.
    func displayNote() -> String {
        host.displayOverride == nil ? "" : " (The user is watching the workspace on their iPhone, so the screen has the phone's shape for now. Use coordinates of this picture.)"
    }

    /// companion.display, signed, target "workspace": `text` is "WIDTHxHEIGHT@SCALE" (see `DisplayRequest`) or
    /// "reset". Answers the size the display got.
    func handleDisplay(_ r: AgentRequest) -> AgentResponse {
        guard r.target == "workspace" else { return .failure(r.id, "Only the workspace's display can change.") }
        guard host.isRunning else { return .failure(r.id, "The workspace is not running.") }
        let text = (r.text ?? "").trimmingCharacters(in: .whitespaces)
        let size: DisplayRequest
        if text == "reset" {
            if host.displayOverride != nil { log("the iPhone gave the workspace its own display size back") }
            host.restoreDisplay()
            let s = host.displaySize
            size = DisplayRequest(width: Int(s.width), height: Int(s.height), scale: 1)
        } else {
            guard let wanted = DisplayRequest(text) else { return .failure(r.id, "Not a display size: \(text)") }
            do {
                let before = host.displayOverride
                size = try host.setDisplay(wanted, lease: Self.displayLease)
                if before != size { log("the iPhone shows the workspace: display \(size)") }
            } catch {
                return .failure(r.id, error.localizedDescription)
            }
        }
        let object: [String: Any] = ["width": size.width, "height": size.height, "scale": size.scale,
                                     "lease": Int(Self.displayLease)]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return AgentResponse(id: r.id, ok: true, text: String(decoding: data, as: UTF8.self))
    }
}

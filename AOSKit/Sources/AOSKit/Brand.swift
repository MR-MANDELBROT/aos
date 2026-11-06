import Foundation

/// The one place that knows the product's name. "aOS" is a working title: renaming the product means
/// changing these values (and the bundle identifiers in project.yml), nothing else.
public enum Brand {
    public static let name = "aOS"
    public static let bundleIdentifierPrefix = "dev.marquart.aos"
    /// Name of the MCP server as Claude Code sees it (tools appear as mcp__aos__<tool>).
    public static let mcpServerName = "aos"
    /// Default name of the Claude Code session in the Claude app (Remote Control).
    public static let defaultSessionName = "aOS"
    /// Account name inside the VM.
    public static let guestUser = "aos"
    public static let guestFullName = "aOS"
    /// The product's website (GitHub Pages; German under de/).
    public static let website = "https://mr-mandelbrot.github.io/aos/"

    /// The website's iPhone section (where to get the iPhone app), in German for German speakers.
    public static var phoneAppPage: URL {
        let german = Locale.preferredLanguages.first?.hasPrefix("de") == true
        return URL(string: website + (german ? "de/" : "") + "#phone")!
    }
}

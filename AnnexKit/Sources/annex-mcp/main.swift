import AnnexKit
import Foundation

// The MCP server Claude Code starts (stdio). Tool calls go to the app over its agent socket.
setvbuf(stdout, nil, _IOLBF, 0)
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
MCPServer(version: version).run()

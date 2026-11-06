import Foundation

/// When aOS keeps the Mac awake (Settings > General). See Docs/DESIGN.md, "Staying awake, freezing and the hotspot".
public enum StayAwake: String, Codable, Sendable, CaseIterable {
    /// The Mac sleeps as usual.
    case off
    /// While something must stay reachable the Mac doesn't fall asleep by itself (a power assertion of the app);
    /// closing the lid still puts it to sleep.
    case lidOpen
    /// Also with the lid closed, on battery too. Only `pmset disablesleep` holds a closed MacBook on battery, which
    /// needs root: aOS's background helper (aos-powerd) does it. While the lid is closed, aOS freezes the other apps,
    /// switches the display off and looks after the network.
    case lidClosed
}

/// How this Mac joins the user's iPhone hotspot. aOS applies it to macOS itself: the auto-join flag of every known
/// network macOS marks as the user's own Personal Hotspot, and "Ask to join hotspots" (Instant Hotspot).
public enum HotspotJoin: String, Codable, Sendable, CaseIterable {
    /// macOS joins the hotspot whenever it can and may switch it on by itself (auto-join on, "Ask to join
    /// hotspots": Automatic). Uses more energy, mostly the iPhone's.
    case automatic
    /// Only while the user switched it on: auto-join off and "Ask to join hotspots": Never, so macOS never joins
    /// or wakes the hotspot by itself. With the lid closed aOS joins it while it broadcasts and the Mac has no
    /// other network; switched off, the Mac stays disconnected from it.
    case manual
}

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// aOS's widget extension: the Live Activity of the open terminals.
@main
struct AOSWidgets: WidgetBundle {
    var body: some Widget {
        TerminalActivityWidget()
    }
}

/// The open terminals on the Lock Screen and in the Dynamic Island, each with an End button. A tap opens the terminal.
struct TerminalActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(nil)
                .widgetURL(Self.link(context.state.items.first))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Terminal")
                    } icon: {
                        Image(systemName: "apple.terminal")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.mint)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    KeptBy(keptBy: context.state.keptBy, isStale: context.isStale)
                        .font(.caption)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(context.state.items.prefix(3)) { item in
                            SessionRow(item: item, isStale: context.isStale, compact: true)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "apple.terminal.fill")
                    .foregroundStyle(context.isStale ? Color.gray : Palette.mint)
            } compactTrailing: {
                if context.state.items.count > 1 {
                    Text("\(context.state.items.count)").font(.caption.weight(.semibold).monospacedDigit())
                } else if let since = context.state.items.first?.since, !context.isStale {
                    Text(since, style: .timer)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: 44)
                        .multilineTextAlignment(.trailing)
                } else {
                    Image(systemName: "pause.fill").font(.caption)
                }
            } minimal: {
                Image(systemName: "apple.terminal.fill")
                    .foregroundStyle(context.isStale ? Color.gray : Palette.mint)
            }
            .widgetURL(Self.link(context.state.items.first))
            .keylineTint(Palette.mint)
        }
    }

    static func link(_ item: TerminalActivityAttributes.ContentState.Item?) -> URL? {
        URL(string: "aos://terminal/" + (item?.id ?? ""))
    }
}

/// The brand colors without the app's asset catalog.
enum Palette {
    static let mint = Color(red: 0.24, green: 0.85, blue: 0.71)
    static let indigo = Color(red: 0.55, green: 0.56, blue: 1.0)
}

private struct LockScreenView: View {
    let state: TerminalActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("aOS Terminal", systemImage: "apple.terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                KeptBy(keptBy: state.keptBy, isStale: isStale).font(.caption)
            }
            ForEach(state.items.prefix(3)) { item in
                SessionRow(item: item, isStale: isStale, compact: false)
            }
        }
        .padding(16)
    }
}

/// What keeps the terminal going: the location option, or (stale) only the Mac.
private struct KeptBy: View {
    let keptBy: String?
    let isStale: Bool

    var body: some View {
        Group {
            if isStale {
                Text("Paused")
            } else if keptBy == "location" {
                Label("Location", systemImage: "location.fill")
            } else {
                Text("Open")
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct SessionRow: View {
    let item: TerminalActivityAttributes.ContentState.Item
    let isStale: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(compact ? .subheadline.weight(.medium) : .body.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(intent: EndTerminalIntent(terminal: item.id)) {
                Label("End", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private var dot: Color {
        if isStale { return .gray }
        return item.state == "connected" ? Palette.mint : .orange
    }

    private var detail: String {
        if isStale {
            return item.held ? String(localized: "Kept on the Mac. Open aOS to continue.") : String(localized: "Open aOS to continue.")
        }
        switch item.state {
        case "connected":
            return item.held ? String(localized: "Connected, kept on the Mac") : String(localized: "Connected")
        default:
            return item.held ? String(localized: "Reconnecting, kept on the Mac") : String(localized: "Reconnecting")
        }
    }
}

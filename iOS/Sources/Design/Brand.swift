import SwiftUI

/// Brand colors and the small building blocks the views share (iOS Liquid Glass), like the Mac app's Style.swift.
enum BrandColor {
    /// Indigo #4D51E0 light, #8C90FF dark (the asset catalog's AccentColor, by name: the global accent alone didn't
    /// reach every control on iOS, so the root view sets it as the tint too).
    static let indigo = Color("AccentColor")
    /// Mint #3DD9B4 light, #8EECD3 dark: "ready" moments.
    static let mint = Color("BrandMint")
    /// Requests that need the person: orange glass, like on the Mac.
    static let attention = Color.orange
}

/// A glass card with a rounded shape.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular,
                         in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A large symbol in a tinted glass circle, used as the hero of a page.
struct HeroSymbol: View {
    let systemName: String
    var tint: Color = BrandColor.indigo
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(tint), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A small colored status dot.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.6), radius: 3)
            .accessibilityHidden(true)
    }
}

/// The app icon (for the lock screen and the welcome page): Icon Composer's rendering, light and dark
/// (Tools/render-icon.sh), since the icon itself isn't loadable as an image.
struct AppIconImage: View {
    var size: CGFloat = 72
    var body: some View {
        Image("AppIconArt")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A line of the "what is where" kind: a symbol and a plain sentence.
struct FactRow: View {
    let symbol: String
    let text: LocalizedStringKey
    var tint: Color = BrandColor.indigo

    var body: some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// A key or fingerprint. Never hyphenated (German text gets hyphenated, and a hyphen would look like part of the
/// key): one line scaled to fit, or broken into lines of fixed length.
struct KeyText: View {
    let text: String
    var font: Font = .caption.monospaced()
    /// 0 keeps it on one line.
    var lineLength = 0

    var body: some View {
        Group {
            if lineLength > 0 {
                Text(verbatim: Self.lines(text, length: lineLength)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: text).lineLimit(1).minimumScaleFactor(0.5).allowsTightening(true)
            }
        }
        .font(font)
        .textSelection(.enabled)
        .accessibilityLabel(Text(verbatim: text))
    }

    static func lines(_ text: String, length: Int) -> String {
        var lines: [Substring] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            lines.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return lines.joined(separator: "\n")
    }
}

extension View {
    /// The calm grouped background the tabs share.
    func aosBackground() -> some View {
        background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

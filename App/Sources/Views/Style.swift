import AOSKit
import AppKit
import SwiftUI

/// Brand colors and the small building blocks the views share (macOS 27 Liquid Glass).
enum BrandColor {
    static let indigo = Color.accentColor
    static let mint = Color("BrandMint")
}

/// A glass card with a rounded shape.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A large symbol in a tinted glass circle, used as the hero of a page.
struct HeroSymbol: View {
    let systemName: String
    var tint: Color = BrandColor.indigo

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .glassEffect(.regular.tint(tint), in: Circle())
    }
}

/// A small colored status dot with a label, for state lines.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

/// The app icon as a SwiftUI image.
struct AppIconImage: View {
    var size: CGFloat = 48
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
    }
}

/// "Recommended" next to a setting's title.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.semibold))
            .foregroundStyle(BrandColor.indigo)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(BrandColor.indigo.opacity(0.14), in: Capsule())
    }
}

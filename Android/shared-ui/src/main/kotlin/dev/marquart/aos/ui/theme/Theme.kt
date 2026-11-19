package dev.marquart.aos.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * The aOS brand on Android (Docs/BRAND.md): indigo is the accent, mint the "ready" moments, status colors stay the
 * platform's usual ones (green running, orange needs you, red error). Material 3 with the brand's colors instead of
 * dynamic colors, so the app looks like the iPhone's and the Mac's.
 */
object Brand {
    val IndigoLight = Color(0xFF4D51E0)
    val IndigoDark = Color(0xFF8C90FF)
    val MintLight = Color(0xFF3DD9B4)
    val MintDark = Color(0xFF8EECD3)
    val LavenderLight = Color(0xFFB2B9FF)
    val LavenderDark = Color(0xFF666CDC)
}

/** The colors the views use besides Material's roles. */
@Immutable
data class AosColors(
    val indigo: Color,
    val mint: Color,
    val lavender: Color,
    /** Requests that need the person (orange, like on the Mac). */
    val attention: Color,
    val green: Color,
    val orange: Color,
    val red: Color,
    val yellow: Color,
    val gray: Color,
    /** Secondary and tertiary text. */
    val secondary: Color,
    val tertiary: Color,
    /** The grouped background behind the cards, and the cards. */
    val background: Color,
    val card: Color,
    val separator: Color,
    val isDark: Boolean,
)

private val LightColors = AosColors(
    indigo = Brand.IndigoLight, mint = Brand.MintLight, lavender = Brand.LavenderLight,
    attention = Color(0xFFFF9500), green = Color(0xFF34C759), orange = Color(0xFFFF9500), red = Color(0xFFFF3B30),
    yellow = Color(0xFFFFCC00), gray = Color(0xFF8E8E93),
    secondary = Color(0xFF6C6C72), tertiary = Color(0xFFA3A3A8),
    background = Color(0xFFF2F2F7), card = Color(0xFFFFFFFF), separator = Color(0x1F000000), isDark = false,
)

private val DarkColors = AosColors(
    indigo = Brand.IndigoDark, mint = Brand.MintDark, lavender = Brand.LavenderDark,
    attention = Color(0xFFFF9F0A), green = Color(0xFF30D158), orange = Color(0xFFFF9F0A), red = Color(0xFFFF453A),
    yellow = Color(0xFFFFD60A), gray = Color(0xFF8E8E93),
    secondary = Color(0xFFA1A1A8), tertiary = Color(0xFF6E6E74),
    background = Color(0xFF000000), card = Color(0xFF1C1C1E), separator = Color(0x29FFFFFF), isDark = true,
)

val LocalAosColors = staticCompositionLocalOf { LightColors }

/** The brand's colors where the views are (`AosTheme.colors.indigo`). */
object AosTheme {
    val colors: AosColors
        @Composable get() = LocalAosColors.current
}

@Composable
fun AosTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) DarkColors else LightColors
    val scheme = if (dark) {
        darkColorScheme(
            primary = Brand.IndigoDark, onPrimary = Color(0xFF14154A),
            primaryContainer = Color(0xFF2E3190), onPrimaryContainer = Color(0xFFE0E0FF),
            secondary = Brand.MintDark, onSecondary = Color(0xFF00382C),
            secondaryContainer = Color(0xFF1F4D42), onSecondaryContainer = Brand.MintDark,
            tertiary = Brand.LavenderDark,
            background = colors.background, onBackground = Color.White,
            surface = colors.background, onSurface = Color.White,
            surfaceVariant = Color(0xFF2C2C2E), onSurfaceVariant = colors.secondary,
            surfaceContainerLowest = Color(0xFF0E0E10), surfaceContainerLow = Color(0xFF161618),
            surfaceContainer = colors.card, surfaceContainerHigh = Color(0xFF242426), surfaceContainerHighest = Color(0xFF2C2C2E),
            outline = Color(0xFF545458), outlineVariant = Color(0xFF38383A),
            error = colors.red,
        )
    } else {
        lightColorScheme(
            primary = Brand.IndigoLight, onPrimary = Color.White,
            primaryContainer = Color(0xFFE2E3FF), onPrimaryContainer = Color(0xFF1B1D7A),
            secondary = Color(0xFF13896F), onSecondary = Color.White,
            secondaryContainer = Color(0xFFCDF6EB), onSecondaryContainer = Color(0xFF00382C),
            tertiary = Brand.LavenderLight,
            background = colors.background, onBackground = Color(0xFF111114),
            surface = colors.background, onSurface = Color(0xFF111114),
            surfaceVariant = Color(0xFFE5E5EA), onSurfaceVariant = colors.secondary,
            surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF7F7FA),
            surfaceContainer = colors.card, surfaceContainerHigh = Color(0xFFF0F0F4), surfaceContainerHighest = Color(0xFFE8E8ED),
            outline = Color(0xFFC6C6CB), outlineVariant = Color(0xFFDCDCE0),
            error = colors.red,
        )
    }
    CompositionLocalProvider(LocalAosColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

package dev.marquart.aos.ui.platform

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
import dev.marquart.aos.desktop.DesktopStrings
import org.jetbrains.skia.Image
import java.util.Locale

// The desktop side of the shared UI's resources (Android has the same declarations: see Platform.kt). The texts are
// Android's XML strings, compiled into tables by desktop/build.gradle.kts (generateAosResources).

/** Where texts are resolved: the language the app shows. */
class PlatformContext(val locale: Locale)

val LocalPlatformContext = staticCompositionLocalOf { PlatformContext(DesktopStrings.locale) }

@Composable
fun platformContext(): PlatformContext = LocalPlatformContext.current

fun PlatformContext.text(id: Int, vararg args: Any): String = DesktopStrings.text(id, *args)
fun PlatformContext.quantityText(id: Int, count: Int, vararg args: Any): String = DesktopStrings.quantityText(id, count, *args)
fun PlatformContext.rawText(id: Int): String = DesktopStrings.rawText(id)
val PlatformContext.locale: Locale get() = locale

/** "4 min. ago", "in 2 hours", "yesterday" (as Android's DateUtils says it, roughly). */
fun PlatformContext.relativeTime(millis: Long): String = DesktopStrings.relativeTime(millis, System.currentTimeMillis())

@Composable
fun stringResource(id: Int): String = DesktopStrings.text(id)

@Composable
fun stringResource(id: Int, vararg formatArgs: Any): String = DesktopStrings.text(id, *formatArgs)

@Composable
fun pluralStringResource(id: Int, count: Int): String = DesktopStrings.quantityText(id, count, count)

@Composable
fun pluralStringResource(id: Int, count: Int, vararg formatArgs: Any): String = DesktopStrings.quantityText(id, count, *formatArgs)

@Composable
fun painterResource(id: Int): Painter = remember(id) {
    BitmapPainter(Image.makeFromEncoded(DesktopStrings.resourceBytes(id)).toComposeImageBitmap())
}

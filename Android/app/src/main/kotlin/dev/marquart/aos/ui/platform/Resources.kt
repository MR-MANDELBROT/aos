package dev.marquart.aos.ui.platform

import android.content.Context
import android.text.format.DateUtils
import androidx.annotation.PluralsRes
import androidx.annotation.RawRes
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import java.util.Locale

// The Android side of the shared UI's resources (the desktop has the same declarations: see Platform.kt).

/** Where texts are resolved: Android's Context. */
typealias PlatformContext = Context

/** The context the UI resolves texts with (recomposes when the language changes). */
@Composable
fun platformContext(): PlatformContext {
    LocalConfiguration.current
    return LocalContext.current
}

fun PlatformContext.text(@StringRes id: Int, vararg args: Any): String = if (args.isEmpty()) getString(id) else getString(id, *args)
fun PlatformContext.quantityText(@PluralsRes id: Int, count: Int, vararg args: Any): String =
    resources.getQuantityString(id, count, *args)
fun PlatformContext.rawText(@RawRes id: Int): String = resources.openRawResource(id).bufferedReader().use { it.readText() }
val PlatformContext.locale: Locale get() = resources.configuration.locales[0] ?: Locale.getDefault()

/** "4 min. ago", "in 2 hours", "yesterday". */
fun PlatformContext.relativeTime(millis: Long): String = DateUtils.getRelativeTimeSpanString(millis, System.currentTimeMillis(),
    DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()

@Composable
fun stringResource(@StringRes id: Int): String = androidx.compose.ui.res.stringResource(id)

@Composable
fun stringResource(@StringRes id: Int, vararg formatArgs: Any): String = androidx.compose.ui.res.stringResource(id, *formatArgs)

@Composable
fun pluralStringResource(@PluralsRes id: Int, count: Int): String = androidx.compose.ui.res.pluralStringResource(id, count)

@Composable
fun pluralStringResource(@PluralsRes id: Int, count: Int, vararg formatArgs: Any): String =
    androidx.compose.ui.res.pluralStringResource(id, count, *formatArgs)

@Composable
fun painterResource(id: Int): Painter = androidx.compose.ui.res.painterResource(id)

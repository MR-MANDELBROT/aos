package dev.marquart.aos.ui

import android.content.Context
import android.text.format.DateUtils
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.util.Locale

/**
 * A text the views show, decided apart from them (the status words, the errors): a string resource with its
 * arguments, a plural, a time, or text as it came. Plain data, so the JVM tests can check which text was chosen
 * without Android; `resolve` makes it a string in the app's language.
 */
sealed interface Txt {
    data class Res(@StringRes val id: Int, val args: List<Any> = emptyList()) : Txt
    data class Plural(@PluralsRes val id: Int, val count: Int, val args: List<Any> = listOf(count)) : Txt
    data class Raw(val text: String) : Txt
    data class Time(val instant: Instant, val style: TimeStyle) : Txt
    data class Join(val parts: List<Txt>, val separator: String) : Txt

    enum class TimeStyle {
        /** 14:05 */
        TIME,
        /** 14:05 today, else "Tue 14:05". */
        TIME_OR_WEEKDAY,
        /** "4 min. ago", "in 2 hours", "yesterday" */
        RELATIVE,
        /** The same inside a sentence ("next in 2 hours"). */
        RELATIVE_INLINE,
        /** 19 Nov 2026, 14:05 */
        DATE_TIME,
        /** 19 Nov 2026 */
        DATE,
    }

    fun resolve(context: Context): String = when (this) {
        is Res -> if (args.isEmpty()) context.getString(id) else context.getString(id, *args.map { it.resolveArg(context) }.toTypedArray())
        is Plural -> context.resources.getQuantityString(id, count, *args.map { it.resolveArg(context) }.toTypedArray())
        is Raw -> text
        is Time -> formatTime(context, instant, style)
        is Join -> parts.map { it.resolve(context) }.filter { it.isNotEmpty() }.joinToString(separator)
    }

    companion object {
        fun res(@StringRes id: Int, vararg args: Any): Txt = Res(id, args.toList())
        fun plural(@PluralsRes id: Int, count: Int, vararg args: Any): Txt =
            Plural(id, count, if (args.isEmpty()) listOf(count) else args.toList())
        fun raw(text: String): Txt = Raw(text)
        fun lines(vararg parts: Txt?): Txt = Join(parts.filterNotNull(), "\n")
    }
}

private fun Any.resolveArg(context: Context): Any = if (this is Txt) resolve(context) else this

/** The text in the app's language (recomposes when the language changes). */
@Composable
fun Txt.text(): String {
    LocalConfiguration.current
    return resolve(LocalContext.current)
}

fun formatTime(context: Context, instant: Instant, style: Txt.TimeStyle): String {
    val locale = context.resources.configuration.locales[0] ?: Locale.getDefault()
    val zone = ZoneId.systemDefault()
    val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).withZone(zone)
    return when (style) {
        Txt.TimeStyle.TIME -> time.format(instant)
        Txt.TimeStyle.TIME_OR_WEEKDAY -> {
            val date = instant.atZone(zone).toLocalDate()
            if (date == LocalDate.now(zone)) time.format(instant)
            else date.dayOfWeek.getDisplayName(TextStyle.SHORT, locale) + " " + time.format(instant)
        }
        Txt.TimeStyle.RELATIVE, Txt.TimeStyle.RELATIVE_INLINE -> DateUtils.getRelativeTimeSpanString(instant.toEpochMilli(),
            System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()
            .let { if (style == Txt.TimeStyle.RELATIVE_INLINE) it.replaceFirstChar { c -> c.lowercase(locale) } else it }
        Txt.TimeStyle.DATE_TIME -> DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(locale).withZone(zone).format(instant)
        Txt.TimeStyle.DATE -> DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).withZone(zone).format(instant)
    }
}

package dev.marquart.aos.ui

import androidx.compose.runtime.Composable
import dev.marquart.aos.ui.platform.PlatformContext
import dev.marquart.aos.ui.platform.locale
import dev.marquart.aos.ui.platform.platformContext
import dev.marquart.aos.ui.platform.quantityText
import dev.marquart.aos.ui.platform.relativeTime
import dev.marquart.aos.ui.platform.text
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle

/**
 * A text the views show, decided apart from them (the status words, the errors): a string resource with its
 * arguments, a plural, a time, or text as it came. Plain data, so the JVM tests can check which text was chosen
 * without Android; `resolve` makes it a string in the app's language.
 */
sealed interface Txt {
    data class Res(val id: Int, val args: List<Any> = emptyList()) : Txt
    data class Plural(val id: Int, val count: Int, val args: List<Any> = listOf(count)) : Txt
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

    fun resolve(context: PlatformContext): String = when (this) {
        is Res -> if (args.isEmpty()) context.text(id) else context.text(id, *args.map { it.resolveArg(context) }.toTypedArray())
        is Plural -> context.quantityText(id, count, *args.map { it.resolveArg(context) }.toTypedArray())
        is Raw -> text
        is Time -> formatTime(context, instant, style)
        is Join -> parts.map { it.resolve(context) }.filter { it.isNotEmpty() }.joinToString(separator)
    }

    companion object {
        fun res(id: Int, vararg args: Any): Txt = Res(id, args.toList())
        fun plural(id: Int, count: Int, vararg args: Any): Txt =
            Plural(id, count, if (args.isEmpty()) listOf(count) else args.toList())
        fun raw(text: String): Txt = Raw(text)
        fun lines(vararg parts: Txt?): Txt = Join(parts.filterNotNull(), "\n")
    }
}

private fun Any.resolveArg(context: PlatformContext): Any = if (this is Txt) resolve(context) else this

/** The text in the app's language (recomposes when the language changes). */
@Composable
fun Txt.text(): String {
    return resolve(platformContext())
}

fun formatTime(context: PlatformContext, instant: Instant, style: Txt.TimeStyle): String {
    val locale = context.locale
    val zone = ZoneId.systemDefault()
    val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).withZone(zone)
    return when (style) {
        Txt.TimeStyle.TIME -> time.format(instant)
        Txt.TimeStyle.TIME_OR_WEEKDAY -> {
            val date = instant.atZone(zone).toLocalDate()
            if (date == LocalDate.now(zone)) time.format(instant)
            else date.dayOfWeek.getDisplayName(TextStyle.SHORT, locale) + " " + time.format(instant)
        }
        Txt.TimeStyle.RELATIVE, Txt.TimeStyle.RELATIVE_INLINE -> context.relativeTime(instant.toEpochMilli())
            .let { if (style == Txt.TimeStyle.RELATIVE_INLINE) it.replaceFirstChar { c -> c.lowercase(locale) } else it }
        Txt.TimeStyle.DATE_TIME -> DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(locale).withZone(zone).format(instant)
        Txt.TimeStyle.DATE -> DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).withZone(zone).format(instant)
    }
}

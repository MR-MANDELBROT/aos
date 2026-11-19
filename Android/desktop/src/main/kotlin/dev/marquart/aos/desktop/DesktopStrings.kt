package dev.marquart.aos.desktop

import dev.marquart.aos.R
import java.util.Locale
import kotlin.math.abs

/**
 * The app's texts: Android's string resources (shared-ui/src/main/res, desktop/src/main/res), compiled into tables
 * by the build (aos/strings/<language>.tsv). German when the system's language is German (or AOS_LANG=de), English
 * otherwise.
 */
object DesktopStrings {
    private class Table(val strings: Map<String, String>, val plurals: Map<String, Map<String, String>>)

    /** The language the app shows. */
    var locale: Locale = chooseLocale()
        private set

    private var tables: List<Table> = load(locale)

    /** For tests and the screenshots: another language. */
    fun use(locale: Locale) {
        this.locale = locale
        tables = load(locale)
    }

    private fun chooseLocale(): Locale {
        val wanted = System.getenv("AOS_LANG") ?: System.getProperty("aos.lang")
        val language = wanted ?: Locale.getDefault().language
        return if (language.startsWith("de")) Locale.GERMAN else Locale.ENGLISH
    }

    private fun load(locale: Locale): List<Table> {
        // The language's own table first, the default (English) behind it.
        val names = if (locale.language == "en") listOf("default") else listOf(locale.language, "default")
        return names.mapNotNull { readTable(it) }
    }

    private fun readTable(name: String): Table? {
        val stream = DesktopStrings::class.java.getResourceAsStream("/aos/strings/$name.tsv") ?: return null
        val strings = HashMap<String, String>()
        val plurals = HashMap<String, MutableMap<String, String>>()
        stream.bufferedReader().useLines { lines ->
            for (line in lines) {
                val parts = line.split('\t', limit = 4)
                if (parts.size < 4) continue
                val value = unescape(parts[3])
                if (parts[0] == "s") strings[parts[1]] = value else plurals.getOrPut(parts[1]) { HashMap() }[parts[2]] = value
            }
        }
        return Table(strings, plurals)
    }

    private fun unescape(s: String): String {
        if ('\\' !in s) return s
        val out = StringBuilder()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                out.append(when (s[i + 1]) { 'n' -> '\n'; 't' -> '\t'; else -> s[i + 1] })
                i += 2
            } else {
                out.append(c)
                i++
            }
        }
        return out.toString()
    }

    private fun name(id: Int): String = R.names[id] ?: error("No resource $id")

    fun text(id: Int, vararg args: Any): String {
        val name = name(id)
        val pattern = tables.firstNotNullOfOrNull { it.strings[name] } ?: return name
        return if (args.isEmpty()) pattern else format(pattern, args)
    }

    fun quantityText(id: Int, count: Int, vararg args: Any): String {
        val name = name(id)
        // English and German: "one" for 1, "other" for everything else.
        val quantity = if (count == 1) "one" else "other"
        val forms = tables.firstNotNullOfOrNull { it.plurals[name] } ?: return name
        val pattern = forms[quantity] ?: forms["other"] ?: forms.values.first()
        return format(pattern, if (args.isEmpty()) arrayOf(count) else args)
    }

    private fun format(pattern: String, args: Array<out Any>): String = try {
        String.format(locale, pattern, *args)
    } catch (_: Exception) {
        pattern
    }

    fun resourceBytes(id: Int): ByteArray {
        val path = "/aos/" + name(id)
        return DesktopStrings::class.java.getResourceAsStream(path)?.use { it.readBytes() } ?: error("Missing $path")
    }

    fun rawText(id: Int): String = String(resourceBytes(id), Charsets.UTF_8)

    /** Relative times like Android's DateUtils with FORMAT_ABBREV_RELATIVE, in English and German. */
    fun relativeTime(millis: Long, now: Long): String {
        val delta = millis - now
        val past = delta < 0
        val seconds = abs(delta) / 1000
        val minutes = seconds / 60
        val hours = minutes / 60
        val days = hours / 24
        val german = locale.language == "de"
        fun phrase(n: Long, en: String, enMany: String, de: String, deMany: String): String {
            val unit = if (german) (if (n == 1L) de else deMany) else (if (n == 1L) en else enMany)
            return if (german) (if (past) "vor $n $unit" else "in $n $unit") else (if (past) "$n $unit ago" else "in $n $unit")
        }
        return when {
            minutes < 1 -> if (german) (if (past) "gerade eben" else "gleich") else (if (past) "just now" else "in a moment")
            hours < 1 -> phrase(minutes, "min.", "min.", "Min.", "Min.")
            days < 1 -> phrase(hours, "hr.", "hr.", "Std.", "Std.")
            days == 1L -> if (german) (if (past) "gestern" else "morgen") else (if (past) "Yesterday" else "Tomorrow")
            else -> phrase(days, "day", "days", "Tag", "Tagen".let { if (past) it else "Tagen" })
        }
    }
}

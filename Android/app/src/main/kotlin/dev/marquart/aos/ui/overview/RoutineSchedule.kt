package dev.marquart.aos.ui.overview

import dev.marquart.aos.R
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.Txt.Companion.raw
import dev.marquart.aos.ui.Txt.Companion.res

/**
 * Cron schedules as aOS writes them (iOS RoutineSchedule): times on weekdays ("M H * * days", several separated by ";")
 * or every few hours ("M A-B/N * * days"), in words. Weekdays: 0 is Sunday, as in cron.
 */
object RoutineSchedule {
    data class Time(val hour: Int, val minute: Int)
    data class Simple(val times: List<Time>, val weekdays: Set<Int>)
    data class Interval(val hours: Int, val from: Int, val to: Int, val minute: Int, val weekdays: Set<Int>)

    val ALL_DAYS: Set<Int> = (0..6).toSet()

    fun parts(text: String): List<List<String>> =
        text.split(';').map { part -> part.trim().split(Regex("\\s+")).filter { it.isNotEmpty() } }.filter { it.isNotEmpty() }

    fun days(field: String): Set<Int>? {
        if (field == "*") return ALL_DAYS
        val out = mutableSetOf<Int>()
        for (part in field.split(',')) {
            val bounds = part.split('-').map { it.toIntOrNull() ?: return null }
            if (bounds.size !in 1..2 || bounds.any { it !in 0..7 } || bounds[0] > bounds.last()) return null
            for (d in bounds[0]..bounds.last()) out += if (d == 7) 0 else d
        }
        return out.ifEmpty { null }
    }

    fun simple(cron: String): Simple? {
        val times = mutableListOf<Time>()
        var weekdays: Set<Int>? = null
        for (f in parts(cron)) {
            if (f.size != 5) return null
            val minute = f[0].toIntOrNull()?.takeIf { it in 0..59 } ?: return null
            if (f[2] != "*" || f[3] != "*") return null
            val d = days(f[4]) ?: return null
            val hourFields = f[1].split(',')
            val hours = hourFields.mapNotNull { it.toIntOrNull() }
            if (hours.isEmpty() || hours.size != hourFields.size || hours.any { it !in 0..23 }) return null
            if (weekdays != null && weekdays != d) return null
            weekdays = d
            times += hours.map { Time(it, minute) }
        }
        val days = weekdays ?: return null
        if (times.isEmpty()) return null
        return Simple(times.sortedWith(compareBy({ it.hour }, { it.minute })).distinct(), days)
    }

    fun interval(cron: String): Interval? {
        val p = parts(cron)
        if (p.size != 1) return null
        val f = p[0]
        if (f.size != 5) return null
        val minute = f[0].toIntOrNull()?.takeIf { it in 0..59 } ?: return null
        if (f[2] != "*" || f[3] != "*") return null
        val d = days(f[4]) ?: return null
        val hp = f[1].split('/')
        if (hp.size > 2) return null
        val step = if (hp.size == 2) hp[1].toIntOrNull() ?: 0 else 1
        if (step < 1) return null
        var from = 0
        var to = 23
        if (hp[0] != "*") {
            val b = hp[0].split('-').mapNotNull { it.toIntOrNull() }
            if (b.size != 2) return null
            from = b[0]; to = b[1]
        }
        if (step <= 1 && hp[0] != "*") return null
        return Interval(step, from, to, minute, d)
    }

    fun dayField(weekdays: Set<Int>): String =
        if (weekdays.size == 7 || weekdays.isEmpty()) "*" else weekdays.sorted().joinToString(",")

    /** One schedule per minute value (hours that share a minute go together), as the Mac writes it. */
    fun cron(times: List<Time>, weekdays: Set<Int>): String {
        val byMinute = times.groupBy({ it.minute }, { it.hour })
        return byMinute.keys.sorted().joinToString("; ") { m ->
            "$m ${byMinute.getValue(m).toSortedSet().joinToString(",")} * * ${dayField(weekdays)}"
        }
    }

    fun every(hours: Int, from: Int, to: Int, minute: Int, weekdays: Set<Int>): String {
        val range = if (from == 0 && to == 23) "*" else "$from-$to"
        return "$minute $range${if (hours > 1) "/$hours" else ""} * * ${dayField(weekdays)}"
    }

    /** Five fields of digits and cron's signs per schedule (the Mac checks it properly). */
    fun looksValid(cron: String): Boolean {
        val p = parts(cron)
        return p.isNotEmpty() && p.all { f -> f.size == 5 && f.all { field -> field.all { it.isDigit() || it in "*,-/" } } }
    }

    fun clock(hour: Int, minute: Int) = "%02d:%02d".format(hour, minute)

    /** The weekdays in words: null for every day. `names` are the short names, Sunday first. */
    fun daysText(set: Set<Int>, names: List<String>, firstDay: Int): Txt? {
        if (set.size == 7) return null
        if (set == (1..5).toSet()) return res(R.string.routine_mon_to_fri)
        if (set == setOf(0, 6)) return res(R.string.routine_weekends)
        return raw((0 until 7).map { (firstDay + it) % 7 }.filter { it in set }.joinToString(", ") { names[it] })
    }

    fun text(cron: String, names: List<String>, firstDay: Int): Txt {
        val s = simple(cron)
        val i = interval(cron)
        if (i != null && (i.hours > 1 || s == null)) {
            val base = if (i.hours == 1) res(R.string.routine_every_hour, clock(i.from, i.minute), clock(i.to, i.minute))
                else res(R.string.routine_every_hours, i.hours, clock(i.from, i.minute), clock(i.to, i.minute))
            return daysText(i.weekdays, names, firstDay)?.let { res(R.string.routine_with_days, base, it) } ?: base
        }
        if (s == null) return raw(cron)
        val times = s.times.joinToString(", ") { clock(it.hour, it.minute) }
        val d = daysText(s.weekdays, names, firstDay) ?: return res(R.string.routine_daily_at, times)
        return res(R.string.routine_days_at, d, times)
    }
}

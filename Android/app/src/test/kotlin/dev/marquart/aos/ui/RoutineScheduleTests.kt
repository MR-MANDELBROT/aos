package dev.marquart.aos.ui

import dev.marquart.aos.R
import dev.marquart.aos.ui.Txt.Companion.raw
import dev.marquart.aos.ui.Txt.Companion.res
import dev.marquart.aos.ui.overview.RoutineSchedule
import dev.marquart.aos.ui.overview.RoutineSchedule.Time
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Cron schedules as aOS writes them (the iPhone's RoutineSchedule tests). */
class RoutineScheduleTests {
    private val names = listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")

    @Test fun timesOnWeekdays() {
        val s = RoutineSchedule.simple("30 7 * * 1-5; 30 12 * * 1-5")!!
        assertEquals(listOf(Time(7, 30), Time(12, 30)), s.times)
        assertEquals((1..5).toSet(), s.weekdays)
        assertEquals("30 7,12 * * 1,2,3,4,5", RoutineSchedule.cron(s.times, s.weekdays))
        assertEquals("0 8 * * *; 15 9 * * *", RoutineSchedule.cron(listOf(Time(9, 15), Time(8, 0)), RoutineSchedule.ALL_DAYS))
        // Different days per part: not a simple schedule.
        assertNull(RoutineSchedule.simple("0 8 * * 1; 0 9 * * 2"))
        assertNull(RoutineSchedule.simple("0 8 1 * *"))
        assertEquals(setOf(0), RoutineSchedule.days("7"))
    }

    @Test fun everyFewHours() {
        val i = RoutineSchedule.interval("0 9-18/3 * * *")!!
        assertEquals(RoutineSchedule.Interval(3, 9, 18, 0, RoutineSchedule.ALL_DAYS), i)
        assertEquals("0 9-18/3 * * *", RoutineSchedule.every(3, 9, 18, 0, RoutineSchedule.ALL_DAYS))
        assertEquals("15 */2 * * 0,6", RoutineSchedule.every(2, 0, 23, 15, setOf(0, 6)))
        assertNull(RoutineSchedule.interval("0 9-18 * * *"))
    }

    @Test fun inWords() {
        assertEquals(res(R.string.routine_daily_at, "07:30"), RoutineSchedule.text("30 7 * * *", names, 1))
        assertEquals(res(R.string.routine_days_at, res(R.string.routine_mon_to_fri), "07:30"), RoutineSchedule.text("30 7 * * 1-5", names, 1))
        assertEquals(res(R.string.routine_days_at, raw("Mon, Wed"), "08:00"), RoutineSchedule.text("0 8 * * 1,3", names, 1))
        assertEquals(res(R.string.routine_every_hours, 3, "09:00", "18:00"), RoutineSchedule.text("0 9-18/3 * * *", names, 1))
        assertEquals(res(R.string.routine_with_days, res(R.string.routine_every_hour, "00:05", "23:05"), res(R.string.routine_weekends)),
            RoutineSchedule.text("5 * * * 0,6", names, 1))
        assertEquals(raw("0 8 1 * *"), RoutineSchedule.text("0 8 1 * *", names, 1))
    }

    @Test fun looksValid() {
        assertTrue(RoutineSchedule.looksValid("0 6 * * 1-5; */5 * * * *"))
        assertFalse(RoutineSchedule.looksValid("0 6 * *"))
        assertFalse(RoutineSchedule.looksValid("0 6 * * mon"))
        assertFalse(RoutineSchedule.looksValid(""))
    }
}

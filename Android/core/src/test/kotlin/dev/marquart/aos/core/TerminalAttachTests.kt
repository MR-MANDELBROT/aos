package dev.marquart.aos.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The notes of `aos-companion term attach`, taken out of the output (iOS TermNoteFilterTests). */
class TerminalAttachTests {
    private fun startNote(id: String, from: Long, reset: Boolean, new: Boolean, gone: String?) = TermNoteFilter.note(
        """{"t":"start","id":"$id","from":$from,"reset":$reset,"prefix":"","created":"2026-11-07T09:00:00Z","new":$new""" +
            (gone?.let { ""","gone":"$it"""" } ?: "") + "}")

    private fun endNote(why: String, status: Int? = null) =
        TermNoteFilter.note("""{"t":"end","why":"$why"""" + (status?.let { ""","status":$it""" } ?: "") + "}")

    private val start = startNote("0123abcd", 42, reset = false, new = false, gone = null)

    private fun run(chunks: List<ByteArray>): List<TermNoteFilter.Piece> {
        val filter = TermNoteFilter()
        val joined = mutableListOf<TermNoteFilter.Piece>()
        for (chunk in chunks) for (piece in filter.feed(chunk)) {
            val last = joined.lastOrNull()
            if (piece is TermNoteFilter.Piece.Bytes && last is TermNoteFilter.Piece.Bytes) {
                joined[joined.size - 1] = TermNoteFilter.Piece.Bytes(last.data + piece.data)
            } else joined += piece
        }
        return joined
    }

    private fun bytes(text: String) = TermNoteFilter.Piece.Bytes(text.toByteArray())

    @Test fun aNoteIsTakenOutAndTheRestStays() {
        val input = "before\u001b[31m".toByteArray() + start + "after\u001b]0;title\u0007".toByteArray()
        assertEquals(listOf(
            bytes("before\u001b[31m"),
            TermNoteFilter.Piece.Note(TermNote.Start("0123abcd", 42, false, ByteArray(0), false, null)),
            bytes("after\u001b]0;title\u0007"),
        ), run(listOf(input)))
    }

    @Test fun aNoteSplitAnywhereIsStillFound() {
        val input = "ab".toByteArray() + start + "cd".toByteArray()
        for (cut in 1 until input.size) {
            val pieces = run(listOf(input.copyOfRange(0, cut), input.copyOfRange(cut, input.size)))
            assertEquals(3, pieces.size, "cut at $cut")
            assertEquals(bytes("ab"), pieces.first())
            assertEquals(bytes("cd"), pieces.last())
        }
        assertEquals(3, run(input.map { byteArrayOf(it) }).size)
    }

    @Test fun somethingThatOnlyLooksLikeANoteStays() {
        val fake = "\u001b]7730;not json\u0007x".toByteArray()
        assertEquals(listOf(TermNoteFilter.Piece.Bytes(fake)), run(listOf(fake)))
        assertEquals(listOf(TermNoteFilter.Piece.Note(TermNote.End("exited", 3))), run(listOf(endNote("exited", 3))))
    }

    @Test fun startNotesWithAPrefixAndANewSession() {
        val note = TermNoteFilter.note("""{"t":"start","id":"0000aa01","from":0,"reset":true,"prefix":"G1s/MTA0OWg=","new":true,"gone":"0123abcd"}""")
        val piece = run(listOf(note)).single() as TermNoteFilter.Piece.Note
        val s = piece.note as TermNote.Start
        assertTrue(s.reset && s.isNew)
        assertEquals("0123abcd", s.gone)
        assertEquals("\u001b[?1049h", s.prefix.toString(Charsets.UTF_8))
        // An id that isn't one: not a note
        assertNull(TermNote.parse("""{"t":"start","id":"x; rm","from":0}""".toByteArray()))
        // Large offsets
        assertEquals(5_000_000_000L, (TermNote.parse("""{"t":"start","id":"0123abcd","from":5000000000}""".toByteArray()) as TermNote.Start).from)
    }

    @Test fun theCommands() {
        val path = "/Applications/aOS.app/Contents/MacOS/aos-companion"
        assertEquals("'$path' term attach", TermAttach.attach(path, null, 5))
        assertEquals("'$path' term attach --id 0123abcd", TermAttach.attach(path, "0123abcd", null))
        assertEquals("'$path' term attach --id 0123abcd --have 99", TermAttach.attach(path, "0123abcd", 99))
        assertEquals("'$path' term attach --id 0123abcd --have 99 --client 4853150ceae1", TermAttach.attach(path, "0123abcd", 99, "4853150ceae1"))
        assertEquals("'$path' term attach", TermAttach.attach(path, "x; rm -rf ~", 1, "a b"))
        assertNull(TermAttach.end(path, "\$(reboot)"))
        assertEquals("'$path' term end 0123abcd", TermAttach.end(path, "0123abcd"))
        assertEquals("'$path' term list --json", TermAttach.list(path))
    }

    @Test fun theListFromTheMac() {
        val json = """{"sessions":[{"id":"0123abcd","attached":true,"since":"2026-11-07T10:00:00Z","from":"ssh 10.0.0.2","client":"4853150ceae1","command":"vim","cwd":"/Users/max/Developer/aos","cols":80,"rows":24,"pid":1,"shell":2,"created":"2026-11-07T09:00:00Z"},{"id":"bad"},{"id":"00000001","attached":false,"created":"2026-11-07T08:00:00Z"}]}"""
        val list = TermAttach.sessions(json.toByteArray())!!
        assertEquals(listOf("0123abcd", "00000001"), list.map { it.id })
        assertTrue(list[0].attached)
        assertEquals("vim in ~/Developer/aos", list[0].place("/Users/max"))
        assertEquals(listOf("00000001", "0123abcd"), TermAttach.ordered(list).map { it.id })
        assertEquals(MacTermSession.Holder.Here, list[0].holder(null, "4853150ceae1", null))
        assertEquals(MacTermSession.Holder.Elsewhere("ssh 10.0.0.2"), list[0].holder(null, "aaaaaaaaaaaa", null))
        assertEquals(MacTermSession.Holder.Nobody, list[1].holder(null, "4853150ceae1", null))
        assertEquals(true, termEndResult("""{"ok":true}""".toByteArray()))
        assertEquals(false, termEndResult("""{"ok":false,"gone":true}""".toByteArray()))
    }
}

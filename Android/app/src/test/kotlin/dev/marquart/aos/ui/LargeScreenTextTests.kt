package dev.marquart.aos.ui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * A tablet isn't "this phone": res/values-sw600dp and values-de-sw600dp say "this device" / "dieses Gerät" for every
 * shared text that names the phone. They are made from the shared texts by the rule here; this checks they still match
 * (a text that changed or came new needs its line there too).
 */
class LargeScreenTextTests {
    private val root = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .first { File(it, "shared-ui/src/main/res").isDirectory }

    private val english = listOf(Regex("\\bphone\\b") to "device", Regex("\\bPhone\\b") to "Device")
    private val german = listOf(Regex("\\bHandys\\b") to "Geräts", Regex("\\bHandy\\b") to "Gerät",
        Regex("\\bTelefons\\b") to "Geräts", Regex("\\bTelefon\\b") to "Gerät")

    private val string = Regex("<string name=\"([^\"]+)\"[^>]*>(.*?)</string>", RegexOption.DOT_MATCHES_ALL)

    private fun strings(dir: File): Map<String, String> = dir.listFiles()!!.filter { it.name.startsWith("strings") }.sortedBy { it.name }
        .flatMap { file -> string.findAll(file.readText()).map { it.groupValues[1] to it.groupValues[2] } }.toMap()

    private fun check(language: String, rules: List<Pair<Regex, String>>) {
        val shared = strings(File(root, "shared-ui/src/main/res/$language"))
        val expected = shared.mapValues { (_, text) -> rules.fold(text) { t, (from, to) -> from.replace(t, to) } }
            .filter { (name, text) -> text != shared[name] }
        val wording = strings(File(root, "app/src/main/res/$language-sw600dp"))
        assertTrue(expected.size > 40, "the shared texts name the phone in many places")
        assertEquals(expected.keys.sorted(), wording.keys.sorted(), "$language: the texts that name the phone")
        for ((name, text) in expected) assertEquals(text, wording[name], "$language: $name")
    }

    @Test fun tabletsSayDeviceWhereThePhoneIsNamed() = check("values", english)

    @Test fun tabletsSayGeraetInGerman() = check("values-de", german)

    @Test fun germanTextsOfTheAppHaveNoDashes() {
        val de = listOf("app/src/main/res/values-de", "app/src/main/res/values-de-sw600dp", "shared-ui/src/main/res/values-de")
            .flatMap { File(root, it).listFiles()!!.toList() }.joinToString("\n") { it.readText() }
        assertFalse(Regex(" [–—-] ").containsMatchIn(de), "no dashes as punctuation")
    }
}

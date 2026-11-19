package dev.marquart.aos.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.math.abs

/**
 * JSON as the Mac reads and writes it: lenient reading (unknown fields are ignored, wrong types count as missing),
 * writing with sorted keys and `/` unescaped (as Swift's `JSONEncoder` with `.sortedKeys, .withoutEscapingSlashes`).
 */
object Json {
    private val json = kotlinx.serialization.json.Json { prettyPrint = false }

    fun encode(element: JsonElement): String = json.encodeToString(JsonElement.serializer(), sorted(element))

    /** One JSON line with its "\n". */
    fun line(element: JsonElement): ByteArray = Bytes.utf8(encode(element) + "\n")

    fun parse(text: String): JsonElement? {
        val element = try {
            json.parseToJsonElement(text)
        } catch (_: Exception) {
            return null
        }
        // kotlinx reads a bare word ("hello", a shell's login message) as an unquoted literal: that isn't JSON.
        if (element is JsonPrimitive && !element.isString && element !is JsonNull &&
            element.content != "true" && element.content != "false" && element.content.toDoubleOrNull() == null) return null
        return element
    }

    fun parse(bytes: ByteArray): JsonElement? = parse(bytes.toString(Charsets.UTF_8))

    fun parseObject(bytes: ByteArray): JsonObject? = parse(bytes) as? JsonObject

    /** Keys in sorted order, all the way down. */
    fun sorted(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.entries.sortedBy { it.key }.associateTo(LinkedHashMap()) { it.key to sorted(it.value) })
        is JsonArray -> JsonArray(element.map(::sorted))
        else -> element
    }

    /** A number the way Swift writes it: integral values without a fraction. */
    fun number(value: Double): JsonPrimitive =
        if (Math.rint(value) == value && abs(value) < 1e15) JsonPrimitive(value.toLong()) else JsonPrimitive(value)

    fun number(value: Number): JsonPrimitive = when (value) {
        is Double -> number(value)
        is Float -> number(value.toDouble())
        else -> JsonPrimitive(value.toLong())
    }
}

/** An object with its keys sorted. */
fun sortedJsonObject(vararg pairs: Pair<String, JsonElement?>): JsonObject =
    JsonObject(pairs.filter { it.second != null }.sortedBy { it.first }.associateTo(LinkedHashMap()) { it.first to it.second!! })

// Lenient accessors: the type a field should have, or null.

val JsonElement?.str: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

val JsonElement?.bool: Boolean?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p.isString || p is JsonNull) return null
        return when (p.content) { "true" -> true; "false" -> false; else -> null }
    }

val JsonElement?.num: Double?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p.isString || p is JsonNull) return null
        if (p.content == "true" || p.content == "false") return null
        return p.doubleOrNull
    }

/** A whole number (a JSON number without a fraction, also when written as `5900.0`). */
val JsonElement?.int: Int?
    get() {
        val n = num ?: return null
        return if (Math.rint(n) == n && abs(n) < 1e15 && n >= Int.MIN_VALUE && n <= Int.MAX_VALUE) n.toInt() else null
    }

val JsonElement?.long: Long?
    get() {
        val n = num ?: return null
        return if (Math.rint(n) == n && abs(n) < 1e15) n.toLong() else null
    }

val JsonElement?.obj: JsonObject? get() = this as? JsonObject
val JsonElement?.arr: JsonArray? get() = this as? JsonArray

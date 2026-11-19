package dev.marquart.aos.ui.demo

import android.content.Intent
import dev.marquart.aos.BuildConfig

/** The demo's options from the intent's extras (debug builds only; see Demo.kt). */
fun DemoOptions.Companion.from(intent: Intent?): DemoOptions? {
    if (!BuildConfig.DEBUG || intent?.getBooleanExtra(EXTRA, false) != true) return null
    fun s(name: String) = intent.getStringExtra("$EXTRA.$name")
    return DemoOptions(
        tab = s("tab"), sheet = s("sheet"), unpaired = intent.getBooleanExtra("$EXTRA.unpaired", false),
        dark = when (s("theme")) { "dark" -> true; "light" -> false; else -> null },
        session = s("session"), display = s("display"), chats = s("chats"),
        sleeping = intent.getBooleanExtra("$EXTRA.sleeping", false), workspace = s("workspace"),
        scrollToBottom = s("scroll") == "bottom", tailnet = s("tailnet"),
    )
}

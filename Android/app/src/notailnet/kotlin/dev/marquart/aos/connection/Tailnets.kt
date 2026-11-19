package dev.marquart.aos.connection

import android.content.Context

/**
 * Built without third_party/aosgo/aosgo.aar (the Go library isn't built on this machine): no node of aOS's own, the
 * tailnet routes through it are left out. The build with the aar uses src/tailnet instead (app/build.gradle.kts).
 */
object Tailnets {
    const val AVAILABLE = false

    fun create(context: Context, deviceName: String): TailnetDialer = NoTailnet
}

package dev.marquart.aos.desktop

import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.screen.LoginCheckResult
import dev.marquart.aos.screen.RemoteSession
import dev.marquart.aos.screen.RemoteSessionFactory
import dev.marquart.aos.screen.RemoteSessionListener
import dev.marquart.aos.screen.RemoteSessionOptions
import dev.marquart.aos.ui.tailnet.TailnetControl

/**
 * Built without the desktop Go library (third_party/aosgo-desktop, Tools/go-desktop.sh): no screen sessions, no node of
 * aOS's own Tailscale. The build with it uses src/aosgo instead (desktop/build.gradle.kts).
 */
object GoLibrary {
    const val AVAILABLE = false

    fun tailnet(deviceName: String): TailnetDialer = NoTailnet

    fun tailnetControl(dialer: TailnetDialer): TailnetControl? = null

    val screenSessions: RemoteSessionFactory = object : RemoteSessionFactory {
        override val available = false

        override fun create(options: RemoteSessionOptions, listener: RemoteSessionListener): RemoteSession =
            throw UnsupportedOperationException("This build of aOS has no screen sharing library.")

        override fun checkLogin(options: RemoteSessionOptions): LoginCheckResult =
            LoginCheckResult.Failed("This build of aOS has no screen sharing library.")
    }
}

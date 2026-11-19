package dev.marquart.aos.screen

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import dev.marquart.aos.AosApp

/**
 * Debug builds: the screen's session without the Mac and SSH, for checks in the emulator.
 *
 *     adb shell am start -n dev.marquart.aos/.screen.ScreenDemoActivity                       # the demo server in the app
 *     adb shell am start -n dev.marquart.aos/.screen.ScreenDemoActivity --es direct 10.0.2.2:5901 [--es user U --es password P]
 *     adb shell am start -n dev.marquart.aos/.screen.ScreenDemoActivity --ez cards true        # the Screen tab's cards
 *
 * `direct` connects straight to a screen sharing server (the iPhone's `-AOSScreenDirect`); without `password` it signs in
 * without authentication (a plain RFB server). Never pointed at the real Mac or workspace without being asked to.
 */
class ScreenDemoActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val hub = ScreenHub.get(this)
        val cards = intent.getBooleanExtra("cards", false)
        if (savedInstanceState == null && !cards && hub.workspace.session == null) {
            val direct = intent.getStringExtra("direct")
            if (direct != null) {
                val host = direct.substringBeforeLast(':')
                val port = direct.substringAfterLast(':').toIntOrNull() ?: 5900
                hub.workspace.startDirect(host, port, intent.getStringExtra("user") ?: "", intent.getStringExtra("password"), "Direct")
            } else {
                hub.workspace.startDemo("Workspace", intent.getIntExtra("width", 1280), intent.getIntExtra("height", 800))
            }
        }
        val model = (application as AosApp).graph.model
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface {
                    if (cards) {
                        ScreenTab(model)
                    } else {
                        val controller = hub.workspace
                        val session = controller.session
                        if (session != null) {
                            SessionScreen(session, hub, help = null, isWorkspace = true, onShowWorkspace = {}, onHelpDone = {},
                                onClose = { controller.closed(session); finish() })
                        }
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (!isChangingConfigurations && !intent.getBooleanExtra("cards", false)) ScreenHub.get(this).workspace.stop()
    }
}

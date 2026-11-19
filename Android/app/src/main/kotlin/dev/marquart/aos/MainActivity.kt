package dev.marquart.aos

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import dev.marquart.aos.ui.PlaceholderScreen

/** The only activity. Its content is a placeholder until the UI is built (ui/PlaceholderScreen.kt). */
class MainActivity : ComponentActivity() {
    /** A pairing link that opened the app (aos-pair://...). */
    private val incomingLink = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        incomingLink.value = pairingLink(intent)
        val model = (application as AosApp).graph.model
        setContent { PlaceholderScreen(model, incomingLink.value) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pairingLink(intent)?.let { incomingLink.value = it }
    }

    private fun pairingLink(intent: Intent?): String? =
        intent?.data?.takeIf { it.scheme.equals("aos-pair", ignoreCase = true) }?.toString()
}

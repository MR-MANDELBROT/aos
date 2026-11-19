package dev.marquart.aos

import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import dev.marquart.aos.ui.AosRoot
import dev.marquart.aos.ui.AosUi
import dev.marquart.aos.ui.demo.Demo
import dev.marquart.aos.ui.demo.DemoOptions
import dev.marquart.aos.ui.tabs.installSettingsSlots
import dev.marquart.aos.ui.tailnet.TailnetControls
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The only activity: the UI (ui/AosRoot.kt), the pairing links that open the app (aos-pair://...), and the requests
 * a notification opens. A FragmentActivity for the biometric prompt.
 */
class MainActivity : FragmentActivity() {
    private lateinit var ui: AosUi

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val graph = (application as AosApp).graph
        installSettingsSlots()
        // Debug builds: sample data from intent extras (ui/demo/Demo.kt), for screenshots without a Mac.
        val demo = DemoOptions.from(intent)
        val dark = demo?.dark
        if (dark == null) enableEdgeToEdge()
        else enableEdgeToEdge(
            statusBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        // Kept across rotations (the pages pushed, pairing), made once per task.
        val holder = ViewModelProvider(this)[UiHolder::class.java]
        ui = holder.ui ?: (if (demo != null) Demo.makeUi(applicationContext, demo)
            else AosUi(applicationContext, graph.model, graph.settings, graph.lock, graph.keys, TailnetControls.of(graph.tailnet), graph.network))
            .also { holder.ui = it }
        if (savedInstanceState == null) handle(intent)
        // Nothing of the app in the recent apps' picture while it locks itself.
        if (Build.VERSION.SDK_INT >= 33 && demo == null) {
            lifecycleScope.launch { graph.settings.settings.collect { setRecentsScreenshotEnabled(!it.requireUnlock) } }
        }
        setContent {
            AosTheme(dark = dark ?: isSystemInDarkTheme()) { AosRoot(ui) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        intent.data?.takeIf { it.scheme.equals("aos-pair", ignoreCase = true) }?.let { ui.startPairing(it.toString()) }
        val open = intent.getStringExtra(EXTRA_OPEN) ?: return
        intent.removeExtra(EXTRA_OPEN)
        val model = ui.model
        when {
            open.startsWith("question:") -> {
                val id = open.removePrefix("question:")
                model.questions.value.firstOrNull { it.id == id }?.let { model.present(it) }
                model.selectTab(dev.marquart.aos.model.AppModel.Tab.OVERVIEW)
            }
            open.startsWith("help:") -> {
                val id = open.removePrefix("help:")
                model.helpRequests.value.firstOrNull { it.id == id }?.let { model.showHelp(it) }
            }
        }
    }

    /** Holds the UI's state for the activity across configuration changes. */
    class UiHolder : ViewModel() {
        var ui: AosUi? = null

        override fun onCleared() {
            ui?.scope?.cancel()
        }
    }

    companion object {
        /** A request a notification opens: "question:<id>" or "help:<id>". */
        const val EXTRA_OPEN = "dev.marquart.aos.open"

        fun openQuestion(id: String) = "question:$id"
        fun openHelp(id: String) = "help:$id"
    }
}

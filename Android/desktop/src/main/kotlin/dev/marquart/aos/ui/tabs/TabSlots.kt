package dev.marquart.aos.ui.tabs

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import dev.marquart.aos.R
import dev.marquart.aos.desktop.screen.DesktopScreenTab
import dev.marquart.aos.desktop.screen.ScreenSettingsSection
import dev.marquart.aos.desktop.system.DesktopSettingsSection
import dev.marquart.aos.desktop.terminal.DesktopTerminalTab
import dev.marquart.aos.desktop.terminal.TerminalSettingsSection
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.platform.stringResource
import dev.marquart.aos.ui.settings.SettingsSlots

// The desktop's Terminal and Screen tabs (JediTerm, the screen in a Compose image) and their settings, the same slots
// Android fills with its own (app/.../ui/tabs/TabSlots.kt).

@Composable
fun TerminalTabSlot(model: AppModel, modifier: Modifier = Modifier) = DesktopTerminalTab(model, modifier)

@Composable
fun ScreenTabSlot(model: AppModel, modifier: Modifier = Modifier) = DesktopScreenTab(model, modifier)

/** Settings > Terminal, Settings > Screen and the computer's own section. Call once at start. */
fun installSettingsSlots() {
    SettingsSlots.terminal = { onBack ->
        Page(stringResource(R.string.terminal), onBack = onBack) { padding ->
            PageColumn(padding) { TerminalSettingsSection() }
        }
    }
    SettingsSlots.screen = { onBack ->
        Page(stringResource(R.string.screen), onBack = onBack) { padding ->
            PageColumn(padding) { ScreenSettingsSection() }
        }
    }
    SettingsSlots.device = { DesktopSettingsSection() }
}

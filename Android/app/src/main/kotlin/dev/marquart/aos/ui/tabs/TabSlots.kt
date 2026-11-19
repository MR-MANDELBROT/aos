package dev.marquart.aos.ui.tabs

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import dev.marquart.aos.R
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.screen.ScreenSettingsSection
import dev.marquart.aos.screen.ScreenTab
import dev.marquart.aos.terminal.TerminalSettingsSection
import dev.marquart.aos.terminal.TerminalTab
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.settings.SettingsSlots

// The Terminal and Screen tabs are built in their own packages (dev.marquart.aos.terminal, dev.marquart.aos.screen).
// The navigation calls them through these slots, and Settings shows their settings sections on pages of their own.

@Composable
fun TerminalTabSlot(model: AppModel, modifier: Modifier = Modifier) = TerminalTab(model, modifier)

@Composable
fun ScreenTabSlot(model: AppModel, modifier: Modifier = Modifier) = ScreenTab(model, modifier)

/** Settings > Terminal and Settings > Screen. Call once at start. */
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
}


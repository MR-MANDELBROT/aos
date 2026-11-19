package dev.marquart.aos.ui.signin

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.AddToQueue
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.PanTool
import androidx.compose.material.icons.rounded.Pin
import androidx.compose.material.icons.rounded.RadioButtonChecked
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.TimerOff
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.HourglassTop
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.marquart.aos.R
import dev.marquart.aos.core.ApprovalRequest
import dev.marquart.aos.core.ApprovalResult
import dev.marquart.aos.core.BitwardenState
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.SignInResult
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.ErrorText
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.components.AosCard
import dev.marquart.aos.ui.components.FactRow
import dev.marquart.aos.ui.components.Monogram
import dev.marquart.aos.ui.components.NoticeCard
import dev.marquart.aos.ui.lock.Biometrics
import dev.marquart.aos.ui.lock.fragmentActivity
import dev.marquart.aos.ui.overview.agentName
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

/** The agent's questions in one sheet, in the order they came (AppModel.presentedQuestion); "Later" keeps one waiting
 *  in the Overview. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuestionSheetHost(locked: Boolean) {
    val ui = LocalAosUi.current
    val presented by ui.model.presentedQuestion.collectAsState()
    val question = presented
    if (question == null || locked) return
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val later: () -> Unit = {
        scope.launch {
            state.hide()
            ui.model.closeQuestionSheet()
        }
    }
    ModalBottomSheet(
        onDismissRequest = { ui.model.closeQuestionSheet() },
        sheetState = state,
        containerColor = AosTheme.colors.background,
        dragHandle = null,
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = later) { Text(stringResource(R.string.later)) }
                Text(
                    stringResource(if (question is AppModel.Question.SignIn) R.string.signin_title else R.string.approval_title),
                    style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).padding(end = 72.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
            when (question) {
                is AppModel.Question.SignIn -> SignInContent(question.request, close = later)
                is AppModel.Question.Approval -> ApprovalContent(question.request, close = later)
            }
        }
    }
}

/** Seconds left until `expires`, updated every second. */
@Composable
private fun secondsLeft(expires: Instant?): Long? {
    if (expires == null) return null
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(expires) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    return maxOf(0, (expires.toEpochMilli() - now + 999) / 1000)
}

@Composable
private fun Countdown(left: Long) {
    val colors = AosTheme.colors
    val text = if (left <= 0) stringResource(R.string.expired) else stringResource(R.string.time_left, "%d:%02d".format(left / 60, left % 60))
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Rounded.Timer, contentDescription = null, tint = if (left < 30) colors.orange else colors.secondary, modifier = Modifier.size(16.dp))
        Text(text, style = MaterialTheme.typography.labelLarge, color = if (left < 30) colors.orange else colors.secondary)
    }
}

/** Asks the screen lock first (biometrics or the phone's PIN); the demo has nothing to protect. */
private suspend fun confirm(context: android.content.Context, demo: Boolean, title: String): Biometrics.Outcome {
    if (demo) return Biometrics.Outcome.SUCCESS
    val activity = context.fragmentActivity() ?: return Biometrics.Outcome.FAILED
    return Biometrics.authenticate(activity, title)
}

private sealed interface Phase {
    data object Choosing : Phase
    data object Sending : Phase
    data class Sent(val fromBitwarden: Boolean) : Phase
    data object Declined : Phase
    data class Failed(val message: String) : Phase
}

// Sign-in

@Composable
private fun SignInContent(request: SignInRequest, close: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val results by ui.model.signInResults.collectAsState()
    val result = results[request.id]
    var phase by remember(request.id) { mutableStateOf<Phase>(Phase.Choosing) }
    var selection by remember(request.id) { mutableStateOf(request.choices.firstOrNull()?.id) }
    var showOther by remember(request.id) { mutableStateOf(request.choices.isEmpty()) }
    var otherUser by remember(request.id) { mutableStateOf("") }
    var otherPassword by remember(request.id) { mutableStateOf("") }
    var code by remember(request.id) { mutableStateOf("") }
    val left = secondsLeft(request.expires)
    val expired = left != null && left <= 0
    val isCode = request.field == SignInRequest.Field.CODE

    // The Mac sent the request again with Bitwarden's logins (it was unlocked meanwhile).
    LaunchedEffect(request.logins) {
        if (request.choices.none { it.id == selection }) selection = request.choices.firstOrNull()?.id
        if (request.choices.isNotEmpty()) showOther = false
    }

    fun closeSoon() {
        scope.launch {
            delay(4_000)
            if (ui.model.presentedQuestion.value?.id == request.id) close()
        }
    }

    fun run(block: suspend () -> Phase) {
        scope.launch {
            phase = try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Phase.Failed(ErrorText.of(e).resolve(context))
            }
        }
    }

    fun approve(login: String?) {
        val connection = ui.model.connection.value ?: return
        if (login == null) return
        run {
            val title = context.getString(if (isCode) R.string.signin_prompt_code else R.string.signin_prompt_approve, request.host)
            when (confirm(context, ui.isDemo, title)) {
                Biometrics.Outcome.SUCCESS -> {
                    phase = Phase.Sending
                    connection.answerSignIn(request.id, request.host, login)
                    closeSoon()
                    Phase.Sent(fromBitwarden = true)
                }
                Biometrics.Outcome.CANCELLED -> Phase.Choosing
                Biometrics.Outcome.UNAVAILABLE -> Phase.Failed(context.getString(R.string.signin_needs_screen_lock))
                Biometrics.Outcome.FAILED -> Phase.Failed(context.getString(R.string.signin_prompt_failed))
            }
        }
    }

    Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        // Who asks for what
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(if (isCode) Icons.Rounded.Pin else Icons.Rounded.Key, contentDescription = null, tint = colors.attention, modifier = Modifier.size(18.dp))
                Text(if (isCode) stringResource(R.string.signin_asks_code, agentName(request.agent))
                    else stringResource(R.string.signin_asks, agentName(request.agent)),
                    style = MaterialTheme.typography.titleSmall, color = colors.attention)
            }
            Text(request.host, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, maxLines = 2,
                overflow = TextOverflow.Ellipsis)
            if (request.purpose.isNotEmpty()) Text("„${request.purpose}“", style = MaterialTheme.typography.titleMedium)
            if (!isCode) {
                Text(stringResource(if (request.field == SignInRequest.Field.USERNAME) R.string.signin_page_user else R.string.signin_page_password),
                    style = MaterialTheme.typography.bodySmall, color = colors.secondary)
            }
            if (left != null && result == null) Countdown(left)
        }

        when {
            result != null -> SignInOutcome(result)
            expired -> NoticeCard(Icons.Rounded.TimerOff, stringResource(R.string.request_expired), colors.secondary)
            else -> {
                when (val p = phase) {
                    Phase.Sending -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                    is Phase.Sent -> NoticeCard(Icons.AutoMirrored.Rounded.Send,
                        stringResource(if (p.fromBitwarden) R.string.signin_sent_bitwarden else R.string.signin_sent), colors.mint)
                    Phase.Declined -> NoticeCard(Icons.Rounded.PanTool, stringResource(R.string.signin_declined_agent), colors.secondary)
                    Phase.Choosing, is Phase.Failed -> {
                        bitwardenNotice(request)?.let { BitwardenNoticeCard(it, request) }
                        if (isCode) {
                            CodeChooser(request, code, { code = it }, sending = false,
                                onApprove = { approve(it) },
                                onSend = {
                                    val connection = ui.model.connection.value
                                    if (connection != null) run {
                                        phase = Phase.Sending
                                        connection.answerSignInCode(request.id, request.host, code.trim())
                                        code = ""
                                        closeSoon()
                                        Phase.Sent(false)
                                    }
                                })
                        } else {
                            LoginChooser(request, selection, { selection = it }, onApprove = { approve(selection) })
                        }
                        OutlinedButton(onClick = {
                            val connection = ui.model.connection.value
                            run {
                                phase = Phase.Sending
                                connection?.declineSignIn(request.id, request.host)
                                closeSoon()
                                Phase.Declined
                            }
                        }, modifier = Modifier.fillMaxWidth().height(48.dp), colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = colors.red)) {
                            Icon(Icons.Rounded.PanTool, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(8.dp))
                            Text(stringResource(R.string.decline))
                        }
                        if (!isCode) {
                            OtherPasswordApp(showOther, { showOther = it }, otherUser, { otherUser = it }, otherPassword, { otherPassword = it }) {
                                val connection = ui.model.connection.value
                                if (connection != null) run {
                                    phase = Phase.Sending
                                    connection.answerSignIn(request.id, request.host, otherUser, otherPassword, null)
                                    otherPassword = ""
                                    closeSoon()
                                    Phase.Sent(false)
                                }
                            }
                        }
                        if (p is Phase.Failed) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Rounded.Warning, contentDescription = null, tint = colors.red, modifier = Modifier.size(18.dp))
                                Text(p.message, color = colors.red, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                        if (isCode) FactRow(Icons.Rounded.Pin, stringResource(R.string.signin_fact_code))
                        else {
                            FactRow(Icons.Rounded.VisibilityOff, stringResource(R.string.signin_fact_no_password))
                            if (request.bitwarden == BitwardenState.UNLOCKED || request.bitwarden == BitwardenState.LOCKED) {
                                FactRow(Icons.Rounded.Key, stringResource(R.string.signin_fact_bitwarden))
                            }
                        }
                    }
                }
            }
        }
    }
}

enum class BitwardenNotice { LOCKED, NO_LOGIN, UNAVAILABLE }

/** What Bitwarden on the Mac can offer, when it offers nothing to choose. */
fun bitwardenNotice(request: SignInRequest): BitwardenNotice? = when (request.bitwarden) {
    BitwardenState.LOCKED -> BitwardenNotice.LOCKED
    BitwardenState.UNAVAILABLE -> BitwardenNotice.UNAVAILABLE
    BitwardenState.UNLOCKED -> if (request.choices.isEmpty()) BitwardenNotice.NO_LOGIN else null
    BitwardenState.OFF -> null
}

@Composable
private fun BitwardenNoticeCard(kind: BitwardenNotice, request: SignInRequest) {
    val isCode = request.field == SignInRequest.Field.CODE
    val (icon, title, text) = when (kind) {
        BitwardenNotice.LOCKED -> Triple(Icons.Rounded.Lock, stringResource(R.string.bw_locked), stringResource(R.string.bw_locked_text))
        BitwardenNotice.NO_LOGIN -> Triple(Icons.Rounded.Key,
            stringResource(if (isCode) R.string.bw_no_code_login else R.string.bw_no_login, request.host),
            stringResource(if (isCode) R.string.bw_type_code else R.string.bw_use_other))
        BitwardenNotice.UNAVAILABLE -> Triple(Icons.Rounded.Warning, stringResource(R.string.bw_no_answer),
            stringResource(if (isCode) R.string.bw_type_code else R.string.bw_use_other))
    }
    AosCard {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
            Text(title, style = MaterialTheme.typography.titleMedium)
        }
        Text(text, style = MaterialTheme.typography.bodyMedium, color = AosTheme.colors.secondary)
    }
}

@Composable
private fun LoginChooser(request: SignInRequest, selection: String?, onSelect: (String) -> Unit, onApprove: () -> Unit) {
    if (request.choices.isEmpty()) return
    val colors = AosTheme.colors
    Text(stringResource(R.string.from_bitwarden), style = MaterialTheme.typography.titleMedium)
    Surface(shape = RoundedCornerShape(20.dp), color = colors.card) {
        Column {
            request.choices.forEachIndexed { index, login ->
                Row(Modifier.fillMaxWidth().clickable { onSelect(login.id) }.padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Monogram(login.name)
                    Column(Modifier.weight(1f)) {
                        Text(login.username.ifEmpty { login.name }, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                        Text(login.name + if (login.hasCode) stringResource(R.string.with_one_time_code) else "",
                            style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                    }
                    Icon(if (selection == login.id) Icons.Rounded.RadioButtonChecked else Icons.Rounded.RadioButtonUnchecked,
                        contentDescription = null, tint = if (selection == login.id) colors.indigo else colors.secondary)
                }
                if (index < request.choices.lastIndex) HorizontalDivider(Modifier.padding(start = 62.dp), color = colors.separator)
            }
        }
    }
    Button(onClick = onApprove, enabled = selection != null, modifier = Modifier.fillMaxWidth().height(52.dp)) {
        Icon(Icons.Rounded.Fingerprint, contentDescription = null)
        Spacer(Modifier.size(8.dp))
        Text(stringResource(R.string.signin_approve))
    }
}

@Composable
private fun CodeChooser(request: SignInRequest, code: String, onCode: (String) -> Unit, sending: Boolean,
                        onApprove: (String) -> Unit, onSend: () -> Unit) {
    val colors = AosTheme.colors
    if (request.choices.isNotEmpty()) {
        Text(stringResource(R.string.from_bitwarden), style = MaterialTheme.typography.titleMedium)
        for (login in request.choices) {
            Button(onClick = { onApprove(login.id) }, enabled = !sending, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                Icon(Icons.Rounded.Fingerprint, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text(stringResource(R.string.signin_fill_code_from, login.name), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Text(stringResource(R.string.signin_code_from_bitwarden), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
    }
    Text(stringResource(if (request.choices.isEmpty()) R.string.one_time_code else R.string.signin_or_type_code), style = MaterialTheme.typography.titleMedium)
    OutlinedTextField(
        value = code, onValueChange = onCode, singleLine = true,
        placeholder = { Text("123456", fontFamily = FontFamily.Monospace, fontSize = 26.sp) },
        textStyle = MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.SmsOtpCode },
    )
    val enabled = code.isNotBlank() && !sending
    if (request.choices.isEmpty()) {
        Button(onClick = onSend, enabled = enabled, modifier = Modifier.fillMaxWidth().height(52.dp)) { SendLabel() }
    } else {
        FilledTonalButton(onClick = onSend, enabled = enabled, modifier = Modifier.fillMaxWidth().height(52.dp)) { SendLabel() }
    }
}

@Composable
private fun SendLabel() {
    Icon(Icons.AutoMirrored.Rounded.Send, contentDescription = null, modifier = Modifier.size(18.dp))
    Spacer(Modifier.size(8.dp))
    Text(stringResource(R.string.signin_send_code))
}

/** "From another password app": fields the phone's autofill service (a password app) fills. */
@Composable
private fun OtherPasswordApp(expanded: Boolean, onExpand: (Boolean) -> Unit, user: String, onUser: (String) -> Unit,
                             password: String, onPassword: (String) -> Unit, onSend: () -> Unit) {
    val colors = AosTheme.colors
    Surface(shape = RoundedCornerShape(20.dp), color = colors.card) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth().clickable { onExpand(!expanded) }, verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.signin_other_app), style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                Icon(if (expanded) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore, contentDescription = null, tint = colors.secondary)
            }
            AnimatedVisibility(expanded) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(user, onUser, label = { Text(stringResource(R.string.signin_user_field)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, autoCorrectEnabled = false),
                        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.Username })
                    OutlinedTextField(password, onPassword, label = { Text(stringResource(R.string.password)) }, singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.Password })
                    FilledTonalButton(onClick = onSend, enabled = password.isNotEmpty(), modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.AutoMirrored.Rounded.Send, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(stringResource(R.string.signin_send_this))
                    }
                    Text(stringResource(R.string.signin_other_app_explain), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                }
            }
        }
    }
}

@Composable
private fun SignInOutcome(result: SignInResult) {
    val colors = AosTheme.colors
    when (result) {
        SignInResult.FILLED -> NoticeCard(Icons.Rounded.CheckCircle, stringResource(R.string.signin_filled), colors.green)
        SignInResult.DECLINED -> NoticeCard(Icons.Rounded.PanTool, stringResource(R.string.declined), colors.secondary)
        SignInResult.EXPIRED -> NoticeCard(Icons.Rounded.TimerOff, stringResource(R.string.request_expired), colors.secondary)
        SignInResult.FAILED, SignInResult.UNKNOWN -> NoticeCard(Icons.Rounded.Warning, stringResource(R.string.signin_failed), colors.orange)
    }
}

// Approval

@Composable
private fun ApprovalContent(request: ApprovalRequest, close: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val results by ui.model.approvalResults.collectAsState()
    val result = results[request.id]
    var phase by remember(request.id) { mutableStateOf<Phase>(Phase.Choosing) }
    var answered by remember(request.id) { mutableStateOf<Boolean?>(null) }
    val left = secondsLeft(request.expires)
    val expired = left != null && left <= 0

    fun answer(allowed: Boolean) {
        val connection = ui.model.connection.value ?: return
        scope.launch {
            phase = Phase.Sending
            phase = try {
                connection.answerApproval(request.id, allowed)
                answered = allowed
                launch {
                    delay(4_000)
                    if (ui.model.presentedQuestion.value?.id == request.id) close()
                }
                Phase.Sent(false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Phase.Failed(ErrorText.of(e).resolve(context))
            }
        }
    }

    Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Rounded.AddToQueue, contentDescription = null, tint = colors.attention, modifier = Modifier.size(18.dp))
                Text(stringResource(R.string.request_wants_workspace, agentName(request.agent)), style = MaterialTheme.typography.titleSmall,
                    color = colors.attention)
            }
            Text(if (request.purpose.isEmpty()) stringResource(R.string.approval_open_workspace) else "„${request.purpose}“",
                style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                val minutes = request.minutes
                if (minutes != null && minutes > 0) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Rounded.HourglassTop, contentDescription = null, tint = colors.secondary, modifier = Modifier.size(16.dp))
                        Text(stringResource(R.string.approval_for_minutes, minutes), style = MaterialTheme.typography.labelLarge, color = colors.secondary)
                    }
                }
                if (left != null && result == null) Countdown(left)
            }
        }
        when {
            result != null -> ApprovalOutcome(result == ApprovalResult.ALLOWED)
            expired -> NoticeCard(Icons.Rounded.TimerOff, stringResource(R.string.request_expired), colors.secondary)
            else -> when (val p = phase) {
                Phase.Sending -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                is Phase.Sent -> ApprovalOutcome(answered == true)
                else -> {
                    Button(onClick = { answer(true) }, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                        Icon(Icons.Rounded.Check, contentDescription = null)
                        Spacer(Modifier.size(8.dp))
                        Text(stringResource(R.string.allow))
                    }
                    OutlinedButton(onClick = { answer(false) }, modifier = Modifier.fillMaxWidth().height(48.dp),
                        colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = colors.red)) {
                        Icon(Icons.Rounded.PanTool, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(stringResource(R.string.dont_allow))
                    }
                    if (p is Phase.Failed) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Rounded.Warning, contentDescription = null, tint = colors.red, modifier = Modifier.size(18.dp))
                            Text(p.message, color = colors.red, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        }
        FactRow(Icons.Rounded.DesktopWindows, stringResource(R.string.approval_fact))
    }
}

@Composable
private fun ApprovalOutcome(allowed: Boolean) {
    val colors = AosTheme.colors
    if (allowed) NoticeCard(Icons.Rounded.CheckCircle, stringResource(R.string.approval_allowed), colors.green)
    else NoticeCard(Icons.Rounded.PanTool, stringResource(R.string.approval_not_allowed), colors.secondary)
}


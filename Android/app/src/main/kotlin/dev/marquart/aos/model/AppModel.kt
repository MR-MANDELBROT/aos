package dev.marquart.aos.model

import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NetworkMonitor
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.core.ApprovalRequest
import dev.marquart.aos.core.ApprovalResult
import dev.marquart.aos.core.CompanionCommand
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.PairingRequest
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.SignInResult
import dev.marquart.aos.keys.DeviceKey
import dev.marquart.aos.keys.KeyProvider
import dev.marquart.aos.ssh.HostKeyPolicy
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.ssh.SshLogin
import dev.marquart.aos.store.MacStore
import dev.marquart.aos.store.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * The app's state, which the UI binds to (iOS Sources/App/AppModel.swift without its views): the paired Mac and the
 * connection to it, the agent's questions (sign-ins and workspace approvals in one queue, in the order they came, with
 * "Later"), help requests, and pairing. Everything observable is a StateFlow; the connection's own flows (Mac status,
 * workspace, chats, ...) are on `connection`.
 *
 * Plain class, one per app process (`AosApp.graph.model`); a ViewModel may hold it. Its methods may be called from any
 * thread.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppModel(
    private val keys: KeyProvider,
    private val macStore: MacStore,
    private val settings: SettingsStore,
    private val connector: SshConnector,
    private val pairingClient: PairingClient,
    private val network: NetworkMonitor,
    private val tailnet: TailnetDialer,
    private val defaultDeviceName: String,
    private val appVersion: String,
    private val connectionTiming: MacConnection.Timing = MacConnection.Timing(),
    /** Debug builds' demo (ui/demo): the Mac is this server in memory, nothing goes to the network. */
    val demo: MockCompanionServer? = null,
) {
    /** Something the agent asks the person to decide: a sign-in or opening the workspace. */
    sealed class Question {
        abstract val id: String
        abstract val expires: Instant?

        data class SignIn(val request: SignInRequest) : Question() {
            override val id get() = request.id
            override val expires get() = request.expires
        }

        data class Approval(val request: ApprovalRequest) : Question() {
            override val id get() = request.id
            override val expires get() = request.expires
        }
    }

    enum class PairingStepKind { CONTACTING_MAC, CHECKING_KEY, DONE }

    data class PairingStep(val kind: PairingStepKind, val mac: PairedMac? = null)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lock = Any()

    private val _macs = MutableStateFlow<List<PairedMac>>(emptyList())
    private val _connection = MutableStateFlow<MacConnection?>(null)
    private val _keyError = MutableStateFlow<String?>(null)
    private val _deviceName = MutableStateFlow(defaultDeviceName)
    private val _questions = MutableStateFlow<List<Question>>(emptyList())
    private val _presented = MutableStateFlow<Question?>(null)
    private val _signInResults = MutableStateFlow<Map<String, SignInResult>>(emptyMap())
    private val _approvalResults = MutableStateFlow<Map<String, ApprovalResult>>(emptyMap())
    private val _helpRequests = MutableStateFlow<List<HelpRequest>>(emptyList())
    private val _activeHelp = MutableStateFlow<HelpRequest?>(null)
    private val _loaded = MutableStateFlow(false)

    /** The paired Macs; the first is the one the app connects to. */
    val macs: StateFlow<List<PairedMac>> = _macs.asStateFlow()

    /** The connection to the active Mac (null while none is paired). */
    val connection: StateFlow<MacConnection?> = _connection.asStateFlow()

    /** The phone's keys couldn't be made (shown instead of pairing). */
    val keyError: StateFlow<String?> = _keyError.asStateFlow()
    val deviceName: StateFlow<String> = _deviceName.asStateFlow()

    /** Open questions in the order they came. */
    val questions: StateFlow<List<Question>> = _questions.asStateFlow()

    /** The question the sheet shows; open one with `present`, close through `closeQuestionSheet`. */
    val presentedQuestion: StateFlow<Question?> = _presented.asStateFlow()

    /** How finished requests ended, for the sheet that is still open. */
    val signInResults: StateFlow<Map<String, SignInResult>> = _signInResults.asStateFlow()
    val approvalResults: StateFlow<Map<String, ApprovalResult>> = _approvalResults.asStateFlow()
    val helpRequests: StateFlow<List<HelpRequest>> = _helpRequests.asStateFlow()

    /** The help request the screen shows (on the workspace); set when one arrives: the UI opens the Screen tab. */
    val activeHelp: StateFlow<HelpRequest?> = _activeHelp.asStateFlow()

    /** `load()` has run. */
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()

    /** The connection's state, also while there is no connection (Idle). */
    val connectionState: StateFlow<MacConnection.State> = _connection
        .flatMapLatest { it?.state ?: flowOf(MacConnection.State.Idle) }
        .stateIn(scope, SharingStarted.Eagerly, MacConnection.State.Idle)

    val companionState: StateFlow<MacConnection.CompanionState> = _connection
        .flatMapLatest { it?.companionState ?: flowOf(MacConnection.CompanionState.NotStarted) }
        .stateIn(scope, SharingStarted.Eagerly, MacConnection.CompanionState.NotStarted)

    val activeMac: PairedMac? get() = _macs.value.firstOrNull()
    val isPaired: Boolean get() = _macs.value.isNotEmpty()
    val signIns: List<SignInRequest> get() = _questions.value.mapNotNull { (it as? Question.SignIn)?.request }
    val approvals: List<ApprovalRequest> get() = _questions.value.mapNotNull { (it as? Question.Approval)?.request }
    val presentedSignIn: SignInRequest? get() = (_presented.value as? Question.SignIn)?.request

    /** Everything that waits for the person (for a badge). */
    val waitingCount: Int get() = _questions.value.size + _helpRequests.value.size

    // What the tabs ask of each other (iOS: AppModel.tab, screenTarget, openTerminal). The UI shows `tab`; the Screen
    // tab and the Terminal tab handle their requests once and clear them.

    enum class Tab { OVERVIEW, TERMINAL, SCREEN, SETTINGS }

    private val _tab = MutableStateFlow(Tab.OVERVIEW)
    private val _screenRequest = MutableStateFlow<ScreenTarget?>(null)
    private val _terminalRequest = MutableStateFlow<Long?>(null)

    /** The tab on screen. */
    val tab: StateFlow<Tab> = _tab.asStateFlow()

    /** A screen someone asked to see (the Overview's "Show the screen", a help request the person opened): the Screen
     *  tab connects it, as after a tap there, and calls `screenRequestHandled()`. */
    val screenRequest: StateFlow<ScreenTarget?> = _screenRequest.asStateFlow()

    /** "Open Terminal" (Claude Code on the Mac needs a sign-in): the Terminal tab opens the Mac's terminal in a new
     *  session there and calls `terminalRequestHandled()`. The value is when it was asked (each request is new). */
    val terminalRequest: StateFlow<Long?> = _terminalRequest.asStateFlow()

    fun selectTab(tab: Tab) {
        _tab.value = tab
    }

    /** The Screen tab with this screen. */
    fun showScreen(target: ScreenTarget) {
        _screenRequest.value = target
        _tab.value = Tab.SCREEN
    }

    fun screenRequestHandled() {
        _screenRequest.value = null
    }

    /** The Terminal tab with the Mac's terminal in a new session there. */
    fun openNewTerminal() {
        _terminalRequest.value = System.currentTimeMillis()
        _tab.value = Tab.TERMINAL
    }

    fun terminalRequestHandled() {
        _terminalRequest.value = null
    }

    private val deferred = HashSet<String>()
    private var pruneJob: Job? = null
    private var backgroundJob: Job? = null
    private var inBackground = false

    /** Reads the paired Macs and the settings, makes the keys if needed, and connects. Call once at start. */
    suspend fun load() {
        settings.current().deviceName?.takeIf { it.isNotBlank() }?.let { _deviceName.value = it }
        _macs.value = macStore.load()
        loadKeys()
        makeConnection()
        _loaded.value = true
    }

    private fun loadKeys(): Pair<DeviceKey, DeviceKey>? = try {
        (keys.sshKey() to keys.companionKey()).also { _keyError.value = null }
    } catch (e: Exception) {
        _keyError.value = e.message ?: e.javaClass.simpleName
        null
    }

    suspend fun setDeviceName(name: String) {
        _deviceName.value = name.ifBlank { defaultDeviceName }
        settings.update { it.copy(deviceName = name.ifBlank { null }) }
    }

    // Connection

    private fun makeConnection() {
        _connection.value?.close()
        _connection.value = null
        val mac = activeMac ?: return
        val (key, companionKey) = loadKeys() ?: return
        val connection = MacConnection(mac, key, CompanionSigner(key.phoneId, companionKey.signer), _deviceName.value,
            appVersion, connector, network, tailnet, connectionTiming)
        connection.onEvent = { handle(it) }
        connection.onMacChanged = { changed -> scope.launch { update(changed) } }
        _connection.value = connection
        if (demo != null) connection.startDemo(demo) else if (!inBackground) connection.start()
    }

    /** The app came to the foreground: connect again (a connection that looks alive is checked). */
    fun onForeground() {
        if (demo != null) return
        inBackground = false
        backgroundJob?.cancel()
        backgroundJob = null
        _connection.value?.start()
    }

    /** Something keeps the app running in the background and needs the connection (the terminal's foreground service
     *  while a terminal is open, terminal/TerminalKeepAliveService.kt): while it says so, the connection stays after
     *  the grace period (iOS: `keepAlive.holdsInBackground`). Asked every 5 s. */
    @Volatile var holdsConnectionInBackground: () -> Boolean = { false }

    /** The app left the foreground: keep the connection for a short while (a quick switch to another app), then let it
     *  go; a fresh connection on return is better than a dead one. Not while `holdsConnectionInBackground`. */
    fun onBackground() {
        if (demo != null) return
        inBackground = true
        backgroundJob?.cancel()
        backgroundJob = scope.launch {
            delay(settings.current().backgroundGraceSeconds * 1000L)
            while (holdsConnectionInBackground()) delay(BACKGROUND_HOLD_CHECK_MILLIS)
            _connection.value?.stop()
        }
    }

    // Pairing

    /** Pairs with the Mac in `link` (Docs/COMPANION.md, "Pairing"), reporting its steps; the new Mac becomes the
     *  active one and the app connects to it. */
    suspend fun pair(link: PairingLink, progress: (PairingStep) -> Unit = {}): PairedMac {
        val (key, signingKey) = loadKeys() ?: throw IllegalStateException("This phone's key couldn't be created: ${_keyError.value}")
        val name = PairingRequest.sanitizedDeviceName(_deviceName.value)
        progress(PairingStep(PairingStepKind.CONTACTING_MAC))
        val request = PairingRequest.make(name, key.openSSHPublicKey, signingKey.publicKeyX963, link.code)
        val (response, host) = pairingClient.send(request, link)

        progress(PairingStep(PairingStepKind.CHECKING_KEY))
        val user = response.user?.takeIf { it.isNotEmpty() } ?: link.user
        val ssh = connector.connectHosts(listOf(host) + link.hosts.filter { it != host }, link.sshPort, SshLogin(user, key),
            HostKeyPolicy.Fingerprint(link.hostKeyFingerprint))
        ssh.close()

        val mac = PairedMac(name = link.macName, hosts = link.hosts, sshPort = link.sshPort, user = user,
            hostKey = ssh.hostKey, hostKeyFingerprint = ssh.hostKeyFingerprint,
            companionPath = response.companion ?: CompanionCommand.DEFAULT_PATH, lastHost = ssh.host,
            way = link.way?.raw, tailnetHosts = link.tailnetHosts, tailnetName = link.tailnetName)
        // The same Mac paired again replaces its old entry.
        saveMacs(listOf(mac) + _macs.value.filter { it.hostKeyFingerprint != mac.hostKeyFingerprint })
        makeConnection()
        progress(PairingStep(PairingStepKind.DONE, mac))
        return mac
    }

    /** Forgets a Mac (the Mac keeps its key line until it is removed there, as on the iPhone). */
    suspend fun unpair(mac: PairedMac) {
        saveMacs(_macs.value.filter { it.id != mac.id })
        synchronized(lock) {
            _questions.value = emptyList()
            deferred.clear()
            _presented.value = null
            _helpRequests.value = emptyList()
            _activeHelp.value = null
        }
        makeConnection()
    }

    /** Makes another paired Mac the one the app connects to. */
    suspend fun makeActive(mac: PairedMac) {
        val index = _macs.value.indexOfFirst { it.id == mac.id }
        if (index <= 0) return
        saveMacs(listOf(_macs.value[index]) + _macs.value.filterIndexed { i, _ -> i != index })
        makeConnection()
    }

    private suspend fun update(mac: PairedMac) {
        val index = _macs.value.indexOfFirst { it.id == mac.id }
        if (index < 0) return
        saveMacs(_macs.value.toMutableList().also { it[index] = mac })
    }

    private suspend fun saveMacs(macs: List<PairedMac>) {
        macStore.save(macs)
        _macs.value = macs
    }

    // Requests from the agent

    fun handle(event: CompanionEvent) {
        synchronized(lock) {
            when (event) {
                is CompanionEvent.SignIn -> ask(Question.SignIn(event.request))
                is CompanionEvent.SignInClosed -> {
                    _signInResults.value = _signInResults.value + (event.request to event.result)
                    settled(event.request)
                }
                is CompanionEvent.Approval -> ask(Question.Approval(event.request))
                is CompanionEvent.ApprovalClosed -> {
                    _approvalResults.value = _approvalResults.value + (event.request to event.result)
                    settled(event.request)
                }
                is CompanionEvent.Help -> {
                    if (_helpRequests.value.none { it.id == event.request.id }) {
                        _helpRequests.value = _helpRequests.value + event.request
                        // Shown on the Screen tab; the workspace connects when the person taps it.
                        _activeHelp.value = event.request
                        _tab.value = Tab.SCREEN
                    }
                }
                is CompanionEvent.HelpClosed -> {
                    _helpRequests.value = _helpRequests.value.filter { it.id != event.request }
                    if (_activeHelp.value?.id == event.request) _activeHelp.value = _helpRequests.value.lastOrNull()
                }
                else -> Unit
            }
        }
    }

    /** A new question: queued, and shown unless another one is open. One the app has already comes again (after a new
     *  subscribe, or because the Mac has news for it: Bitwarden was unlocked) and is updated where it is. */
    private fun ask(question: Question) {
        val index = _questions.value.indexOfFirst { it.id == question.id }
        if (index >= 0) {
            _questions.value = _questions.value.toMutableList().also { it[index] = question }
            if (_presented.value?.id == question.id) _presented.value = question
            return
        }
        _questions.value = _questions.value + question
        if (_presented.value == null) _presented.value = question
        schedulePruning()
    }

    /** The Mac closed a question (answered here, elsewhere, or expired): the sheet shows the result for a moment. */
    private fun settled(id: String) {
        _questions.value = _questions.value.filter { it.id != id }
        deferred.remove(id)
        if (_presented.value?.id != id) return
        scope.launch {
            delay(SETTLED_SHOWN_MILLIS)
            if (_presented.value?.id == id) closeQuestionSheet()
        }
    }

    /** Opens a question from the overview. */
    fun present(question: Question) = synchronized(lock) {
        deferred.remove(question.id)
        _presented.value = question
    }

    /** The help request the Screen tab shows (the overview's banner was tapped). */
    fun showHelp(request: HelpRequest) {
        _activeHelp.value = request
        showScreen(ScreenTarget.WORKSPACE)
    }

    /** The question sheet closed (answered, declined, "Later" or swiped away). A question that is still open stays in
     *  the overview without popping up again; the next new one comes up. */
    fun closeQuestionSheet() {
        val next = synchronized(lock) {
            _presented.value?.id?.let { id -> if (_questions.value.any { it.id == id }) deferred += id }
            _presented.value = null
            _questions.value.firstOrNull { it.id !in deferred && !isExpired(it) }
        } ?: return
        scope.launch {
            delay(NEXT_QUESTION_MILLIS)
            synchronized(lock) {
                if (_presented.value == null && _questions.value.any { it.id == next.id }) _presented.value = next
            }
        }
    }

    fun isExpired(question: Question, now: Instant = Instant.now()): Boolean = question.expires?.let { !it.isAfter(now) } ?: false

    /** Forgets expired questions now and then (the Mac closes them too, with `signin.closed` or `approval.closed`). */
    private fun schedulePruning() {
        if (pruneJob?.isActive == true) return
        pruneJob = scope.launch {
            while (_questions.value.isNotEmpty()) {
                delay(5_000)
                synchronized(lock) {
                    val now = Instant.now()
                    _questions.value = _questions.value.filter { q ->
                        val expires = q.expires ?: return@filter true
                        !(expires.plusSeconds(30).isBefore(now) && _presented.value?.id != q.id)
                    }
                    deferred.retainAll(_questions.value.map { it.id }.toSet())
                }
            }
        }
    }

    /** The person is done helping: the Mac hears it, the request goes. */
    suspend fun finishHelp(request: HelpRequest) {
        runCatching { _connection.value?.helpDone(request.id) }
        synchronized(lock) {
            _helpRequests.value = _helpRequests.value.filter { it.id != request.id }
            if (_activeHelp.value?.id == request.id) _activeHelp.value = null
        }
    }

    companion object {
        const val SETTLED_SHOWN_MILLIS = 1_600L
        const val NEXT_QUESTION_MILLIS = 450L
        const val BACKGROUND_HOLD_CHECK_MILLIS = 5_000L
    }
}

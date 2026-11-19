package dev.marquart.aos.connection

import dev.marquart.aos.companion.CompanionClient
import dev.marquart.aos.companion.CompanionError
import dev.marquart.aos.companion.ExecTransport
import dev.marquart.aos.core.ChatList
import dev.marquart.aos.core.CompanionCommand
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionRequest
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.ConnectionPlan
import dev.marquart.aos.core.HelloResult
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacActionResult
import dev.marquart.aos.core.MacStatus
import dev.marquart.aos.core.MacTermSession
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.ReachWay
import dev.marquart.aos.core.SSHRoute
import dev.marquart.aos.core.ScreenEndpoint
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.TermAttach
import dev.marquart.aos.core.WorkspaceOperation
import dev.marquart.aos.core.WorkspaceStatus
import dev.marquart.aos.core.termEndResult
import dev.marquart.aos.keys.DeviceKey
import dev.marquart.aos.ssh.HostKeyPolicy
import dev.marquart.aos.ssh.SessionChannel
import dev.marquart.aos.ssh.SshConnectException
import dev.marquart.aos.ssh.SshConnection
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.ssh.SshLogin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Instant

/**
 * The connection to the paired Mac (iOS Sources/App/MacConnection.swift): SSH along `ConnectionPlan`'s routes with the
 * host key pinned at pairing, reconnecting on its own (1 s, doubling up to 30 s; at once after a connection that lived
 * more than 10 s, on network changes and when aOS's Tailscale comes up), and inside it the companion API: hello,
 * subscribe, status, then events, with a `status` heartbeat every 25 s (no answer: the companion starts again).
 *
 * Everything observable is a StateFlow; the UI and the terminal and screen code read these. All mutation happens on one
 * serial dispatcher, so the state machine never runs twice at once (as the iPhone's main actor).
 *
 * The terminal agent: `ssh` (the live SshConnection: `terminal(...)`, `run(...)`), `mac.companionPath`, `phoneId`,
 * `termSessions()`, `endTermSession(id)`. The screen agent: `screenEndpoint(target)`, `display(size)`, `ssh` for a
 * `LocalForwarder`, `connectedRoute` for the direct path.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MacConnection(
    mac: PairedMac,
    private val key: DeviceKey,
    /** Signs every companion request (the Mac refuses unsigned ones); null only in tests of old behavior. */
    private val signer: CompanionSigner?,
    private val deviceName: String,
    private val appVersion: String,
    private val connector: SshConnector,
    private val network: NetworkMonitor = FixedNetworkMonitor(),
    private val tailnet: TailnetDialer = NoTailnet,
    private val timing: Timing = Timing(),
) {
    data class Timing(
        val heartbeatMillis: Long = 25_000,
        val probeTimeoutMillis: Long = 5_000,
        val firstBackoffMillis: Long = 1_000,
        val maxBackoffMillis: Long = 30_000,
        val companionRetrySeconds: Int = 15,
        val pairAgainRetrySeconds: Int = 60,
        val sleepGraceMillis: Long = 20_000,
        val operationPollMillis: Long = 3_000,
        /** A connection that lived longer than this reconnects at once when it ends. */
        val livedMillis: Long = 10_000,
    )

    sealed class State {
        data object Idle : State()
        data object Connecting : State()
        data class Connected(val host: String, val route: SSHRoute) : State()

        /** Not reachable right now; tries again by itself (at `nextAttempt`). */
        data class Unreachable(val message: String, val nextAttempt: Instant? = null) : State()

        /** Needs the person (the Mac's key changed, or it no longer accepts this phone); no automatic retries. */
        data class NeedsAttention(val message: String) : State()
    }

    sealed class CompanionState {
        data object NotStarted : CompanionState()
        data object Starting : CompanionState()
        data object Ready : CompanionState()

        /** SSH works, but aOS on the Mac doesn't answer (not installed, too old, not running). */
        data class Unavailable(val message: String) : CompanionState()

        /** The Mac has no signing key for this phone and refuses its requests: pair again. */
        data object NeedsPairing : CompanionState()
    }

    private val serial = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + serial)

    private val _mac = MutableStateFlow(mac)
    private val _state = MutableStateFlow<State>(State.Idle)
    private val _companionState = MutableStateFlow<CompanionState>(CompanionState.NotStarted)
    private val _hello = MutableStateFlow<HelloResult?>(null)
    private val _workspace = MutableStateFlow<WorkspaceStatus?>(null)
    private val _macStatus = MutableStateFlow<MacStatus?>(null)
    private val _chats = MutableStateFlow<ChatList?>(null)
    private val _macAppProblem = MutableStateFlow<String?>(null)
    private val _ssh = MutableStateFlow<SshConnection?>(null)
    private val _companion = MutableStateFlow<CompanionClient?>(null)
    private val _workspaceOperation = MutableStateFlow<WorkspaceOperation?>(null)
    private val _workspaceTimeout = MutableStateFlow<WorkspaceOperation?>(null)
    private val _sleepingSince = MutableStateFlow<Instant?>(null)

    /** The paired Mac (its `lastHost` follows the address that worked). */
    val mac: StateFlow<PairedMac> = _mac.asStateFlow()
    val state: StateFlow<State> = _state.asStateFlow()
    val companionState: StateFlow<CompanionState> = _companionState.asStateFlow()
    val hello: StateFlow<HelloResult?> = _hello.asStateFlow()
    val workspace: StateFlow<WorkspaceStatus?> = _workspace.asStateFlow()

    /** The Overview: battery, lid, display, staying awake, workspace, Claude Code, Bitwarden (`mac.status`). */
    val macStatus: StateFlow<MacStatus?> = _macStatus.asStateFlow()

    /** The chats as `chats.list` reported them last; null before, and from a Mac that doesn't have them. */
    val chats: StateFlow<ChatList?> = _chats.asStateFlow()

    /** Set while `aos-companion` can't reach the aOS app on the Mac (it keeps trying): what it said. */
    val macAppProblem: StateFlow<String?> = _macAppProblem.asStateFlow()

    /** The live SSH connection, while connected (terminal channels, `LocalForwarder` for the screens). */
    val ssh: StateFlow<SshConnection?> = _ssh.asStateFlow()

    /** The companion client, while it runs. */
    val companion: StateFlow<CompanionClient?> = _companion.asStateFlow()

    /** A start or close of the workspace from this phone that the Mac hasn't finished yet. */
    val workspaceOperation: StateFlow<WorkspaceOperation?> = _workspaceOperation.asStateFlow()

    /** The last start or close took too long (until the next one, or until the workspace gets there after all). */
    val workspaceTimeout: StateFlow<WorkspaceOperation?> = _workspaceTimeout.asStateFlow()

    /** Since when the Mac sleeps: it was put to sleep from here and hasn't answered since. */
    val sleepingSince: StateFlow<Instant?> = _sleepingSince.asStateFlow()

    /** Events from the Mac go to the app model (called on the connection's dispatcher). */
    @Volatile var onEvent: ((CompanionEvent) -> Unit)? = null

    /** The Mac's record changed (the address that worked); the app saves it. */
    @Volatile var onMacChanged: ((PairedMac) -> Unit)? = null

    /** This phone's id on the Mac (`--client` for `term attach`). */
    val phoneId: String get() = key.phoneId

    val isConnected: Boolean get() = _state.value is State.Connected

    /** How the Mac was reached (same network, tailnet, Bonjour), while connected. */
    val connectedRoute: SSHRoute? get() = _ssh.value?.route

    /** aOS on the Mac is older and doesn't know the Overview's ops. */
    val macStatusUnsupported: Boolean
        get() {
            val hello = _hello.value ?: return false
            return _companionState.value == CompanionState.Ready && MacAction.STATUS.raw !in hello.features
        }

    /** aOS on the Mac lists its chats (an older one only counts the kept ones in `mac.status`). */
    val chatsSupported: Boolean
        get() = _companionState.value == CompanionState.Ready && _hello.value?.features?.contains(MacAction.CHATS_LIST.raw) == true

    /** The workspace's state as the Mac reports it (mac.status if this Mac knows it, else the older status). */
    val reportedWorkspaceState: String? get() = _macStatus.value?.workspace?.state ?: _workspace.value?.state?.name

    /** The state to show: as reported, or "starting"/"closing" while a start or close from here is under way. */
    val workspaceState: String? get() = _workspaceOperation.value?.shownState ?: reportedWorkspaceState

    private var loop: Job? = null
    private var watchers: Job? = null
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var sleepGrace: Instant? = null
    private var probing = false
    private var operationWatch: Job? = null

    /** Starts connecting (and keeps the connection up) until `stop()`. Called again (the app came back to the
     *  foreground): a live-looking connection is checked, a dead one retried at once. */
    fun start() {
        scope.launch {
            if (loop != null) {
                if (isConnected) probe() else retryNow()
                return@launch
            }
            if (_state.value is State.NeedsAttention) return@launch
            loop = scope.launch { run() }
            watchers = scope.launch { watch() }
            tailnet.startIfSetUp()
        }
    }

    /** Stops: closes the companion and the SSH connection, no more attempts. */
    fun stop() {
        scope.launch { stopNow() }
    }

    private suspend fun stopNow() {
        loop?.cancel()
        loop = null
        watchers?.cancel()
        watchers = null
        val ssh = _ssh.value
        val companion = _companion.value
        _ssh.value = null
        _companion.value = null
        _companionState.value = CompanionState.NotStarted
        if (_state.value !is State.NeedsAttention) _state.value = State.Idle
        withContext(NonCancellable) {
            companion?.close()
            ssh?.close()
        }
    }

    /** Tries again now instead of waiting (pull to refresh, the app came back, the network changed). */
    fun retryNow() {
        scope.launch {
            if (_state.value is State.NeedsAttention) {
                _state.value = State.Idle
                stopNow()
                loop = scope.launch { run() }
                watchers = scope.launch { watch() }
                return@launch
            }
            wake.trySend(Unit)
        }
    }

    /** Ends everything for good (the Mac was unpaired). */
    fun close() {
        scope.launch {
            stopNow()
            scope.coroutineContext[Job]?.cancel()
        }
    }

    // Requests for the views

    private fun readyCompanion(): CompanionClient {
        val companion = _companion.value
        if (companion == null || _companionState.value != CompanionState.Ready) throw CompanionError.Closed
        return companion
    }

    /** Where a screen is. The Mac's own screen is screen sharing on the Mac itself: without the companion that's still
     *  known. The workspace's comes sealed (`CompanionClient.workspaceLogin`). */
    suspend fun screenEndpoint(target: ScreenTarget): ScreenEndpoint {
        val companion = _companion.value
        if (companion == null || _companionState.value != CompanionState.Ready) {
            if (target == ScreenTarget.MAC) return ScreenEndpoint("127.0.0.1", 5900)
            throw CompanionError.Closed
        }
        return companion.screen(target)
    }

    // Sign-in answers name the request's website too: the signature covers it and the Mac checks it.

    suspend fun answerSignIn(request: String, host: String, login: String) =
        (_companion.value ?: throw CompanionError.Closed).answerSignIn(request, host, login)

    suspend fun answerSignIn(request: String, host: String, username: String, password: String, totp: String?) =
        (_companion.value ?: throw CompanionError.Closed).answerSignIn(request, host, username, password, totp)

    suspend fun declineSignIn(request: String, host: String) =
        (_companion.value ?: throw CompanionError.Closed).declineSignIn(request, host)

    suspend fun answerSignInCode(request: String, host: String, code: String) =
        (_companion.value ?: throw CompanionError.Closed).answerSignInCode(request, host, code)

    suspend fun helpDone(request: String) = (_companion.value ?: throw CompanionError.Closed).helpDone(request)

    suspend fun answerApproval(request: String, allowed: Boolean) =
        (_companion.value ?: throw CompanionError.Closed).answerApproval(request, allowed)

    /** Types text into the running workspace. */
    suspend fun typeInWorkspace(text: String) = (_companion.value ?: throw CompanionError.Closed).type(text)

    /** The workspace's display in the phone's shape ("WIDTHxHEIGHT@SCALE", renewed every 20 s) or "reset". */
    suspend fun display(size: String): Pair<Int, Int> = readyCompanion().display(size)

    suspend fun refreshStatus() = withContext(serial) {
        val companion = _companion.value ?: return@withContext
        if (_companionState.value != CompanionState.Ready) return@withContext
        runCatching { companion.status() }.getOrNull()?.let { setWorkspace(it) }
    }

    suspend fun refreshMacStatus() = withContext(serial) {
        val companion = _companion.value ?: return@withContext
        if (_companionState.value != CompanionState.Ready || macStatusUnsupported) return@withContext
        runCatching { companion.mac(MacAction.STATUS) }.getOrNull()?.status?.let { setMacStatus(it) }
    }

    suspend fun refreshChats() = withContext(serial) {
        val companion = _companion.value ?: return@withContext
        if (!chatsSupported) return@withContext
        val result = runCatching { companion.mac(MacAction.CHATS_LIST) }.getOrNull() ?: return@withContext
        result.chats?.let { _chats.value = it }
        result.status?.let { setMacStatus(it) }
    }

    /**
     * An action of the Overview (signed like every request). The status that comes back is shown at once. Starting
     * and closing the workspace stay under way until the Mac reports it done (`workspaceOperation`). Throws
     * `MacRefusal` (with the Mac's code) or a `CompanionError`.
     */
    suspend fun perform(action: MacAction, value: String? = null): MacActionResult = withContext(serial) {
        val companion = readyCompanion()
        val operation = WorkspaceOperation.of(action, reportedWorkspaceState)
        if (operation != null) {
            _workspaceTimeout.value = null
            _workspaceOperation.value = operation
        }
        val result = try {
            companion.mac(action, value)
        } catch (e: Throwable) {
            // Refused or no answer: nothing under way (the card says what went wrong).
            if (operation != null && _workspaceOperation.value?.since == operation.since) _workspaceOperation.value = null
            throw e
        }
        result.status?.let { setMacStatus(it) }
        result.chats?.let { _chats.value = it }
        if (operation != null && _workspaceOperation.value != null) watchWorkspaceOperation()
        if (action == MacAction.SLEEP) result.sleepsIn?.let { macGoesToSleep(it) }
        if (action.changesChat) {
            // The answer has the new choice; aOS's keeper on the Mac starts or ends the chat a moment later.
            scope.launch {
                for (pause in listOf(2_000L, 5_000L)) {
                    delay(pause)
                    refreshChats()
                }
            }
        }
        result
    }

    /** The Mac's terminal sessions (`term list --json`), or null when it can't say (an older aOS). */
    suspend fun termSessions(): List<MacTermSession>? {
        val ssh = _ssh.value ?: throw CompanionError.Closed
        return TermAttach.sessions(ssh.run(TermAttach.list(_mac.value.companionPath)))
    }

    /** Ends a terminal session on the Mac (`term end <id>`): true when it ended, false when it was gone already. */
    suspend fun endTermSession(id: String): Boolean {
        val ssh = _ssh.value ?: throw CompanionError.Closed
        val command = TermAttach.end(_mac.value.companionPath, id) ?: return false
        return termEndResult(ssh.run(command)) ?: false
    }

    // Starting and closing the workspace

    private fun setWorkspace(status: WorkspaceStatus) {
        _workspace.value = status
        updateWorkspaceOperation()
    }

    private fun setMacStatus(status: MacStatus) {
        _macStatus.value = status
        updateWorkspaceOperation()
    }

    /** After every new state: whether the start or close under way is done, failed or took too long. */
    private fun updateWorkspaceOperation(now: Instant = Instant.now()) {
        val state = reportedWorkspaceState
        _workspaceTimeout.value?.let { if (it.arrived(state)) _workspaceTimeout.value = null }
        val operation = _workspaceOperation.value ?: return
        val (outcome, next) = operation.observe(state, now)
        when (outcome) {
            WorkspaceOperation.Outcome.UNDER_WAY -> {
                if (next != operation) _workspaceOperation.value = next
                return
            }
            WorkspaceOperation.Outcome.DONE, WorkspaceOperation.Outcome.FAILED -> _workspaceOperation.value = null
            WorkspaceOperation.Outcome.TIMED_OUT -> {
                // Only from what the Mac says: not while it can't be asked (it may be done by the time it answers).
                if (_companionState.value != CompanionState.Ready) return
                _workspaceOperation.value = null
                _workspaceTimeout.value = next
            }
        }
        operationWatch?.cancel()
        operationWatch = null
    }

    /** Asks for the Mac's status every 3 s while a start or close is under way (its events say so too). */
    private fun watchWorkspaceOperation() {
        operationWatch?.cancel()
        operationWatch = scope.launch {
            while (isActive) {
                delay(timing.operationPollMillis)
                if (_workspaceOperation.value == null) return@launch
                refreshMacStatus()
                updateWorkspaceOperation()
            }
        }
    }

    // The Mac asleep

    /** The Mac sleeps in `after` s. Its connection then dies without a word, so it is closed here 0.5 s after: the
     *  app shows at once that the Mac sleeps, and no attempt runs for 20 s more (it could reach or wake the Mac). */
    fun macGoesToSleep(after: Double) {
        scope.launch {
            val now = Instant.now()
            _sleepingSince.value = now
            sleepGrace = now.plusMillis((after * 1000).toLong() + timing.sleepGraceMillis)
            val ssh = _ssh.value
            scope.launch {
                delay((after * 1000).toLong() + 500)
                if (ssh != null && _ssh.value === ssh) ssh.close()
            }
        }
    }

    // Running

    private suspend fun run() {
        var backoff = timing.firstBackoffMillis
        while (currentCoroutineContextActive()) {
            sleepGrace?.let { grace ->
                val wait = grace.toEpochMilli() - System.currentTimeMillis()
                if (wait > 0) {
                    // The Mac is falling asleep: no attempt until it had the time to (also not when woken).
                    _state.value = State.Unreachable("The Mac is going to sleep.", grace)
                    delay(wait)
                }
            }
            _state.value = State.Connecting
            try {
                val mac = _mac.value
                // The same network first, then the tailnet (aOS's node, the Tailscale app's VPN), then Bonjour.
                val routes = ConnectionPlan.routes(mac, tailnet.isRunning, network.tailscaleVpnActive())
                val connection = connector.connect(routes, mac.sshPort, SshLogin(mac.user, key), HostKeyPolicy.Pinned(mac.hostKey))
                _ssh.value = connection
                // It answers: awake again (woken on the Mac, or it didn't sleep after all).
                _sleepingSince.value = null
                sleepGrace = null
                _state.value = State.Connected(connection.host, connection.route)
                val connectedAt = System.currentTimeMillis()
                if (mac.lastHost != connection.host) {
                    val updated = mac.copy(lastHost = connection.host)
                    _mac.value = updated
                    onMacChanged?.invoke(updated)
                }
                serve(connection)
                _ssh.value = null
                _companion.value = null
                // No companion without the connection: nothing reads as current any more.
                if (_companionState.value != CompanionState.NeedsPairing) _companionState.value = CompanionState.NotStarted
                withContext(NonCancellable) { connection.close() }
                if (System.currentTimeMillis() - connectedAt > timing.livedMillis) {
                    backoff = timing.firstBackoffMillis
                    continue
                }
                _state.value = State.Unreachable("The connection to the Mac ended.")
            } catch (e: CancellationException) {
                throw e
            } catch (e: SshConnectException) {
                when (e) {
                    is SshConnectException.HostKeyMismatch, is SshConnectException.AuthenticationFailed -> {
                        _state.value = State.NeedsAttention(message(e))
                        loop = null
                        return
                    }
                    is SshConnectException.Unreachable -> _state.value = State.Unreachable(unreachableMessage())
                    else -> _state.value = State.Unreachable(message(e))
                }
            } catch (e: Exception) {
                _state.value = State.Unreachable(e.message ?: "The Mac isn't reachable.")
            }
            // Wait for the next attempt, or less when `retryNow()` wakes the loop.
            val next = Instant.now().plusMillis(backoff)
            (_state.value as? State.Unreachable)?.let { _state.value = it.copy(nextAttempt = next) }
            withTimeoutOrNull(backoff) { wake.receive() }
            backoff = minOf(backoff * 2, timing.maxBackoffMillis)
        }
    }

    private suspend fun currentCoroutineContextActive(): Boolean = kotlin.coroutines.coroutineContext.isActive

    /** Runs the companion for as long as the SSH connection is up; restarts it if it ends early. */
    private suspend fun serve(connection: SshConnection) {
        while (connection.isActive && currentCoroutineContextActive()) {
            _companionState.value = CompanionState.Starting
            var started: CompanionClient? = null
            try {
                val channel = connection.exec(CompanionCommand.serve(_mac.value.companionPath))
                val client = CompanionClient(ExecTransport(channel), signer)
                started = client
                client.start()
                _companion.value = client
                _hello.value = client.hello(appVersion, deviceName)
                // Subscribe first: the Mac then sends the questions that are still open, then everything new.
                client.subscribe()
                setWorkspace(client.status())
                _companionState.value = CompanionState.Ready
                val heartbeat = scope.launch { beat(client) }
                try {
                    client.events.collect { handle(it) }
                } finally {
                    heartbeat.cancel()
                }
                _companion.value = null
                _macAppProblem.value = null
                if (connection.isActive && _companionState.value != CompanionState.NeedsPairing) {
                    _companionState.value = CompanionState.Unavailable("aOS on the Mac stopped answering.")
                }
            } catch (e: CancellationException) {
                withContext(NonCancellable) { started?.close() }
                throw e
            } catch (e: CompanionError.PairAgain) {
                // The Mac has no signing key for this phone: nothing works until it is paired again.
                _companion.value = null
                withContext(NonCancellable) { started?.close() }
                _companionState.value = CompanionState.NeedsPairing
            } catch (e: Exception) {
                _companion.value = null
                withContext(NonCancellable) { started?.close() }
                _companionState.value = CompanionState.Unavailable(companionMessage(e))
            }
            // Try the companion again after a while (aOS on the Mac may be starting or updating; without a key on the
            // Mac only pairing helps, so not so often).
            val pause = if (_companionState.value == CompanionState.NeedsPairing) timing.pairAgainRetrySeconds else timing.companionRetrySeconds
            for (i in 0 until pause) {
                if (!connection.isActive || !currentCoroutineContextActive()) break
                delay(1000)
            }
        }
    }

    private fun handle(event: CompanionEvent) {
        when (event) {
            is CompanionEvent.Workspace -> {
                val current = _workspace.value
                setWorkspace(current?.copy(state = event.state) ?: WorkspaceStatus(event.state))
                scope.launch {
                    refreshStatus()
                    refreshMacStatus()
                }
            }
            // A chat started or ended on the Mac: the list now, not at the next poll.
            CompanionEvent.Chats -> scope.launch { refreshChats() }
            is CompanionEvent.Mac -> _macAppProblem.value = if (event.state == "unavailable") event.detail else null
            CompanionEvent.SubscriptionEnded -> scope.launch { resubscribe() }
            else -> Unit
        }
        onEvent?.invoke(event)
    }

    /** The Mac ended the event subscription (it restarted, or a day went by): a new signed subscribe; the Mac then
     *  sends the open questions again. */
    private suspend fun resubscribe() {
        val companion = _companion.value ?: return
        try {
            companion.subscribe()
        } catch (_: CompanionError.PairAgain) {
            _companionState.value = CompanionState.NeedsPairing
            companion.close()
        } catch (_: Exception) {
        }
    }

    /** Every 25 s a `status`: the Mac counts the phone as connected while it asked within 45 s, the workspace line stays
     *  fresh, and a companion that stopped answering is noticed (its channel is closed and started again). */
    private suspend fun beat(client: CompanionClient) {
        while (currentCoroutineContextActive()) {
            delay(timing.heartbeatMillis)
            try {
                setWorkspace(client.status())
                _macAppProblem.value = null
            } catch (_: CompanionError.Timeout) {
                client.close()
                return
            } catch (e: CompanionError.Refused) {
                _macAppProblem.value = e.reason
            } catch (_: CompanionError.PairAgain) {
                // Removed on the Mac meanwhile.
                _companionState.value = CompanionState.NeedsPairing
                client.close()
                return
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                return
            }
        }
    }

    /** Network changes: a new network is a good moment to try again; another way out while connected (Wi-Fi to
     *  cellular) may have killed the connection without anyone noticing, so it is checked. Also aOS's Tailscale coming
     *  up: a new way to the Mac. */
    private suspend fun watch() {
        scope.launch {
            tailnet.ready.collect { if (!isConnected) retryNow() }
        }
        var last: NetworkPath? = null
        network.path.collect { path ->
            val previous = last
            last = path
            if (previous == null) return@collect
            if (path.satisfied && !isConnected) retryNow()
            if (path.satisfied && isConnected && previous.interfaceId != null && path.interfaceId != previous.interfaceId) probe()
        }
    }

    /** Asks the Mac something small; without an answer within 5 s the connection is closed and built again (the
     *  terminals attach again by themselves). */
    fun probe() {
        scope.launch {
            if (probing) return@launch
            val ssh = _ssh.value ?: return@launch
            probing = true
            try {
                val companion = _companion.value
                val alive = if (companion != null && _companionState.value == CompanionState.Ready) {
                    // Any answer counts, also a refusal.
                    runCatching { companion.request(CompanionRequest.Status, timing.probeTimeoutMillis, refusalsThrow = false) }.isSuccess
                } else {
                    runCatching { ssh.run("true", timing.probeTimeoutMillis) }.isSuccess
                }
                if (!alive && _ssh.value === ssh) ssh.close()
            } finally {
                probing = false
            }
        }
    }

    /** Waits until the companion is ready (or `timeoutMillis` passed); true when it is. */
    suspend fun awaitReady(timeoutMillis: Long): Boolean = withTimeoutOrNull(timeoutMillis) {
        _companionState.first { it == CompanionState.Ready }
        true
    } ?: false

    // Text (English; the UI words these itself where it wants)

    fun message(error: SshConnectException): String = when (error) {
        is SshConnectException.HostKeyMismatch ->
            "At ${error.host} a different computer answered, or the Mac's SSH key changed. If you set the Mac up again, pair it again."
        is SshConnectException.AuthenticationFailed -> "The Mac no longer accepts this phone. Pair again in aOS on the Mac."
        SshConnectException.LocalNetworkDenied -> "aOS may not use the local network. Allow it in the app's settings."
        is SshConnectException.Unreachable -> "The Mac isn't reachable. Outside your home network you need Tailscale or another VPN to reach it."
        is SshConnectException.UnknownHostKey -> "The Mac's key is unknown."
    }

    /** Not reachable: what would help, by the Mac's way on the go. */
    fun unreachableMessage(): String {
        val notThroughTailscale = "The Mac isn't reachable, also not through Tailscale. Is it awake, and is Tailscale on there?"
        return when (_mac.value.reachWay) {
            ReachWay.AOS_TAILSCALE -> when {
                !tailnet.isSetUp -> "The Mac isn't reachable. On the go, set up aOS's Tailscale on this phone: Settings > Connection."
                tailnet.isRunning -> notThroughTailscale
                else -> "The Mac isn't reachable, and aOS's Tailscale on this phone isn't connected (Settings > Connection)."
            }
            ReachWay.TAILSCALE_APP -> if (tailnet.isRunning || network.tailscaleVpnActive()) notThroughTailscale
                else "The Mac isn't reachable. On the go, switch on Tailscale on this phone (the Tailscale app, or aOS's Tailscale in Settings > Connection)."
            ReachWay.LOCAL_NETWORK -> "The Mac isn't reachable. Your Mac is set up for the same network only; to reach it on the go, choose a way with Tailscale in aOS on the Mac."
            null -> message(SshConnectException.Unreachable(emptyList()))
        }
    }

    companion object {
        fun companionMessage(error: Throwable): String {
            val failure = (error as? CompanionError.ChannelEnded)?.failure ?: error
            if (failure is SessionChannel.Failure.Exited && failure.status == 127) {
                return "aOS isn't installed on the Mac where it was paired. Open aOS on the Mac and pair again."
            }
            if (error == CompanionError.Timeout) return "aOS on the Mac doesn't answer."
            return "aOS on the Mac isn't ready: ${error.message}"
        }
    }
}

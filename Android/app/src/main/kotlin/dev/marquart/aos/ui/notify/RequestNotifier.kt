package dev.marquart.aos.ui.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import dev.marquart.aos.MainActivity
import dev.marquart.aos.R
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Requests that arrive while the app is in the background but still connected (the 25 s after leaving it, or while
 * something keeps the connection): a notification each, in the channel "Requests". Tapping it opens the app with the
 * request (`MainActivity.EXTRA_OPEN`). Gone again once the request is answered or closed, or the app is on screen.
 */
class RequestNotifier(private val context: Context, private val model: AppModel) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val shown = mutableSetOf<String>()
    private val seen = mutableSetOf<String>()

    fun start() {
        createChannel(context)
        scope.launch {
            combine(model.questions, model.helpRequests) { q, h -> q to h }.collect { (questions, help) -> update(questions, help) }
        }
    }

    /** The app came to the foreground: the requests are on screen there. */
    fun clear() {
        val manager = NotificationManagerCompat.from(context)
        for (id in shown) manager.cancel(TAG, id.hashCode())
        shown.clear()
    }

    private fun inForeground() = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)

    private fun update(questions: List<AppModel.Question>, help: List<HelpRequest>) {
        val manager = NotificationManagerCompat.from(context)
        val current = questions.map { it.id }.toSet() + help.map { it.id }.toSet()
        for (gone in shown - current) manager.cancel(TAG, gone.hashCode())
        shown.retainAll(current)
        val foreground = inForeground()
        for (q in questions) post(q.id, foreground) { builder(q) }
        for (h in help) post(h.id, foreground) { builder(h) }
        seen.retainAll(current)
    }

    private inline fun post(id: String, foreground: Boolean, make: () -> NotificationCompat.Builder) {
        if (id in seen) return
        seen += id
        if (foreground || !allowed()) return
        val notification = make().build()
        try {
            NotificationManagerCompat.from(context).notify(TAG, id.hashCode(), notification)
            shown += id
        } catch (_: SecurityException) {
        }
    }

    private fun allowed(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun builder(question: AppModel.Question): NotificationCompat.Builder = when (question) {
        is AppModel.Question.SignIn -> {
            val r = question.request
            val agent = r.agent.ifEmpty { context.getString(R.string.your_agent) }
            base(MainActivity.openQuestion(question.id))
                .setContentTitle(context.getString(if (r.field == SignInRequest.Field.CODE) R.string.request_asks_code else R.string.request_asks_sign_in, agent))
                .setContentText(listOf(r.host, r.purpose).filter { it.isNotEmpty() }.joinToString(": "))
        }
        is AppModel.Question.Approval -> {
            val r = question.request
            val agent = r.agent.ifEmpty { context.getString(R.string.your_agent) }
            base(MainActivity.openQuestion(question.id))
                .setContentTitle(context.getString(R.string.request_wants_workspace, agent))
                .setContentText(r.purpose)
        }
    }

    private fun builder(help: HelpRequest): NotificationCompat.Builder {
        val agent = help.agent.ifEmpty { context.getString(R.string.your_agent) }
        return base(MainActivity.openHelp(help.id))
            .setContentTitle(context.getString(R.string.request_asks_help, agent))
            .setContentText(help.purpose)
    }

    private fun base(open: String): NotificationCompat.Builder {
        val intent = Intent(context, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_OPEN, open)
        val pending = PendingIntent.getActivity(context, open.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(context, R.color.brand_indigo))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(pending)
            .setAutoCancel(true)
    }

    companion object {
        const val CHANNEL = "requests"
        private const val TAG = "aos-request"

        fun createChannel(context: Context) {
            val channel = NotificationChannel(CHANNEL, context.getString(R.string.notify_channel), NotificationManager.IMPORTANCE_HIGH)
                .apply { description = context.getString(R.string.notify_channel_description) }
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}

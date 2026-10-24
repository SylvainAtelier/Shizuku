package moe.shizuku.manager.adb

import android.app.AppOpsManager
import android.app.ForegroundServiceStartNotAllowedException
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.annotation.AttrRes
import androidx.annotation.DrawableRes
import androidx.annotation.RequiresApi
import androidx.core.view.isGone
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.R as MaterialR
import com.google.android.material.color.MaterialColors
import moe.shizuku.manager.AppConstants
import moe.shizuku.manager.R
import moe.shizuku.manager.adb.AdbPairingService.FailureReason
import moe.shizuku.manager.adb.AdbPairingService.State
import moe.shizuku.manager.app.AppBarActivity
import moe.shizuku.manager.databinding.AdbPairingTutorialActivityBinding
import moe.shizuku.manager.utils.EnvironmentUtils
import rikka.compatibility.DeviceCompatibility

@RequiresApi(Build.VERSION_CODES.R)
class AdbPairingTutorialActivity : AppBarActivity() {

    companion object {
        private const val PAIRING_CODE_LENGTH = 6
    }

    private lateinit var binding: AdbPairingTutorialActivityBinding

    private var notificationEnabled: Boolean = false

    private var pairingPort = -1

    private var lastState: State? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val context = this

        binding = AdbPairingTutorialActivityBinding.inflate(layoutInflater)
        setContentView(binding.root)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        notificationEnabled = isNotificationEnabled()

        if (notificationEnabled || EnvironmentUtils.canPairInApp(this)) {
            startPairingService()
        }

        binding.apply {
            syncNotificationEnabled()

            if (DeviceCompatibility.isMiui()) {
                miui.isVisible = true
            }

            developerOptions.setOnClickListener {
                val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                intent.putExtra(":settings:fragment_args_key", "toggle_adb_wireless")
                try {
                    context.startActivity(intent)
                } catch (e: ActivityNotFoundException) {
                }
            }

            notificationOptions.setOnClickListener {
                val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                intent.putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                try {
                    context.startActivity(intent)
                } catch (e: ActivityNotFoundException) {
                }
            }

            pairingCodeEdit.doAfterTextChanged {
                pairingCode.error = null
                pairingSubmit.isEnabled = isPairingCodeComplete()
            }
            pairingCodeEdit.setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE && pairingSubmit.isEnabled) {
                    submitPairingCode()
                }
                actionId == EditorInfo.IME_ACTION_DONE
            }
            pairingSubmit.setOnClickListener { submitPairingCode() }
            pairingRetry.setOnClickListener { startPairingService() }
            pairingDone.setOnClickListener { finish() }
        }

        AdbPairingService.state.observe(this) { renderPairingState(it) }
    }

    private fun isPairingCodeComplete(): Boolean {
        return binding.pairingCodeEdit.text?.length == PAIRING_CODE_LENGTH
    }

    private fun submitPairingCode() {
        if (pairingPort <= 0 || !isPairingCodeComplete()) return
        val code = binding.pairingCodeEdit.text.toString()
        startPairingService(AdbPairingService.inputIntent(this, pairingPort, code))
    }

    private fun renderPairingState(state: State) {
        val previous = lastState
        lastState = state

        binding.apply {
            pairing.isVisible = state != State.Idle
            pairingRetry.isVisible = false
            pairingDone.isVisible = false

            when (state) {
                State.Idle -> {
                    pairingPort = -1
                }
                State.Searching -> {
                    pairingPort = -1
                    setPairingHeader(
                        R.drawable.ic_wadb_24, MaterialR.attr.colorSecondaryContainer,
                        MaterialR.attr.colorOnSecondaryContainer,
                        getString(R.string.notification_adb_pairing_searching_for_service_title),
                        getString(R.string.adb_pairing_in_app_searching_summary)
                    )
                    pairingProgress.isVisible = true
                    pairingInput.isVisible = false
                }
                is State.Found -> {
                    pairingPort = state.port
                    setPairingHeader(
                        R.drawable.ic_wadb_24, MaterialR.attr.colorPrimaryContainer,
                        MaterialR.attr.colorOnPrimaryContainer,
                        getString(R.string.notification_adb_pairing_service_found_title),
                        getString(R.string.adb_pairing_in_app_found_summary)
                    )
                    pairingProgress.isVisible = false
                    setPairingInputEnabled(true)
                    if (previous !is State.Found && previous !is State.Failed) {
                        pairingCodeEdit.text?.clear()
                        focusPairingCode()
                    }
                }
                is State.Working -> {
                    pairingPort = state.port
                    setPairingHeader(
                        R.drawable.ic_wadb_24, MaterialR.attr.colorPrimaryContainer,
                        MaterialR.attr.colorOnPrimaryContainer,
                        getString(R.string.notification_adb_pairing_working_title),
                        null
                    )
                    pairingProgress.isVisible = true
                    setPairingInputEnabled(false)
                    hideKeyboard()
                }
                State.Succeeded -> {
                    pairingPort = -1
                    setPairingHeader(
                        R.drawable.ic_server_ok_24dp, MaterialR.attr.colorPrimaryContainer,
                        MaterialR.attr.colorOnPrimaryContainer,
                        getString(R.string.notification_adb_pairing_succeed_title),
                        getString(R.string.notification_adb_pairing_succeed_text)
                    )
                    pairingProgress.isVisible = false
                    pairingInput.isVisible = false
                    pairingDone.isVisible = true
                    hideKeyboard()
                }
                is State.Failed -> {
                    pairingPort = state.port
                    pairingProgress.isVisible = false
                    setPairingInputEnabled(true)
                    if (state.reason == FailureReason.WRONG_CODE) {
                        setPairingHeader(
                            R.drawable.ic_wadb_24, MaterialR.attr.colorPrimaryContainer,
                            MaterialR.attr.colorOnPrimaryContainer,
                            getString(R.string.notification_adb_pairing_service_found_title),
                            getString(R.string.adb_pairing_in_app_found_summary)
                        )
                        pairingCode.error = state.message
                        pairingCodeEdit.selectAll()
                        focusPairingCode()
                    } else {
                        setPairingHeader(
                            R.drawable.ic_server_error_24dp, MaterialR.attr.colorErrorContainer,
                            MaterialR.attr.colorOnErrorContainer,
                            getString(R.string.notification_adb_pairing_failed_title),
                            state.message
                        )
                        pairingRetry.isVisible = true
                    }
                }
            }

            pairingActions.isVisible = pairingRetry.isVisible || pairingDone.isVisible
        }
    }

    private fun setPairingHeader(
        @DrawableRes icon: Int, @AttrRes background: Int, @AttrRes foreground: Int,
        title: CharSequence, summary: CharSequence?
    ) {
        binding.apply {
            pairingIcon.setImageResource(icon)
            pairingIcon.backgroundTintList =
                ColorStateList.valueOf(MaterialColors.getColor(pairingIcon, background))
            pairingIcon.imageTintList =
                ColorStateList.valueOf(MaterialColors.getColor(pairingIcon, foreground))
            pairingTitle.text = title
            pairingSummary.text = summary
            pairingSummary.isVisible = !summary.isNullOrEmpty()
        }
    }

    private fun setPairingInputEnabled(enabled: Boolean) {
        binding.apply {
            pairingInput.isVisible = true
            pairingCode.isEnabled = enabled
            pairingSubmit.isEnabled = enabled && isPairingCodeComplete()
        }
    }

    private fun focusPairingCode() {
        val edit = binding.pairingCodeEdit
        if (edit.requestFocus()) {
            edit.post {
                getSystemService(InputMethodManager::class.java)
                    .showSoftInput(edit, InputMethodManager.SHOW_IMPLICIT)
            }
        }
    }

    private fun hideKeyboard() {
        val edit = binding.pairingCodeEdit
        getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(edit.windowToken, 0)
        edit.clearFocus()
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)

        // In-app input becomes usable once the system pairing dialog can stay visible
        if (isInMultiWindowMode && AdbPairingService.state.value == State.Idle) {
            startPairingService()
        }
    }

    private fun syncNotificationEnabled() {
        binding.apply {
            step1.isVisible = notificationEnabled
            step2.isVisible = notificationEnabled
            step3.isVisible = notificationEnabled
            network.isVisible = notificationEnabled
            notification.isVisible = notificationEnabled
            notificationDisabled.isGone = notificationEnabled
        }
    }

    private fun isNotificationEnabled(): Boolean {
        val context = this

        val nm = context.getSystemService(NotificationManager::class.java)
        val channel = nm.getNotificationChannel(AdbPairingService.notificationChannel)
        return nm.areNotificationsEnabled() &&
                (channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE)
    }

    override fun onResume() {
        super.onResume()

        val newNotificationEnabled = isNotificationEnabled()
        if (newNotificationEnabled != notificationEnabled) {
            notificationEnabled = newNotificationEnabled
            syncNotificationEnabled()

            if (newNotificationEnabled) {
                startPairingService()
            }
        }
    }

    private fun startPairingService(intent: Intent = AdbPairingService.startIntent(this)) {
        try {
            startForegroundService(intent)
        } catch (e: Throwable) {
            Log.e(AppConstants.TAG, "startForegroundService", e)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                && e is ForegroundServiceStartNotAllowedException
            ) {
                val mode = getSystemService(AppOpsManager::class.java)
                    .noteOpNoThrow("android:start_foreground", android.os.Process.myUid(), packageName, null, null)
                if (mode == AppOpsManager.MODE_ERRORED) {
                    Toast.makeText(this, "OP_START_FOREGROUND is denied. What are you doing?", Toast.LENGTH_LONG).show()
                }
                startService(intent)
            }
        }
    }
}

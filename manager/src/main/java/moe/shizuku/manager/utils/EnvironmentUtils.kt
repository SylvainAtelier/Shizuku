package moe.shizuku.manager.utils

import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.SystemProperties
import java.io.File

object EnvironmentUtils {

    @JvmStatic
    fun isWatch(context: Context): Boolean {
        return (context.getSystemService(UiModeManager::class.java).currentModeType
                == Configuration.UI_MODE_TYPE_WATCH)
    }

    fun isMetaQuest(): Boolean {
        return Build.MANUFACTURER.equals("Oculus", true) || Build.MANUFACTURER.equals("Meta", true)
    }

    /**
     * Whether the system pairing dialog can stay visible alongside Shizuku (multi-window,
     * secondary display such as WSA, or Meta Quest panels), so the pairing code can be
     * entered in-app instead of from the notification.
     */
    fun canPairInApp(activity: Activity): Boolean {
        return activity.isInMultiWindowMode
                || (activity.window?.decorView?.display?.displayId ?: -1) > 0
                || isMetaQuest()
    }

    fun isRooted(): Boolean {
        return System.getenv("PATH")?.split(File.pathSeparatorChar)?.find { File("$it/su").exists() } != null
    }

    fun getAdbTcpPort(): Int {
        var port = SystemProperties.getInt("service.adb.tcp.port", -1)
        if (port == -1) port = SystemProperties.getInt("persist.adb.tcp.port", -1)
        return port
    }
}

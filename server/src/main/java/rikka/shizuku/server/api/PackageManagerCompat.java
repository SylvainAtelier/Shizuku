package rikka.shizuku.server.api;

import android.content.pm.IPackageManager;
import android.content.pm.PackageInfo;
import android.content.pm.ParceledListSlice;
import android.os.Build;
import android.os.IBinder;
import android.os.ServiceManager;

import androidx.annotation.NonNull;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.List;

import rikka.shizuku.server.util.Logger;

/**
 * Android 17 (API 37) changed the return type of IPackageManager#getInstalledPackages(long, int)
 * from ParceledListSlice to PackageInfoList (a subclass of ParceledListSlice). The call in
 * hidden-compat 4.4.0 is linked against the old descriptor, so it fails with NoSuchMethodError
 * and getInstalledPackagesNoThrow silently returns an empty list.
 * <p>
 * Looking the method up by name and parameter types ignores the return type, and the result
 * can still be read as a ParceledListSlice on every version.
 */
public class PackageManagerCompat {

    private static final Logger LOGGER = new Logger("PackageManagerCompat");

    private static Method getInstalledPackagesMethod;

    private static Method getInstalledPackagesMethod() throws NoSuchMethodException {
        if (getInstalledPackagesMethod == null) {
            Class<?> flagsType = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ? long.class : int.class;
            getInstalledPackagesMethod = IPackageManager.class.getMethod("getInstalledPackages", flagsType, int.class);
        }
        return getInstalledPackagesMethod;
    }

    @SuppressWarnings("unchecked")
    @NonNull
    public static List<PackageInfo> getInstalledPackagesNoThrow(long flags, int userId) {
        try {
            IBinder binder = ServiceManager.getService("package");
            IPackageManager pm = IPackageManager.Stub.asInterface(binder);
            Object flagsArg = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ? (Object) flags : (Object) (int) flags;
            Object result = getInstalledPackagesMethod().invoke(pm, flagsArg, userId);
            if (result instanceof ParceledListSlice) {
                List<PackageInfo> list = ((ParceledListSlice<PackageInfo>) result).getList();
                if (list != null) {
                    return list;
                }
            }
        } catch (InvocationTargetException e) {
            LOGGER.w(e.getCause(), "getInstalledPackages for user %d", userId);
        } catch (Throwable tr) {
            LOGGER.w(tr, "getInstalledPackages for user %d", userId);
        }
        return Collections.emptyList();
    }
}

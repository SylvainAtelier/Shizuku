<#
.SYNOPSIS
    构建 Shizuku debug APK 并部署到已连接的 adb 设备，回读 versionCode 确认真的装上去了。

.DESCRIPTION
    命令链：
      adb devices → dumpsys package 取现装版本 → gradlew.bat :manager:assembleDebug
      → adb install -r → 再 dumpsys 校验 →（可选）重启 shizuku_server

    versionCode 默认取「设备上现有版本 + 1」。Android 允许用同一个 versionCode 覆盖安装，
    装完无法从设备上分辨新旧，单调递增再回读才能证明跑的是刚构建的那一份。

    注意：Shizuku 的包名 moe.shizuku.privileged.api 被 starter / server / shell 硬编码，
    debug 与 release 不能用 applicationIdSuffix 并存，只能互相覆盖。
    两者签名不同时覆盖会失败（INSTALL_FAILED_UPDATE_INCOMPATIBLE），脚本会提示而不会自动卸载。

.PARAMETER Adb
    adb 可执行文件路径，默认走 PATH。

.PARAMETER Device
    adb -s 的设备序列号。接了多台设备时必填。

.PARAMETER VersionCode
    手动指定 versionCode。不填则用设备现有版本 + 1。

.PARAMETER SkipBuild
    跳过构建，直接安装 manager/build/outputs/apk/debug/ 下最新的 APK。

.PARAMETER Launch
    安装后拉起主界面。

.PARAMETER RestartServer
    安装后用新包里的 libshizuku.so 重启 shizuku_server。不重启的话设备上跑的仍是旧服务端。

.PARAMETER VerifyOnly
    不构建不安装，只校验设备上装的是哪个版本、服务端是否在跑。

.EXAMPLE
    ./scripts/deploy-debug.ps1 -RestartServer
    ./scripts/deploy-debug.ps1 -Device 192.168.1.5:5555 -Launch
    ./scripts/deploy-debug.ps1 -VerifyOnly
#>
param(
    [string]$Adb = "adb",
    [string]$Device = "",
    [int]$VersionCode = 0,
    [switch]$SkipBuild,
    [switch]$Launch,
    [switch]$RestartServer,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-Adb([string[]]$Arguments, [switch]$AllowFailure) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $target = if ($Device) { @('-s', $Device) } else { @() }
        $output = & $Adb @target @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "adb $($Arguments -join ' ') failed: $output"
    }
    return $output
}

function Get-PackageDump {
    return (Invoke-Adb @('shell', 'dumpsys', 'package', $packageName)) -join "`n"
}

function Get-InstalledVersionCode {
    # 未安装时 dumpsys 也返回 0，所以匹配不到就是没装，而不是报错。
    $match = [regex]::Match((Get-PackageDump), 'versionCode=(\d+)')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return 0
}

function Get-StarterPath {
    # 与 Starter.kt 的 userCommand 一致：nativeLibraryDir/libshizuku.so。
    # useLegacyPackaging=true，so 会解压到 legacyNativeLibraryDir/<abi 目录>/。
    $dump = Get-PackageDump
    $libDir = [regex]::Match($dump, 'legacyNativeLibraryDir=(\S+)').Groups[1].Value
    $abi = [regex]::Match($dump, 'primaryCpuAbi=(\S+)').Groups[1].Value
    $abiDir = @{ 'arm64-v8a' = 'arm64'; 'armeabi-v7a' = 'arm'; 'x86_64' = 'x86_64'; 'x86' = 'x86' }[$abi]
    if (-not $libDir -or -not $abiDir) { return $null }
    return "$libDir/$abiDir/libshizuku.so"
}

function Test-ServerRunning {
    $ps = (Invoke-Adb @('shell', 'ps', '-A', '-o', 'NAME') -AllowFailure) -join "`n"
    return $ps -match '(?m)^shizuku_server\s*$'
}

$root = Split-Path -Parent $PSScriptRoot
$packageName = 'moe.shizuku.privileged.api'
$mainActivity = "$packageName/moe.shizuku.manager.MainActivity"

$devices = Invoke-Adb @('devices')
$connected = ($devices | Select-String -SimpleMatch "`tdevice").Count
if ($connected -eq 0) {
    throw 'No authorized Android device is connected. 先跑 adb devices 确认设备已授权。'
}
if ($connected -gt 1 -and -not $Device) {
    Write-Output $devices
    throw 'Multiple devices connected. 用 -Device <serial> 指定一台。'
}

$installedVersion = Get-InstalledVersionCode

if ($VerifyOnly) {
    if ($installedVersion -le 0) {
        throw "$packageName is not installed on the connected device."
    }
    $VersionCode = $installedVersion
} else {
    if ($VersionCode -le $installedVersion) {
        $VersionCode = $installedVersion + 1
    }

    $apkDir = Join-Path $root 'manager/build/outputs/apk/debug'
    if (-not $SkipBuild) {
        $gradle = Join-Path $root 'gradlew.bat'
        & $gradle :manager:assembleDebug --console=plain "-PversionCode=$VersionCode"
        if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed.' }
    }

    # 文件名带 versionName（shizuku-v13.6.0.rN.<commit>-debug.apk），取最新的那个。
    $apk = Get-ChildItem $apkDir -Filter 'shizuku-v*-debug.apk' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) { throw "APK not found under $apkDir" }

    # --no-streaming：部分 OEM（含 ColorOS）的 streaming 安装会在大包上静默失败。
    $result = Invoke-Adb @('install', '--no-streaming', '-r', $apk.FullName) -AllowFailure
    $result | Write-Output
    if (($result -join '') -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Write-Output ''
        Write-Output '设备上的 Shizuku 与本次构建签名不同（通常是 release 包 vs debug keystore）。'
        Write-Output '要么跑 scripts/setup-signing.ps1 生成 .local/signing/keystore.properties 让 debug 也用发布密钥签，要么先卸载（会丢失已授权应用列表）：'
        Write-Output "  $Adb uninstall $packageName"
        throw 'Install failed: signature mismatch.'
    }
}

$updatedVersion = Get-InstalledVersionCode
if ($updatedVersion -ne $VersionCode) {
    throw "Device versionCode is $updatedVersion, expected $VersionCode. 安装没有生效。"
}

$starter = Get-StarterPath

if ($RestartServer -and -not $VerifyOnly) {
    if (-not $starter) { throw '从 dumpsys 解析不出 libshizuku.so 路径。' }
    # starter 会先杀掉已有的 shizuku_server 再拉起新的。
    Invoke-Adb @('shell', $starter) | Write-Output
}

# ── 运行前提：服务端是否在跑 ─────────────────────────────────────
# 重装 APK 不会替换已经在跑的 shizuku_server，表现是「改了服务端代码但行为没变」，
# 很容易被当成代码 bug 排查半天。
$serverOn = Test-ServerRunning

Write-Output ''
Write-Output "包名           $packageName"
Write-Output "versionCode    $VersionCode"
Write-Output "shizuku_server $(if ($serverOn) { '运行中' } else { '未运行' })"

if (-not $serverOn -and $starter) {
    Write-Output ''
    Write-Output '服务端没有在跑。用 adb 启动（或加 -RestartServer）：'
    Write-Output "  $Adb shell $starter"
}

if ($Launch -and -not $VerifyOnly) {
    Invoke-Adb @('shell', 'am', 'start', '-n', $mainActivity) | Write-Output
}

Write-Output ''
if ($VerifyOnly) {
    Write-Output "Verified $packageName versionCode=$VersionCode."
} else {
    Write-Output "Installed $packageName versionCode=$VersionCode."
}

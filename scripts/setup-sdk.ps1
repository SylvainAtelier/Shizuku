<#
.SYNOPSIS
    补齐本机构建 Shizuku 所需的 Android SDK 组件，并写好 local.properties。

.DESCRIPTION
    1. local.properties 没有 sdk.dir 时写入（文件已 gitignore）。
    2. 没有 cmdline-tools 时从 dl.google.com 下载最新版装到 <sdk>/cmdline-tools/latest。
    3. -AcceptLicenses 时接受全部 SDK 许可（等同于手动跑 sdkmanager --licenses 一路按 y）。
    4. 按 build.gradle 里的 ndkVersion / buildToolsVersion / compileSdk 和
       manager/build.gradle 里的 cmake 版本安装缺失的包。

    可重复运行，已装的组件 sdkmanager 会跳过。

.EXAMPLE
    ./scripts/setup-sdk.ps1 -AcceptLicenses
#>
param(
    [string]$Sdk = "",
    [switch]$AcceptLicenses
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$localProps = Join-Path $root 'local.properties'

# ── SDK 位置 ───────────────────────────────────────────────────
if (-not $Sdk -and (Test-Path $localProps)) {
    $line = Get-Content $localProps | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
    if ($line) { $Sdk = ($line -split '=', 2)[1] -replace '\\:', ':' -replace '\\\\', '\' }
}
if (-not $Sdk) { $Sdk = $env:ANDROID_HOME ?? $env:ANDROID_SDK_ROOT ?? (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
if (-not (Test-Path $Sdk)) { throw "Android SDK 不存在：$Sdk。先装 Android Studio 或用 -Sdk 指定。" }
$Sdk = (Resolve-Path $Sdk).Path

if (-not ((Test-Path $localProps) -and (Select-String -Quiet '^sdk\.dir=' $localProps))) {
    # properties 里反斜杠是转义符，写成正斜杠最省事。
    Add-Content -Encoding ascii $localProps "sdk.dir=$($Sdk -replace '\\', '/')"
    Write-Output "已写入 local.properties：sdk.dir=$Sdk"
}

# sdkmanager 需要 JAVA_HOME；没设时借用 Android Studio 自带的 JBR。
if (-not $env:JAVA_HOME) {
    $jbr = 'C:\Program Files\Android\Android Studio\jbr'
    if (Test-Path $jbr) { $env:JAVA_HOME = $jbr }
}

# ── cmdline-tools ──────────────────────────────────────────────
$sdkmanager = Join-Path $Sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path $sdkmanager)) {
    $xml = (Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/android/repository/repository2-3.xml').Content
    $zipName = [regex]::Matches($xml, 'commandlinetools-win-(\d+)_latest\.zip') |
        Sort-Object { [long]$_.Groups[1].Value } | Select-Object -Last 1 | ForEach-Object Value
    if (-not $zipName) { throw '在 repository2-3.xml 里找不到 commandlinetools-win。' }

    $work = Join-Path ([IO.Path]::GetTempPath()) "cmdline-tools-$([guid]::NewGuid())"
    New-Item -ItemType Directory $work | Out-Null
    try {
        $zip = Join-Path $work $zipName
        Write-Output "下载 $zipName"
        Invoke-WebRequest -UseBasicParsing "https://dl.google.com/android/repository/$zipName" -OutFile $zip
        Expand-Archive $zip (Join-Path $work 'x')
        # 压缩包顶层是 cmdline-tools/，sdkmanager 要求它位于 <sdk>/cmdline-tools/latest/。
        New-Item -ItemType Directory -Force (Join-Path $Sdk 'cmdline-tools') | Out-Null
        Move-Item (Join-Path $work 'x\cmdline-tools') (Join-Path $Sdk 'cmdline-tools\latest')
    } finally {
        Remove-Item -Recurse -Force $work
    }
    Write-Output "已安装 $sdkmanager"
}

# ── 许可 ───────────────────────────────────────────────────────
if ($AcceptLicenses) {
    (1..50 | ForEach-Object { 'y' }) -join "`n" | & $sdkmanager --licenses | Select-Object -Last 3
}

# ── 项目要求的组件 ─────────────────────────────────────────────
$rootGradle = Get-Content -Raw (Join-Path $root 'build.gradle')
$managerGradle = Get-Content -Raw (Join-Path $root 'manager\build.gradle')
$ndk = [regex]::Match($rootGradle, 'ndkVersion\s*=\s*"([^"]+)"').Groups[1].Value
$buildTools = [regex]::Match($rootGradle, 'buildToolsVersion\s*=\s*"([^"]+)"').Groups[1].Value
$compileSdk = [regex]::Match($rootGradle, 'compileSdk\s*=\s*(\d+)').Groups[1].Value
$cmakeMin = [regex]::Match($managerGradle, 'version\s*=\s*"(\d+\.\d+)[^"]*"').Groups[1].Value

# cmake 取同一 major.minor 下最新的一个：CMakeLists 写的是 cmake_minimum_required(3.31)，
# 跨到 4.x 会改变策略默认值，不冒这个险。
$cmake = & $sdkmanager --list 2>$null |
    ForEach-Object { if ($_ -match "^\s*cmake;($([regex]::Escape($cmakeMin))\.\d+)\s") { $Matches[1] } } |
    Sort-Object { [version]$_ } -Unique | Select-Object -Last 1
if (-not $cmake) { throw "sdkmanager 里找不到 cmake $cmakeMin.x。" }

$packages = @("ndk;$ndk", "cmake;$cmake", "build-tools;$buildTools", "platforms;android-$compileSdk", 'platform-tools')
Write-Output "安装/确认：$($packages -join ', ')"
& $sdkmanager --install @packages
if ($LASTEXITCODE -ne 0) { throw 'sdkmanager --install 失败。没接受许可的话加 -AcceptLicenses 重跑。' }

Write-Output ''
Write-Output "SDK 就绪：$Sdk"

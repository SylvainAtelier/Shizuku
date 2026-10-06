<#
.SYNOPSIS
    构建 Shizuku debug APK 并部署到 adb 设备。参数与说明见 deploy.ps1。

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

& (Join-Path $PSScriptRoot 'deploy.ps1') -Variant debug @PSBoundParameters

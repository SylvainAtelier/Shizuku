<#
.SYNOPSIS
    一次性配置 Shizuku 发布签名：密钥、本地 keystore.properties、预检、GitHub Secrets。

.DESCRIPTION
    所有签名材料都放在 .local/signing/（已 gitignore）：
      shizuku.jks             发布密钥（PKCS12）。只生成一次，换了密钥用户就无法覆盖升级。
      keystore.properties     signing.gradle 读取，storeFile 相对本目录。
      shizuku.jks.base64      单行 base64，即 ANDROID_KEYSTORE_BASE64 的值。

    可重复运行：已存在的 jks 与 keystore.properties 一律沿用，绝不覆盖。
    -Import 把已有的 jks 迁进来（复制、校验哈希后删除原文件）。
    -PushSecrets 用 gh 写入仓库的四个 Actions Secret，需要先 gh auth login。

.EXAMPLE
    ./scripts/setup-signing.ps1
    ./scripts/setup-signing.ps1 -Import C:\secure\shizuku.jks -Password '口令'
    ./scripts/setup-signing.ps1 -PushSecrets
#>
param(
    [string]$Import = "",
    [string]$Password = "",
    [string]$Alias = "shizuku",
    [string]$DName = "CN=Shizuku, O=SylvainAtelier, C=CN",
    [string]$Repo = "",
    [switch]$PushSecrets
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root '.local/signing'
$jks = Join-Path $dir 'shizuku.jks'
$props = Join-Path $dir 'keystore.properties'
$b64 = Join-Path $dir 'shizuku.jks.base64'
New-Item -ItemType Directory -Force $dir | Out-Null

function Read-Props([string]$Path) {
    $map = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*([^#=\s]+)\s*=(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
    }
    return $map
}

function New-Password {
    # 只用字母数字：properties 文件、shell、gh 都不需要转义。
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# ── 1. 密钥 ─────────────────────────────────────────────────────
if ($Import) {
    if (Test-Path $jks) { throw "$jks 已存在，拒绝用 $Import 覆盖。" }
    Copy-Item $Import $jks
    if ((Get-FileHash $Import).Hash -ne (Get-FileHash $jks).Hash) { throw '复制后哈希不一致。' }
    Remove-Item $Import
    Write-Output "已迁移 $Import → $jks"
}

if (Test-Path $props) {
    $p = Read-Props $props
    if (-not $Password) { $Password = $p['storePassword'] }
    $Alias = $p['keyAlias']
}

if (-not (Test-Path $jks)) {
    if (-not $Password) { $Password = New-Password }
    # 口令走环境变量（-storepass:env），不出现在进程命令行里。
    # PKCS12 下密钥口令恒等于库口令，-keypass 用同一个值。
    $env:SHIZUKU_KS_PW = $Password
    try {
        keytool -genkeypair -keystore $jks -alias $Alias -keyalg RSA -keysize 4096 -validity 10950 `
            -storetype PKCS12 -dname $DName -storepass:env SHIZUKU_KS_PW -keypass:env SHIZUKU_KS_PW
        if ($LASTEXITCODE -ne 0) { throw 'keytool failed.' }
    } finally {
        Remove-Item Env:SHIZUKU_KS_PW
    }
    Write-Output "已生成 $jks"
} elseif (-not $Password) {
    throw "$jks 存在但没有口令：用 -Password 传入，或补上 keystore.properties。"
}

# ── 2. keystore.properties ─────────────────────────────────────
if (-not (Test-Path $props)) {
    @(
        'storeFile=shizuku.jks'
        "storePassword=$Password"
        "keyAlias=$Alias"
        "keyPassword=$Password"
    ) | Set-Content -Encoding ascii $props
    Write-Output "已写入 $props"
}

# ── 3. 预检：与 AGP 相同的 KeyStore.getKey 路径 ─────────────────
$env:KS_PATH = $jks; $env:KS_PASSWORD = $Password; $env:KS_ALIAS = $Alias; $env:KEY_PASSWORD = $Password
try {
    $which = java (Join-Path $root '.github/scripts/SigningProbe.java')
    if ($LASTEXITCODE -ne 0) { throw "SigningProbe 失败（rc=$LASTEXITCODE），见上方输出。" }
} finally {
    Remove-Item Env:KS_PATH, Env:KS_PASSWORD, Env:KS_ALIAS, Env:KEY_PASSWORD
}
Write-Output "签名预检通过（私钥由 $which 口令解开）"

# ── 4. base64 ──────────────────────────────────────────────────
[Convert]::ToBase64String([IO.File]::ReadAllBytes($jks)) | Set-Content -NoNewline -Encoding ascii $b64

$env:SHIZUKU_KS_PW = $Password
try {
    $fingerprint = (keytool -list -v -keystore $jks -alias $Alias -storepass:env SHIZUKU_KS_PW |
        Select-String 'SHA256:' | Select-Object -First 1).ToString().Trim()
} finally {
    Remove-Item Env:SHIZUKU_KS_PW
}
Write-Output "证书 $fingerprint"

# ── 5. GitHub Secrets ──────────────────────────────────────────
if ($PushSecrets) {
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'gh 未登录，先执行 gh auth login。' }
    if (-not $Repo) {
        $url = git -C $root remote get-url origin
        $Repo = [regex]::Match($url, 'github\.com[:/](.+?)(\.git)?$').Groups[1].Value
    }
    # 从 stdin 传值，口令不进命令行。
    Get-Content -Raw $b64 | gh secret set ANDROID_KEYSTORE_BASE64 --repo $Repo
    $Password | gh secret set ANDROID_KEYSTORE_PASSWORD --repo $Repo
    $Password | gh secret set ANDROID_KEY_PASSWORD --repo $Repo
    $Alias | gh secret set ANDROID_KEY_ALIAS --repo $Repo
    gh secret list --repo $Repo
} else {
    Write-Output ''
    Write-Output '未写入 GitHub Secrets。gh auth login 后重跑：./scripts/setup-signing.ps1 -PushSecrets'
}

# manifest-ohos.ps1 - inject permissions / background modes / deviceTypes into
# the project's ohos/entry/src/main/module.json5 (idempotent). Watch edition.
#
# Why scripted: `flutter create --platforms ohos` regenerates a bare template,
# and a fresh checkout must reach a buildable state without manual DevEco
# edits. Mirrors the mobile project's manifest-ohos.ps1, plus:
#   - deviceTypes forced to ["wearable"] (watch HAP must declare wearable
#     to install on watches; the create template ships phone/tablet)
#   - ohos.permission.VIBRATE for the future native haptics channel
#     (xianyu/haptics falls back to Flutter HapticFeedback until then)
param(
    [string]$ProjectRoot = ''
)
if (-not $ProjectRoot) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ProjectRoot = if ($env:XIANYU_OHOS_MIRROR) { $env:XIANYU_OHOS_MIRROR } else { Split-Path -Parent (Split-Path -Parent $ScriptDir) }
}

$ErrorActionPreference = 'Stop'
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$modFile = Join-Path $ProjectRoot 'ohos\entry\src\main\module.json5'
if (-not (Test-Path $modFile)) { throw "module.json5 missing: $modFile (run build-ohos.ps1 once to create ohos/)" }
$mod = [System.IO.File]::ReadAllText($modFile, $Utf8)

# ---- requestPermissions: INTERNET + KEEP_BACKGROUND_RUNNING + VIBRATE ----
if ($mod -notmatch 'ohos\.permission\.INTERNET') {
    if ($mod -match '"requestPermissions"') {
        Write-Warning 'module.json5 has requestPermissions but lacks INTERNET; add manually'
    } elseif ($mod -match '"module"\s*:\s*\{') {
        $mod = [regex]::Replace($mod, '"module"\s*:\s*\{', "`$0`n    `"requestPermissions`": [`n      { `"name`": `"ohos.permission.INTERNET`" },`n      { `"name`": `"ohos.permission.KEEP_BACKGROUND_RUNNING`" },`n      { `"name`": `"ohos.permission.VIBRATE`" }`n    ],", 1)
        Write-Host 'added requestPermissions: INTERNET + KEEP_BACKGROUND_RUNNING + VIBRATE'
    }
} else {
    if ($mod -notmatch 'KEEP_BACKGROUND_RUNNING') {
        $mod = [regex]::Replace($mod, '("ohos\.permission\.INTERNET"\s*\})', "`$1,`n      { `"name`": `"ohos.permission.KEEP_BACKGROUND_RUNNING`" }", 1)
        Write-Host 'added KEEP_BACKGROUND_RUNNING (long-running task, required by audio_service)'
    }
    if ($mod -notmatch 'ohos\.permission\.VIBRATE') {
        $mod = [regex]::Replace($mod, '("ohos\.permission\.KEEP_BACKGROUND_RUNNING"\s*\})', "`$1,`n      { `"name`": `"ohos.permission.VIBRATE`" }", 1)
        Write-Host 'added VIBRATE (xianyu/haptics native channel)'
    }
}

# ---- backgroundModes: audioPlayback (just_audio/audio_service) ----
if ($mod -notmatch 'backgroundModes') {
    $mod2 = [regex]::Replace($mod, '("abilities"\s*:\s*\[\s*\{)', "`$1`n      `"backgroundModes`": [`"audioPlayback`"],", 1)
    if ($mod2 -ne $mod) {
        $mod = $mod2
        Write-Host 'added backgroundModes: [audioPlayback]'
    } else {
        Write-Warning 'abilities anchor not found; add "backgroundModes": ["audioPlayback"] manually'
    }
}

# ---- deviceTypes: force ["wearable"] ----
if ($mod -match '"deviceTypes"\s*:\s*\[[^\]]*\]') {
    $mod = [regex]::Replace($mod, '"deviceTypes"\s*:\s*\[[^\]]*\]', '"deviceTypes": ["wearable"]', 1)
    Write-Host 'deviceTypes set to ["wearable"]'
} else {
    $mod2 = [regex]::Replace($mod, '("module"\s*:\s*\{)', "`$0`n    `"deviceTypes`": [`"wearable`"],", 1)
    if ($mod2 -ne $mod) {
        $mod = $mod2
        Write-Host 'added deviceTypes: ["wearable"]'
    } else {
        Write-Warning 'module anchor not found; add "deviceTypes": ["wearable"] manually'
    }
}

[System.IO.File]::WriteAllText($modFile, $mod, $Utf8)
Write-Host 'manifest patch done.'

#requires -version 5.1
<#
.SYNOPSIS
  HarmonyOS build entry for XianYu-Music-Watch: toolchain -> ohos HAP, all automated.

.DESCRIPTION
  Watch edition of the mobile project's build-ohos.ps1. Builds the HarmonyOS
  HAP IN PLACE (space-free path). Differences vs mobile:
    - no version.ts sync step (single version source = pubspec.yaml)
    - project name xianyu_watch, archive 弦予音乐v<ver>-Watch-<arch>.hap
    - no PoC signing-profile fallback (watch bundle com.xianyumusic.watch.next has
      its own AGC materials, configured later in ohos/build-profile.json5)
    - no signing materials -> canonical profile omits "signingConfig" so
      hvigor produces an UNSIGNED release HAP (compile verification OK;
      real-device install needs signing configured first)

  Usage:
    .\scripts\ohos\build-ohos.ps1                    # build RELEASE HAP (archives to releases\ohos)
    .\scripts\ohos\build-ohos.ps1 -Run               # flutter run (foreground; daily testing)
    .\scripts\ohos\build-ohos.ps1 -Run -d 127.0.0.1:5555
    .\scripts\ohos\build-ohos.ps1 -SkipRust          # reuse existing .so
    .\scripts\ohos\build-ohos.ps1 -Codegen           # force FRB regeneration
    .\scripts\ohos\build-ohos.ps1 -AppPack           # HAP + signed .app for AppGallery (needs signing)
#>
param(
    [switch]$Run,
    [switch]$SkipRust,
    [switch]$Codegen,
    # Also pack the .app (App Pack) for AppGallery upload, after the HAP build
    # succeeds. Requires signing materials - fails on an unsigned project.
    [switch]$AppPack,
    [string]$Device = '',
    # Target CPU ABI for `flutter build hap`. Watch devices are arm64; the
    # x86_64 wearable emulator needs -Abi x64.
    [ValidateSet('', 'x64', 'arm64')]
    [string]$Abi = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$FlutterArgs
)

$ErrorActionPreference = 'Continue' # native tool stderr must not abort; explicit LASTEXITCODE checks below
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path            # scripts\ohos
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)         # main project
$MirrorDir   = if ($env:XIANYU_OHOS_MIRROR) { $env:XIANYU_OHOS_MIRROR } else { $ProjectRoot }
$InPlace     = $MirrorDir -ieq $ProjectRoot
. (Join-Path $ScriptDir 'pub-state.ps1')   # Enter/Exit-XianyuOhosPubState

# ---- signing password auto-encryption (aligned with the mobile project) ----
# hvigor ALWAYS reads storePassword/keyPassword as an ENCRYPTED hex blob
# (DecipherUtil.decryptPwd): an even, >=32-char plain-text password passes the
# length checks but then fails with 00304032 "Signing materials <dir> is an
# empty directory" because it looks for the material key tree. This helper
# re-encodes a PLAIN password to the DevEco encrypted hex using the machine-wide
# material tree at <storeFile parent>\material before the canonical write.
function Invoke-EncryptSignPassword {
    param([string]$StoreFile, [string]$Password)
    if (-not $Password) { return '' }
    # already-encrypted blobs are long & pure hex -> leave untouched
    if ($Password -match '^[0-9a-fA-F]+$' -and $Password.Length -ge 64 -and ($Password.Length % 2) -eq 0) {
        return $Password
    }
    $nodeJs = Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $nodeJs) { throw 'node not found - required to encrypt the signing password' }
    $helper  = Join-Path $ScriptDir 'ohos-sign-password.mjs'
    $materialDir = Split-Path $StoreFile -Parent
    $out = & $nodeJs $helper $materialDir $Password 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $out -notmatch 'encryptedHex:\s*([0-9a-fA-F]+)') {
        throw "signing password encryption failed (storeFile=$StoreFile): $($out.Trim())"
    }
    return $Matches[1].Trim()
}

function Update-SigningPasswords {
    param([string]$SignJson)
    if (-not $SignJson -or $SignJson -eq '[]') { return $SignJson }
    try { $arr = $SignJson | ConvertFrom-Json } catch { return $SignJson }
    foreach ($cfg in $arr) {
        $m = $cfg.material
        if (-not $m -or -not $m.storeFile) { continue }
        foreach ($f in @('storePassword','keyPassword')) {
            if ($m.PSObject.Properties.Name -contains $f) {
                $m.$f = Invoke-EncryptSignPassword -StoreFile $m.storeFile -Password $m.$f
            }
        }
    }
    return (ConvertTo-Json -InputObject $arr.PSObject.BaseObject -Depth 8 -Compress)
}

# ---- 1. session -> Flutter-OH toolchain ----
. (Join-Path $ScriptDir 'env-ohos.ps1')

# ---- 2. FRB codegen (optional) ----
if ($Codegen) {
    Write-Host "[ohos] FRB codegen ..." -ForegroundColor Cyan
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
    $codegenExe = Join-Path $cargoBin 'flutter_rust_bridge_codegen.exe'
    if (-not (Test-Path $codegenExe)) { $codegenExe = 'flutter_rust_bridge_codegen' }
    $unc = [string][char]92 + [char]92 + [char]63 + [char]92
    $rustRoot = $unc + (Join-Path $ProjectRoot 'rust')
    $rustOut  = $unc + (Join-Path $ProjectRoot 'rust\src\frb_generated.rs')
    # libclang for rquickjs-sys bindgen: SDK llvm first, local LLVM fallback
    $llvmCandidates = @(
        (Join-Path $env:DEVECO_SDK_HOME 'native\llvm\bin'),
        'C:\Program Files\LLVM\bin'
    )
    foreach ($l in $llvmCandidates) {
        if (Test-Path (Join-Path $l 'libclang.dll')) { $env:LIBCLANG_PATH = $l; break }
    }
    Push-Location $ProjectRoot
    try {
        & $codegenExe generate --rust-root "$rustRoot" --rust-output "$rustOut"
        if ($LASTEXITCODE -ne 0) { throw "FRB codegen failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}

# ---- 3. ohos dependency state (overrides + lock) -> pub get ----
# 进入 fork 解析态（写 overrides + 从 android 快照恢复 lock），整个构建期持有，
# 结束（含失败）由外层 finally 释放互斥并驻留 ohos 态（见 pub-state.ps1 头注释）。
Enter-XianyuOhosPubState -Root $MirrorDir -ScriptDir $ScriptDir
try {

Push-Location $MirrorDir
try {
    Write-Host '[ohos] pubspec_overrides.yaml synced from template'

    # create/repair the ohos template: trigger on the entry module profile
    # (a bare `ohos/` existence check is not enough - partial trees from an
    # interrupted bootstrap would skip create and leave the template broken)
    if (-not (Test-Path (Join-Path $MirrorDir 'ohos\entry\build-profile.json5'))) {
        Write-Host '[ohos] flutter create --platforms ohos (first run) ...' -ForegroundColor Cyan
        & flutter create --platforms ohos --project-name xianyu_watch .
        if ($LASTEXITCODE -ne 0) { throw "flutter create failed ($LASTEXITCODE)" }
    }

    # bundle name: NO rewrite - ohos/AppScope/app.json5 is the single source
    # of truth (com.xianyumusic.watch.next, set once after the first flutter create;
    # must match the AGC app registration before signing/upload).

    # build-profile.json5 is REWRITTEN canonically every run (signingConfigs
    # preserved) - immune to stale-buffer writebacks. useNormalizedOHMUrl:true
    # matches the mobile project (fork HAR ecosystem expects normalized OHM).
    # compatibleSdkVersion "5.1.0(18)": same as mobile; wearable devices on
    # older HarmonyOS 5.x may need lowering - revisit after first device test.
    $bpJson5 = Join-Path $MirrorDir 'ohos\build-profile.json5'

    # signingConfigs source, in order of preference:
    # 1. main project ohos/build-profile.json5 (DevEco "Automatically generate
    #    signature" run on the watch project - material is machine-wide in
    #    ~\.ohos\config, bound to the AGC-registered watch bundle name).
    # 2. the mirror's existing signingConfigs (legacy mirror mode).
    # 3. none -> UNSIGNED build (canonical profile omits "signingConfig").
    $sign = '[]'
    foreach ($src in @(
        @{ Label = 'MAIN project build-profile'; Path = (Join-Path $ProjectRoot 'ohos\build-profile.json5') },
        @{ Label = 'mirror build-profile';       Path = $bpJson5 }
    )) {
        if ($sign -eq '[]' -and (Test-Path $src.Path)) {
            $content = [System.IO.File]::ReadAllText($src.Path, [System.Text.UTF8Encoding]::new($false))
            if ($content -match '"signingConfigs"\s*:\s*(\[[^\]]*\])') {
                $sign = $Matches[1].Trim()
                Write-Host "[ohos] signingConfigs imported from $($src.Label)"
            }
        }
    }
    # auto-encrypt PLAIN signing passwords -> DevEco encrypted hex (aligned
    # with the mobile project; already-encrypted blobs pass through untouched)
    if ($sign -ne '[]') {
        $sign = Update-SigningPasswords -SignJson $sign
    }
    $hasSigning = $sign -ne '[]' -and $sign -ne ''
    if (Test-Path $bpJson5) {
        $existing = [System.IO.File]::ReadAllText($bpJson5, [System.Text.UTF8Encoding]::new($false))
        $canonical = @'

{
  "app": {
    "signingConfigs": SIGNING,
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        "compatibleSdkVersion": "5.1.0(18)",
        "runtimeOS": "HarmonyOS",
        "buildOption": {
          "strictMode": {
            "useNormalizedOHMUrl": true
          }
        }
      }
    ],
    "buildModeSet": [
      {
        "name": "debug"
      },
      {
        "name": "profile"
      },
      {
        "name": "release"
      }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": [
            "default"
          ]
        }
      ]
    }
  ]
}
'@.Replace('SIGNING', $sign)
        if (-not $hasSigning) {
            # no materials -> drop the product-level signingConfig reference so
            # hvigor produces an unsigned HAP instead of failing on a missing
            # named signing config
            $canonical = $canonical.Replace('        "signingConfig": "default",' + "`r`n", '')
            $canonical = $canonical.Replace('        "signingConfig": "default",' + "`n", '')
        }
        if ($existing.Trim() -ne $canonical.Trim()) {
            [System.IO.File]::WriteAllText($bpJson5, $canonical, [System.Text.UTF8Encoding]::new($false))
            Write-Host "[ohos] build-profile.json5 canonicalized (signingConfigs: $(if ($hasSigning) { 'imported' } else { 'NONE - unsigned build' }))"
        }
    }

    Write-Host '[ohos] flutter pub get ...' -ForegroundColor Cyan
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "pub get failed ($LASTEXITCODE)" }

    # NOTE: no manual `ohpm install` here - outside hvigor it only PRUNES the
    # materialized oh_modules without reinstalling (which would discard the
    # applied embedding patch and force a wasted first attempt every build).
    # oh_modules is materialized by hvigor during `flutter build hap`; if the
    # embedding package is (re)installed unpatched, attempt 1 fails and the
    # retry below patches + rebuilds. Steady state passes attempt 1 directly.
    & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
    & (Join-Path $ScriptDir 'manifest-ohos.ps1') -ProjectRoot $MirrorDir
} finally { Pop-Location }

# ---- 4. rust .so (arm64; artifact -> ohos/entry/libs) ----
if (-not $SkipRust) {
    & (Join-Path $ScriptDir 'build-rust-ohos.ps1')
    if ($LASTEXITCODE -ge 8) { throw "rust build failed" }
}

# ---- 5. build / run ----
# Target ABI: explicit -Abi wins; otherwise probe the connected device's ABI
# list (wearable emulator = x86_64, watches = arm64). Falls back to arm64.
$targetAbi = $Abi
if ($targetAbi -eq '') {
    $hdcExe = Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\toolchains\hdc.exe'
    $abilist = ''
    if (Test-Path $hdcExe) {
        $abilist = (& $hdcExe shell param get const.product.cpu.abilist 2>$null | Out-String)
    }
    if ($abilist -match 'x86_64') { $targetAbi = 'x64' } else { $targetAbi = 'arm64' }
    Write-Host "[ohos] target ABI (auto-detected): $targetAbi" -ForegroundColor Cyan
} else {
    Write-Host "[ohos] target ABI (explicit): $targetAbi" -ForegroundColor Cyan
}

Push-Location $MirrorDir
try {
    if ($Run) {
        $runArgs = @('run')
        if ($Device) { $runArgs += @('-d', $Device) }
        if ($FlutterArgs) { $runArgs += $FlutterArgs }
        Write-Host "[ohos] flutter $($runArgs -join ' ')" -ForegroundColor Cyan
        & flutter @runArgs
        if ($LASTEXITCODE -ne 0) {
            # Same two-stage logic as build-hap below: ohpm re-materialization
            # swaps the embedding package to an unpatched instance, which fails
            # attempt 1. Patch (now-materialized) oh_modules and retry once.
            Write-Host '[ohos] flutter run attempt 1 failed - patch embedding and retry ...' -ForegroundColor Yellow
            & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
            & flutter @runArgs
            if ($LASTEXITCODE -ne 0) { throw "flutter run failed ($LASTEXITCODE)" }
        }
    } else {
        $buildArgs = @('build', 'hap')
        $hasModeFlag = $false
        foreach ($a in $FlutterArgs) { if ($a -in @('--release', '--profile', '--debug')) { $hasModeFlag = $true } }
        if (-not $hasModeFlag) { $buildArgs += '--release' }
        if ($targetAbi -eq 'x64') { $buildArgs += @('--target-platform', 'ohos-x64') }
        elseif ($targetAbi -eq 'arm64') { $buildArgs += @('--target-platform', 'ohos-arm64') }
        if ($FlutterArgs) { $buildArgs += $FlutterArgs }
        Write-Host "[ohos] flutter $($buildArgs -join ' ') ..." -ForegroundColor Cyan
        & flutter @buildArgs
        if ($LASTEXITCODE -ne 0) {
            # First build on a fresh ohos/ fails by design: the embedding HAR
            # and plugin deps are only materialized DURING the build (ohpm
            # install runs inside hvigor, after the FlutterTask writes entry's
            # oh-package.json5), so the pre-build patch had no package to hit.
            # oh_modules is materialized now - patch and retry once.
            Write-Host '[ohos] attempt 1 failed - patch embedding (now materialized) and retry ...' -ForegroundColor Yellow
            & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
            & flutter @buildArgs
            if ($LASTEXITCODE -ne 0) { throw "build hap failed ($LASTEXITCODE)" }
        }
        $haps = Get-ChildItem (Join-Path $MirrorDir 'build') -Recurse -Filter *.hap -ErrorAction SilentlyContinue
        foreach ($h in $haps) { Write-Host ("  HAP: {0}  ({1:N1} MB)" -f $h.FullName, ($h.Length / 1MB)) -ForegroundColor Green }

        # ---- archive to releases\ohos ----
        # Naming: 弦予音乐v<version>-Watch-<arch>.hap, version verbatim from
        # pubspec.yaml (single version source; build number never in filenames,
        # matching the Android/三端 naming convention). Explicit --debug builds
        # are NOT archived.
        # 与 flutter build hap 的默认一致：未显式指定 mode 时是 release
        # （buildArgs 自动补 --release），assembleApp 必须用同一 mode，
        # 否则 debug 模式产物（kernel_blob + 双 ABI 引擎）会混进 .app。
        $buildMode = 'release'
        foreach ($a in $FlutterArgs) {
            if ($a -eq '--release') { $buildMode = 'release' }
            elseif ($a -eq '--profile') { $buildMode = 'profile' }
            elseif ($a -eq '--debug') { $buildMode = 'debug' }
        }
        $appVersion = '0.0.0'
        $pubspecTxt = [System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'pubspec.yaml'))
        if ($pubspecTxt -match '(?m)^version:\s*([0-9][^\s+]*)(\+.*)?$') { $appVersion = $Matches[1] }
        $relDir = Join-Path $ProjectRoot 'releases\ohos'
        $archSuffix = if ($targetAbi -eq 'x64') { 'x86' } else { 'arm64' }
        # hvigor FlutterTask 的目标平台：缺省（不传 TARGET_PLATFORM）会编译全部
        # ohos 目标并在 entry/libs 重新物化 x86_64，.app 体积翻倍（29.8MB vs
        # 18.1MB，2026-09-25 实测）——assembleApp 必须显式传
        $tpHvigor = if ($targetAbi -eq 'x64') { 'ohos-x64' } else { 'ohos-arm64' }
        if ($buildMode -ne 'debug') {
            New-Item -ItemType Directory -Force -Path $relDir | Out-Null
            foreach ($h in $haps) {
                $dst = Join-Path $relDir ("弦予音乐v{0}-Watch-{1}.hap" -f $appVersion, $archSuffix)
                Copy-Item $h.FullName $dst -Force
                Write-Host ("  archived: {0}" -f $dst) -ForegroundColor Green
            }
        }
        if ($AppPack) {
            if (-not $hasSigning) { throw 'AppPack requires signing materials in ohos/build-profile.json5 (DevEco auto-sign once first)' }
            # assembleApp is a project-level hvigor task (no --mode module).
            Push-Location (Join-Path $MirrorDir 'ohos')
            try {
                Write-Host "[ohos] hvigorw assembleApp (buildMode=$buildMode, TARGET_PLATFORM=$tpHvigor) ..." -ForegroundColor Cyan
                & hvigorw assembleApp -p product=default -p buildMode=$buildMode -p TARGET_PLATFORM=$tpHvigor
                if ($LASTEXITCODE -ne 0) {
                    Write-Host '[ohos] assembleApp attempt 1 failed - patch embedding and retry ...' -ForegroundColor Yellow
                    & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
                    & hvigorw assembleApp -p product=default -p buildMode=$buildMode -p TARGET_PLATFORM=$tpHvigor
                    if ($LASTEXITCODE -ne 0) { throw "assembleApp failed ($LASTEXITCODE)" }
                }
                $apps = Get-ChildItem (Join-Path $MirrorDir 'ohos\build\outputs') -Recurse -Filter '*signed.app' -ErrorAction SilentlyContinue
                foreach ($a2 in $apps) {
                    Write-Host ("  APP: {0}  ({1:N1} MB)" -f $a2.FullName, ($a2.Length / 1MB)) -ForegroundColor Green
                    # '*signed.app' 通配符会连 -unsigned.app 一起匹配
                    # （unsigned 以 signed.app 结尾），必须排除，归档只留签名版
                    if ($buildMode -ne 'debug' -and $a2.Name -notmatch 'unsigned') {
                        $dst = Join-Path $relDir ("弦予音乐v{0}-Watch.app" -f $appVersion)
                        Copy-Item $a2.FullName $dst -Force
                        Write-Host ("  archived: {0}" -f $dst) -ForegroundColor Green
                    }
                }
            } finally { Pop-Location }
        }
    }
} finally { Pop-Location }
} finally {
    # 无论成败：仅释放互斥标记，依赖态驻留 ohos（DevEco/hvigor 的 FlutterTask
    # 需要 fork 态 package_config 才能编译）；切回 android 由下一次安卓命令的
    # Restore-XianyuAndroidPubState 自愈（见 pub-state.ps1 头注释）
    Exit-XianyuOhosPubState -Root $MirrorDir -KeepState
}

Write-Host ''
Write-Host '== ohos build done ==' -ForegroundColor Green

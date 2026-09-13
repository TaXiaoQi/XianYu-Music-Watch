$ErrorActionPreference = "Stop"
$realSource = Split-Path -Parent $PSScriptRoot

if ($env:XIANMU_SKIP_RUST -eq "1") { exit 0 }

$bindings   = Join-Path $realSource "lib\src\rust\frb_generated.dart"
$rustSrcDir = Join-Path $realSource "rust\src"
$hookLog    = Join-Path $realSource "build\rust-hook.log"
New-Item (Split-Path $hookLog) -ItemType Directory -Force | Out-Null

$rustFiles = Get-ChildItem $rustSrcDir -Recurse -Filter "*.rs" -File | Where-Object { $_.Name -ne "frb_generated.rs" }
$configFiles = @()
foreach ($f in @("rust\Cargo.toml", "rust\Cargo.lock", "flutter_rust_bridge.yaml")) {
    $p = Join-Path $realSource $f
    if (Test-Path $p) { $configFiles += Get-Item $p }
}
$newestRust = ($rustFiles | Measure-Object LastWriteTime -Maximum).Maximum

# ABI 选择：XIANMU_RUST_ABI=v8 只编 arm64，=v7 只编 armv7（32 位国表），缺省双 ABI 全编。
# 对应出包命令见 README「构建安装包」。
$abiTable = @{
    'arm64-v8a'  = 'aarch64-linux-android'
    'armeabi-v7a' = 'armv7-linux-androideabi'
}
$abiSel = if ($env:XIANMU_RUST_ABI -eq 'v8') { @('arm64-v8a') }
          elseif ($env:XIANMU_RUST_ABI -eq 'v7') { @('armeabi-v7a') }
          else { @('arm64-v8a', 'armeabi-v7a') }
$soPaths = @{}
foreach ($abi in $abiSel) {
    $soPaths[$abi] = Join-Path $realSource "android\app\src\main\jniLibs\$abi\libxianyu_core.so"
}

$needSo = $true
$existing = @($abiSel | Where-Object { Test-Path $soPaths[$_] })
if ($existing.Count -eq $abiSel.Count) {
    # 取所选 ABI 产物中最旧的时间：任一过期即重建（产物缺失也走重建分支）。
    $soTime = ($existing | ForEach-Object { (Get-Item $soPaths[$_]).LastWriteTime } |
        Measure-Object -Minimum).Minimum
    $newestAll = @($newestRust, (($configFiles | Measure-Object LastWriteTime -Maximum).Maximum)) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    if ($newestAll -le $soTime) { $needSo = $false }
}

$needCodegen = $true
if (Test-Path $bindings) {
    if ($newestRust -le (Get-Item $bindings).LastWriteTime) { $needCodegen = $false }
}

if (-not $needSo -and -not $needCodegen) { exit 0 }

Write-Host "[rust-hook] Building Rust..." -ForegroundColor Yellow

$cargoBin = if ($env:CARGO_HOME) {
    Join-Path $env:CARGO_HOME "bin"
} else {
    Join-Path $env:USERPROFILE ".cargo\bin"
}
if (-not (Test-Path $cargoBin)) {
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargoCmd) { $cargoBin = Split-Path $cargoCmd.Source -Parent }
}
$asciiNdk   = "D:\ascii-env\ndk-copy"
$asciiRustc = "D:\ascii-env\rust-tc-real\bin\rustc.exe"
$env:ANDROID_HOME     = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
if (Test-Path $asciiNdk) {
    $env:ANDROID_NDK_HOME = $asciiNdk
    $env:ANDROID_NDK_ROOT = $asciiNdk
} else {
    $ndkRoot = Join-Path $env:ANDROID_HOME "ndk"
    if (Test-Path $ndkRoot) {
        $ndkVer = Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($ndkVer) { $env:ANDROID_NDK_HOME = $ndkVer.FullName; $env:ANDROID_NDK_ROOT = $ndkVer.FullName }
    }
}
if (Test-Path $asciiRustc) { $env:RUSTC = $asciiRustc }
$env:Path = "$cargoBin;" + $env:Path

if ($needCodegen) {
    Write-Host "[rust-hook] Generating Dart bindings..." -ForegroundColor Cyan
    $codegenExe = Join-Path $cargoBin "flutter_rust_bridge_codegen.exe"
    if (-not (Test-Path $codegenExe)) { $codegenExe = "flutter_rust_bridge_codegen" }
    $uncPrefix = [string][char]92 + [char]92 + [char]63 + [char]92
    $rustRoot = $uncPrefix + (Join-Path $realSource 'rust')
    $rustOut = $uncPrefix + (Join-Path $realSource 'rust\src\frb_generated.rs')
    Push-Location $realSource
    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $codegenExe
        $pInfo.Arguments = "generate --rust-root `"$rustRoot`" --rust-output `"$rustOut`""
        $pInfo.WorkingDirectory = $realSource
        $pInfo.UseShellExecute = $false
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.CreateNoWindow = $true
        # rquickjs-sys 0.12+ 的 bindgen 需要 libclang：机器装有 LLVM 时自动注入路径
        # （Gradle daemon 不继承新装软件的 PATH 变更，须显式传入）。
        $llvmBin = "C:\Program Files\LLVM\bin"
        if ((Test-Path (Join-Path $llvmBin "libclang.dll")) -and -not $pInfo.EnvironmentVariables.ContainsKey("LIBCLANG_PATH")) {
            $pInfo.EnvironmentVariables["LIBCLANG_PATH"] = $llvmBin
        }
        # 本机 NDK sysroot 缺 stdbool.h 等编译器头文件：把 LLVM 自带的 clang 内置
        # 头文件目录追加进 bindgen 搜索路径（进程环境变量，子进程继承）。
        if (Test-Path (Join-Path $llvmBin "libclang.dll")) {
            $clangRes = Get-ChildItem "C:\Program Files\LLVM\lib\clang" -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($null -ne $clangRes) {
                $inc = Join-Path $clangRes.FullName "include"
                $extra = "-I`"$inc`""
                if ($env:BINDGEN_EXTRA_CLANG_ARGS) {
                    $env:BINDGEN_EXTRA_CLANG_ARGS = "$($env:BINDGEN_EXTRA_CLANG_ARGS) $extra"
                } else {
                    $env:BINDGEN_EXTRA_CLANG_ARGS = $extra
                }
            }
        }
        $p = [System.Diagnostics.Process]::Start($pInfo)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $stdout = $tOut.Result
        $stderr = $tErr.Result
        Set-Content -Path $hookLog -Value ($stdout + "`n" + $stderr) -Encoding UTF8
        if ($p.ExitCode -ne 0) {
            Get-Content $hookLog -Tail 20 | Write-Host
            throw "[rust-hook] Codegen failed (exit=$($p.ExitCode))"
        }
    } finally { Pop-Location }
}

if ($needSo) {
    Write-Host "[rust-hook] Compiling .so..." -ForegroundColor Cyan
    Push-Location (Join-Path $realSource "rust")
    try {
        $cargoExe = Join-Path $cargoBin "cargo.exe"
        if (-not (Test-Path $cargoExe)) { $cargoExe = "cargo" }
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $cargoExe
        # 按所选 ABI 出产物：-t 全 triple 名（cargo-ndk 原样透传给 cargo，最稳）。
        $targetArgs = ($abiSel | ForEach-Object { "-t"; $abiTable[$_] }) -join ' '
        $pInfo.Arguments = "ndk $targetArgs build --release"
        $pInfo.WorkingDirectory = Join-Path $realSource "rust"
        $pInfo.UseShellExecute = $false
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.CreateNoWindow = $true
        # rquickjs-sys 0.12+ 的 bindgen 需要 libclang：机器装有 LLVM 时自动注入路径
        # （Gradle daemon 不继承新装软件的 PATH 变更，须显式传入）。
        $llvmBin = "C:\Program Files\LLVM\bin"
        if ((Test-Path (Join-Path $llvmBin "libclang.dll")) -and -not $pInfo.EnvironmentVariables.ContainsKey("LIBCLANG_PATH")) {
            $pInfo.EnvironmentVariables["LIBCLANG_PATH"] = $llvmBin
        }
        # 本机 NDK sysroot 缺 stdbool.h 等编译器头文件：把 LLVM 自带的 clang 内置
        # 头文件目录追加进 bindgen 搜索路径（进程环境变量，子进程继承）。
        if (Test-Path (Join-Path $llvmBin "libclang.dll")) {
            $clangRes = Get-ChildItem "C:\Program Files\LLVM\lib\clang" -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($null -ne $clangRes) {
                $inc = Join-Path $clangRes.FullName "include"
                $extra = "-I`"$inc`""
                if ($env:BINDGEN_EXTRA_CLANG_ARGS) {
                    $env:BINDGEN_EXTRA_CLANG_ARGS = "$($env:BINDGEN_EXTRA_CLANG_ARGS) $extra"
                } else {
                    $env:BINDGEN_EXTRA_CLANG_ARGS = $extra
                }
            }
        }
        $p = [System.Diagnostics.Process]::Start($pInfo)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $stdout = $tOut.Result
        $stderr = $tErr.Result
        Set-Content -Path $hookLog -Value ($stdout + "`n" + $stderr) -Encoding UTF8
        if ($p.ExitCode -ne 0) {
            Get-Content $hookLog -Tail 30 | Write-Host
            throw "[rust-hook] cargo ndk build failed (exit=$($p.ExitCode))"
        }
    } finally { Pop-Location }
    foreach ($abi in $abiSel) {
        $src = Join-Path $realSource "rust\target\$($abiTable[$abi])\release\libxianyu_core.so"
        $dst = Join-Path $realSource "android\app\src\main\jniLibs\$abi"
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item $src -Destination $dst -Force
    }
    # 只保留两个标准 ABI 的 libxianyu_core.so，其余过期 .so 清理
    # （未选 ABI 的既有产物保留不动，下次构建该 ABI 时走过期检测）。
    Get-ChildItem (Join-Path $realSource "android\app\src\main\jniLibs") -Recurse -Filter "*.so" |
        Where-Object { $_.Name -ne "libxianyu_core.so" -or
            ($_.Directory.Name -notin @('arm64-v8a', 'armeabi-v7a')) } |
        Remove-Item -Force
}

if ($needCodegen) {
    Write-Host "[rust-hook] Rust API bindings regenerated. Please re-run flutter run." -ForegroundColor Yellow
    exit 3
}

Write-Host "[rust-hook] .so updated successfully" -ForegroundColor Green
exit 0

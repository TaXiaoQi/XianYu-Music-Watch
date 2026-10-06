@echo off
setlocal
title XianYu Music Watch - Cache Clean

echo ============================================
echo   XianYu Music Watch - Cache Clean
echo ============================================
echo.

:: Set PATH (Cargo)
set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"

:: [1/4] Clean Flutter build output (build)
:: build\ohos 里存着鸿蒙/安卓依赖态快照（pubspec.lock.android 等），
:: 删掉会迫使下次安卓构建全量重新解析依赖（pub 直连巨慢），先暂存再还原
set "OHOS_STATE_DIR=%~dp0build\ohos"
set "OHOS_STASH=%TEMP%\xy_watch_ohos_state"
if exist "%OHOS_STATE_DIR%\pubspec.lock.android" (
    echo [1/4] Stashing ohos pub-state snapshots...
    mkdir "%OHOS_STASH%" 2>nul
    copy /y "%OHOS_STATE_DIR%\pubspec.lock.android" "%OHOS_STASH%\" >nul
    copy /y "%OHOS_STATE_DIR%\package_config.android.json" "%OHOS_STASH%\" >nul 2>nul
    copy /y "%OHOS_STATE_DIR%\.pub-state-current" "%OHOS_STASH%\" >nul 2>nul
)
if exist "%~dp0build" (
    echo [1/4] Cleaning Flutter build output...
    rmdir /s /q "%~dp0build"
) else (
    echo [1/4] No build folder, skip
)
if exist "%OHOS_STASH%\pubspec.lock.android" (
    mkdir "%OHOS_STATE_DIR%" 2>nul
    copy /y "%OHOS_STASH%\*" "%OHOS_STATE_DIR%\" >nul
    rmdir /s /q "%OHOS_STASH%"
    echo [1/4] ohos pub-state snapshots restored
)
echo.

:: [2/4] Clean Dart tool cache (.dart_tool)
if exist "%~dp0.dart_tool" (
    echo [2/4] Cleaning Dart tool cache...
    rmdir /s /q "%~dp0.dart_tool"
) else (
    echo [2/4] No .dart_tool cache, skip
)
echo.

:: [3/4] Clean Rust build cache (rust\target)
if exist "%~dp0rust\target" (
    echo [3/4] Cleaning Rust build cache...
    cd /d "%~dp0rust"
    cargo clean
    cd /d "%~dp0"
) else (
    echo [3/4] No rust\target, skip
)
echo.

:: [4/4] Clean Gradle cache (android\.gradle)
if exist "%~dp0android\.gradle" (
    echo [4/4] Cleaning Gradle cache...
    rmdir /s /q "%~dp0android\.gradle"
) else (
    echo [4/4] No android\.gradle cache, skip
)
echo.

echo ============================================
echo   Cache cleaned! Run to rebuild:
echo     Android : "flutter build apk --v7" (32-bit CN watches) or "--v8"
echo     HarmonyOS: "flutter build hap" (use .tools\flutter-ohos-344)
echo   (Rust is compiled automatically via scripts\gradle-rust-hook.ps1)
echo ============================================
echo.
pause

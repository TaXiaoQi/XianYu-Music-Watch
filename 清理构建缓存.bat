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
if exist "%~dp0build" (
    echo [1/4] Cleaning Flutter build output...
    rmdir /s /q "%~dp0build"
) else (
    echo [1/4] No build folder, skip
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
echo   Cache cleaned! Run "flutter run" or "flutter build apk --v7" to rebuild.
echo   (Rust is compiled automatically via scripts\gradle-rust-hook.ps1)
echo ============================================
echo.
pause

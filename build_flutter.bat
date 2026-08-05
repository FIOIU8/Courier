@echo off
:: ============================================================
:: build_flutter.bat - Courier Flutter Build Script
::
:: Usage:
::   build_flutter.bat                  Full pipeline (clean+deps+analyze+test+build)
::   build_flutter.bat --skip-test      Skip tests
::   build_flutter.bat --skip-analyze   Skip static analysis
::   build_flutter.bat --skip-clean     Skip clean step
::   build_flutter.bat --skip-deps      Skip dependency install
::   build_flutter.bat --clean          Force flutter clean then full build
::   build_flutter.bat --release        Build release only (skip test and analyze)
::   build_flutter.bat --help           Show help
:: ============================================================

setlocal enabledelayedexpansion

:: ---- Project paths ----
set "PROJECT_DIR=%~dp0"
set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"
set "DLL_SOURCE=D:\00-Work\03-Code\SoM\Courier\courier_core\courier_core.dll"

:: ---- Locate flutter ----
call flutter --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    set "FLUTTER_BIN="
    for %%P in (
        "D:\Programs\flutter\bin"
        "C:\flutter\bin"
        "C:\src\flutter\bin"
    ) do (
        if exist "%%~P\flutter.bat" set "FLUTTER_BIN=%%~P"
    )
    if defined FLUTTER_BIN (
        set "PATH=!FLUTTER_BIN!;%PATH%"
    ) else (
        echo [ERROR] flutter not found in PATH or common locations
        echo Please install Flutter or add it to PATH
        exit /b 1
    )
)

:: ---- Parse arguments ----
set "SKIP_TEST=0"
set "SKIP_ANALYZE=0"
set "SKIP_CLEAN=0"
set "SKIP_DEPS=0"
set "RELEASE_ONLY=0"
set "FORCE_CLEAN=0"

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--skip-test" set "SKIP_TEST=1"
if /i "%~1"=="--skip-analyze" set "SKIP_ANALYZE=1"
if /i "%~1"=="--skip-clean" set "SKIP_CLEAN=1"
if /i "%~1"=="--skip-deps" set "SKIP_DEPS=1"
if /i "%~1"=="--clean" set "FORCE_CLEAN=1"
if /i "%~1"=="--release" set "RELEASE_ONLY=1"
if /i "%~1"=="--help" goto :show_help
if /i "%~1"=="-h" goto :show_help
shift
goto :parse_args
:args_done

if "%RELEASE_ONLY%"=="1" (
    set "SKIP_TEST=1"
    set "SKIP_ANALYZE=1"
    set "SKIP_CLEAN=0"
    set "SKIP_DEPS=0"
)

echo ========================================
echo    Courier Flutter Build Pipeline
echo ========================================
echo.

cd /d "%PROJECT_DIR%"

:: ============================================================
:: Step 1: Clean
:: ============================================================
if "%SKIP_CLEAN%"=="0" (
    echo [1/5] Cleaning build artifacts...
    if exist "build\windows" rmdir /s /q "build\windows" 2>nul
    if exist "build\unit_test_assets" rmdir /s /q "build\unit_test_assets" 2>nul
    :: Clean stale plugin symlinks that cause PathExistsException
    if exist "windows\flutter\ephemeral\.plugin_symlinks" rmdir /s /q "windows\flutter\ephemeral\.plugin_symlinks" 2>nul
    if exist "windows\flutter\ephemeral\generated_plugins.cmake" del /q "windows\flutter\ephemeral\generated_plugins.cmake" 2>nul
    if "%FORCE_CLEAN%"=="1" (
        echo       Force clean ^(flutter clean^)...
        call flutter clean 2>nul
    )
    echo       [OK] Clean done
) else (
    echo [1/5] Skipping clean
)
echo.

:: ============================================================
:: Step 2: Dependencies
:: ============================================================
if "%SKIP_DEPS%"=="0" (
    echo [2/5] Checking dependencies...
    call flutter pub get
    if !ERRORLEVEL! neq 0 (
        echo       [FAIL] flutter pub get failed
        goto :error_exit
    )
    echo       [OK] Dependencies ready
) else (
    echo [2/5] Skipping dependencies
)
echo.

:: ============================================================
:: Step 3: Static Analysis
:: ============================================================
if "%SKIP_ANALYZE%"=="0" (
    echo [3/5] Running static analysis...
    call flutter analyze lib/
    if !ERRORLEVEL! neq 0 (
        echo       [FAIL] Analysis found issues
        goto :error_exit
    )
    echo       [OK] Analysis passed
) else (
    echo [3/5] Skipping analysis
)
echo.

:: ============================================================
:: Step 4: Unit Tests
:: ============================================================
if "%SKIP_TEST%"=="0" (
    echo [4/5] Running tests...
    call flutter test test/courier_core_service_test.dart
    if !ERRORLEVEL! neq 0 (
        echo       [FAIL] Tests failed
        goto :error_exit
    )
    echo       [OK] All tests passed
) else (
    echo [4/5] Skipping tests
)
echo.

:: ============================================================
:: Step 5: Build Release
:: ============================================================
echo [5/5] Building Windows Release...
call flutter build windows --release
if !ERRORLEVEL! neq 0 (
    echo       [FAIL] Build failed
    goto :error_exit
)
echo       [OK] Build successful
echo.

:: ============================================================
:: Post-build: Copy DLL
:: ============================================================
echo [Post] Copying courier_core.dll...
set "BUILD_OUTPUT=%PROJECT_DIR%\build\windows\x64\runner\Release"
if not exist "%BUILD_OUTPUT%" (
    for /d %%D in ("%PROJECT_DIR%\build\windows\*\runner\Release") do (
        set "BUILD_OUTPUT=%%D"
    )
)

if exist "%DLL_SOURCE%" (
    copy /y "%DLL_SOURCE%" "%BUILD_OUTPUT%\courier_core.dll" >nul 2>&1
    if !ERRORLEVEL! neq 0 (
        echo       [WARN] DLL copy failed, please copy manually
        echo       Source: %DLL_SOURCE%
        echo       Target: %BUILD_OUTPUT%\courier_core.dll
    ) else (
        echo       [OK] DLL copied to output directory
    )
) else (
    echo       [WARN] courier_core.dll not found
    echo       Expected: %DLL_SOURCE%
    echo       Please run Go backend build first: build_core.bat
)
echo.

:: ============================================================
:: Summary
:: ============================================================
echo ========================================
echo    Build Success
echo ========================================
echo.
echo   Output: %BUILD_OUTPUT%
echo   Executable: %BUILD_OUTPUT%\courier_flutter.exe
echo.
goto :eof

:: ============================================================
:: Error exit
:: ============================================================
:error_exit
echo.
echo ========================================
echo    Build Failed
echo ========================================
echo.
exit /b 1

:: ============================================================
:: Help
:: ============================================================
:show_help
echo Usage: build_flutter.bat [options]
echo.
echo Options:
echo   --skip-test       Skip unit tests
echo   --skip-analyze    Skip static analysis
echo   --skip-clean      Skip clean step
echo   --skip-deps       Skip dependency install
echo   --clean           Force flutter clean before build
echo   --release         Build release only (skip test and analyze)
echo   --help, -h        Show this help
echo.
echo Examples:
echo   build_flutter.bat                    Full pipeline
echo   build_flutter.bat --skip-test        Skip tests
echo   build_flutter.bat --clean            Clean then full build
echo   build_flutter.bat --release          Release only
goto :eof

@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "PROJECT_DIR=%~dp0"
set "RUN_CLEAN=0"
set "SKIP_DEPS=0"
set "SKIP_ANALYZE=0"
set "SKIP_TEST=0"

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--clean" (
    set "RUN_CLEAN=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--skip-deps" (
    set "SKIP_DEPS=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--skip-analyze" (
    set "SKIP_ANALYZE=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--skip-test" (
    set "SKIP_TEST=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--release" (
    shift
    goto :parse_args
)
if /i "%~1"=="--help" goto :show_help
if /i "%~1"=="-h" goto :show_help
echo [FAIL] Unsupported option: %~1
exit /b 2

:args_done
where flutter >nul 2>&1
if errorlevel 1 (
    echo [FAIL] Flutter was not found in PATH.
    echo Install a supported Flutter SDK and add its bin directory to PATH.
    exit /b 1
)

if not exist "%PROJECT_DIR%pubspec.yaml" (
    echo [FAIL] pubspec.yaml was not found beside this script.
    exit /b 1
)

pushd "%PROJECT_DIR%" >nul
if errorlevel 1 (
    echo [FAIL] Unable to enter the project directory.
    exit /b 1
)

echo ========================================
echo    Courier Flutter Release Pipeline
echo ========================================
echo.

if "%RUN_CLEAN%"=="1" (
    echo [1/5] Cleaning generated Flutter artifacts...
    call flutter clean
    if errorlevel 1 goto :clean_failed
    echo       [OK] Clean completed
) else (
    echo [1/5] Clean skipped
)
echo.

if "%SKIP_DEPS%"=="0" (
    echo [2/5] Resolving locked dependencies...
    call flutter pub get
    if errorlevel 1 goto :dependencies_failed
    echo       [OK] Dependencies resolved
) else (
    echo [2/5] Dependency resolution skipped
)
echo.

if "%SKIP_ANALYZE%"=="0" (
    echo [3/5] Running static analysis...
    call flutter analyze
    if errorlevel 1 goto :analysis_failed
    echo       [OK] Static analysis passed
) else (
    echo [3/5] Static analysis skipped
)
echo.

if "%SKIP_TEST%"=="0" (
    echo [4/5] Running the complete test suite...
    call flutter test
    if errorlevel 1 goto :tests_failed
    echo       [OK] Tests passed
) else (
    echo [4/5] Tests skipped
)
echo.

echo [5/5] Building Windows Release...
call flutter build windows --release
if errorlevel 1 goto :build_failed

set "BUILD_OUTPUT=%PROJECT_DIR%build\windows\x64\runner\Release"
if not exist "%BUILD_OUTPUT%\courier_flutter.exe" (
    for /d %%D in ("%PROJECT_DIR%build\windows\*\runner\Release") do (
        if exist "%%~fD\courier_flutter.exe" set "BUILD_OUTPUT=%%~fD"
    )
)
if not exist "%BUILD_OUTPUT%\courier_flutter.exe" goto :output_missing

echo       [OK] Windows Release built
echo.
echo ========================================
echo    Build Success
echo ========================================
echo.
echo Output: %BUILD_OUTPUT%
echo Executable: %BUILD_OUTPUT%\courier_flutter.exe
echo.
popd
exit /b 0

:clean_failed
echo       [FAIL] flutter clean failed
goto :pipeline_failed

:dependencies_failed
echo       [FAIL] flutter pub get failed
goto :pipeline_failed

:analysis_failed
echo       [FAIL] flutter analyze failed
goto :pipeline_failed

:tests_failed
echo       [FAIL] flutter test failed
goto :pipeline_failed

:build_failed
echo       [FAIL] flutter build windows --release failed
goto :pipeline_failed

:output_missing
echo       [FAIL] The release executable was not found after the build.
goto :pipeline_failed

:pipeline_failed
echo.
echo ========================================
echo    Build Failed
echo ========================================
echo.
popd
exit /b 1

:show_help
echo Usage: build_flutter.bat [options]
echo.
echo Options:
echo   --clean           Run flutter clean before dependency resolution
echo   --skip-deps       Skip flutter pub get
echo   --skip-analyze    Skip flutter analyze
echo   --skip-test       Skip flutter test
echo   --release         Compatibility alias for the validated release pipeline
echo   --help, -h        Show this help
echo.
echo The default pipeline resolves dependencies, analyzes, tests, and builds.
exit /b 0

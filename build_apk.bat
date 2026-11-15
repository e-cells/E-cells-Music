@echo off
chcp 65001 >nul
echo ============================================
echo   易格音乐 (E-Cells Music) - APK 构建工具
echo ============================================
echo.

setlocal
set JAVA_HOME=E:\jdk17\jdk-17.0.2
set ANDROID_HOME=C:\Users\HULY\AppData\Local\Android\Sdk
set ANDROID_NDK_HOME=C:\Users\HULY\AppData\Local\Android\Sdk\ndk\28.2.13676358
set NDK_HOME=C:\Users\HULY\AppData\Local\Android\Sdk\ndk\28.2.13676358
set JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8
set PATH=%USERPROFILE%\.cargo\bin;%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%PATH%

cd /d "%~dp0"

rem 用法: build_apk.bat [impeller^|skia] [release^|debug] [arm64^|arm32]
rem   第一个参数是渲染引擎，默认 impeller（老机器闪退/冻屏再打 skia 版）
rem   第二个参数是构建类型，默认 release
rem   第三个参数是目标 ABI，默认 arm64（老车机打 arm32）
rem   兼容老用法：build_apk.bat debug 仍表示 impeller + debug
set RENDERER=%1
set BUILD_TYPE=%2
set ABI=%3
if "%RENDERER%"=="" set RENDERER=impeller
if "%RENDERER%"=="release" (
    set BUILD_TYPE=release
    set RENDERER=impeller
)
if "%RENDERER%"=="debug" (
    set BUILD_TYPE=debug
    set RENDERER=impeller
)
if "%BUILD_TYPE%"=="" set BUILD_TYPE=release
if "%ABI%"=="" set ABI=arm64

if not "%RENDERER%"=="impeller" if not "%RENDERER%"=="skia" (
    echo [失败] 渲染引擎只能是 impeller 或 skia，当前: %RENDERER%
    pause
    exit /b 1
)
if not "%ABI%"=="arm64" if not "%ABI%"=="arm32" (
    echo [失败] ABI 只能是 arm64 或 arm32，当前: %ABI%
    pause
    exit /b 1
)

echo [渲染引擎] %RENDERER%
echo [构建类型] %BUILD_TYPE%
echo [目标 ABI] %ABI%
echo.

echo [0/4] 检查是否需要清理...
rem 切渲染器或 ABI 必须 clean：--dart-define=APP_RENDERER / APP_ABI 是
rem 编译期烘焙常量，不清可能复用上个变体的 kernel 缓存，导致关于页标签
rem 和更新选包串味。Gradle 变体产物本身是隔离的，不用担心。
rem 用 build\.last_variant（gitignored）记住上次组合，同组合走增量构建
rem 不浪费时间。
set STAMP=build\.last_variant
set VARIANT=%RENDERER%-%ABI%
set LAST_VARIANT=
if exist "%STAMP%" set /p LAST_VARIANT=<"%STAMP%"
if not "%LAST_VARIANT%"=="%VARIANT%" (
    if "%LAST_VARIANT%"=="" (
        echo 上次构建记录不存在，执行 flutter clean 确保干净构建...
    ) else (
        echo 变体切换（%LAST_VARIANT% --^> %VARIANT%），执行 flutter clean...
    )
    call E:\flutter\flutter\bin\flutter.bat clean
    if %ERRORLEVEL% neq 0 (
        echo [失败] clean 出错
        pause
        exit /b 1
    )
    if not exist build mkdir build
    echo %VARIANT%>"%STAMP%"
) else (
    echo 同一变体（%VARIANT%），跳过 clean，走增量构建。
)

echo.
echo [1/4] 安装依赖...
call E:\flutter\flutter\bin\flutter.bat pub get
if %ERRORLEVEL% neq 0 (
    echo [失败] pub get 出错
    pause
    exit /b 1
)

echo.
echo [2/4] 代码分析...
call E:\flutter\flutter\bin\flutter.bat analyze
if %ERRORLEVEL% neq 0 (
    echo [失败] 分析出错，请检查代码
    pause
    exit /b 1
)

echo.
echo [3/4] 构建 APK...
rem --target-platform 的 32 位值是 android-arm（非 android-arm32）。
set FLUTTER_TARGET=android-arm64
if "%ABI%"=="arm32" set FLUTTER_TARGET=android-arm
call E:\flutter\flutter\bin\flutter.bat build apk --%BUILD_TYPE% --target-platform %FLUTTER_TARGET% --flavor %RENDERER% --dart-define=APP_RENDERER=%RENDERER% --dart-define=APP_ABI=%ABI%
if %ERRORLEVEL% neq 0 (
    echo [失败] 构建出错
    pause
    exit /b 1
)

echo.
echo ============================================
echo   ^[成功^] 构建成功！
echo   APK：build\app\outputs\flutter-apk\app-%RENDERER%-%BUILD_TYPE%.apk
echo ============================================
echo.
echo 用法: build_apk.bat [impeller^|skia] [release^|debug] [arm64^|arm32]
echo   默认: impeller + release + arm64
echo   示例: build_apk.bat（默认）、build_apk.bat skia、
echo         build_apk.bat skia release arm32（老车机 32 位包）
pause

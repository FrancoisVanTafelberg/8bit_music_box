@echo off
rem Cello Helper: build it as a DLL for hot reload. The same source\ package as
rem the music box, compiled with -define:CELLO=true, into its own cello.dll, so
rem both programs can be built and run side by side.
setlocal
cd /d "%~dp0"
if not exist build\hot_reload mkdir build\hot_reload

for /f "delims=" %%i in ('odin root') do set "ODIN_ROOT=%%i"
if "%ODIN_ROOT:~-1%"=="\" set "ODIN_ROOT=%ODIN_ROOT:~0,-1%"
if not exist build\raylib.dll (
    copy "%ODIN_ROOT%\vendor\raylib\windows\raylib.dll" build\ >nul
    if errorlevel 1 (
        echo could not copy raylib.dll from "%ODIN_ROOT%\vendor\raylib\windows\"
        exit /b 1
    )
)

odin build source -build-mode:dll -define:RAYLIB_SHARED=true -define:CELLO=true -out:build\hot_reload\cello.dll -debug
if errorlevel 1 exit /b 1

rem The host: the music box's own, told to load cello.dll.
tasklist /fi "imagename eq cello_helper_dev.exe" | find /i "cello_helper_dev.exe" >nul
if errorlevel 1 (
    odin build main_hot_reload -define:GAME_NAME=cello -out:build\cello_helper_dev.exe -debug
    if errorlevel 1 exit /b 1
)
echo ok - run build\cello_helper_dev.exe  (from this folder)

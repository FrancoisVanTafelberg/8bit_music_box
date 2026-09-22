@echo off
rem Build the app as a DLL. Safe to run while the app is running: the host
rem copies the DLL before loading it, so the compiler can always overwrite this.
setlocal
cd /d "%~dp0"
if not exist build\hot_reload mkdir build\hot_reload

rem raylib ships as a DLL on Windows and must sit next to the executable.
rem `odin root` may or may not come back with a trailing backslash, so strip one
rem if it is there and put exactly one back.
for /f "delims=" %%i in ('odin root') do set "ODIN_ROOT=%%i"
if "%ODIN_ROOT:~-1%"=="\" set "ODIN_ROOT=%ODIN_ROOT:~0,-1%"
if not exist build\raylib.dll (
    copy "%ODIN_ROOT%\vendor\raylib\windows\raylib.dll" build\ >nul
    if errorlevel 1 (
        echo could not copy raylib.dll from "%ODIN_ROOT%\vendor\raylib\windows\"
        exit /b 1
    )
)

rem RAYLIB_SHARED: the DLL must use raylib.dll, not its own static copy.
rem With a static copy every reload brings a fresh, uninitialised raylib -
rem no window, no audio device - and the host keeps drawing into nothing.
odin build source -build-mode:dll -define:RAYLIB_SHARED=true -out:build\hot_reload\game.dll -debug
if errorlevel 1 exit /b 1

rem Only rebuild the host when it is not already running.
tasklist /fi "imagename eq 8bit_music_box_dev.exe" | find /i "8bit_music_box_dev.exe" >nul
if errorlevel 1 (
    odin build main_hot_reload -out:build\8bit_music_box_dev.exe -debug
    if errorlevel 1 exit /b 1
)
echo ok - run build\8bit_music_box_dev.exe  (from this folder, so songs\ is found)

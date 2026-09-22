@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build

rem raylib ships as a DLL on Windows and must sit next to the executable.
for /f "delims=" %%i in ('odin root') do set "ODIN_ROOT=%%i"
if "%ODIN_ROOT:~-1%"=="\" set "ODIN_ROOT=%ODIN_ROOT:~0,-1%"
if not exist build\raylib.dll (
    copy "%ODIN_ROOT%\vendor\raylib\windows\raylib.dll" build\ >nul
    if errorlevel 1 (
        echo could not copy raylib.dll from "%ODIN_ROOT%\vendor\raylib\windows\"
        exit /b 1
    )
)
odin build main_release -out:build\8bit_music_box.exe -o:speed -no-bounds-check -subsystem:windows
if errorlevel 1 exit /b 1
echo ok - build\8bit_music_box.exe

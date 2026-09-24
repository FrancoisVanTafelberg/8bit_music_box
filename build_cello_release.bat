@echo off
rem Cello Helper, release build: build\cello_helper.exe
setlocal
cd /d "%~dp0"
if not exist build mkdir build

for /f "delims=" %%i in ('odin root') do set "ODIN_ROOT=%%i"
if "%ODIN_ROOT:~-1%"=="\" set "ODIN_ROOT=%ODIN_ROOT:~0,-1%"
if not exist build\raylib.dll (
    copy "%ODIN_ROOT%\vendor\raylib\windows\raylib.dll" build\ >nul
    if errorlevel 1 (
        echo could not copy raylib.dll from "%ODIN_ROOT%\vendor\raylib\windows\"
        exit /b 1
    )
)
odin build main_release -define:CELLO=true -out:build\cello_helper.exe -o:speed -no-bounds-check -subsystem:windows
if errorlevel 1 exit /b 1
echo ok - build\cello_helper.exe

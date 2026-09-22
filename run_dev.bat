@echo off
rem Build (if needed) and start the hot-reload app from the project root, so it
rem finds songs\, imports\ and exports\.
cd /d "%~dp0"
call build_hot_reload.bat || exit /b 1
start "" build\8bit_music_box_dev.exe

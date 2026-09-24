@echo off
rem Build (if needed) and start the Cello Helper with hot reload, from the
rem project root so it finds cello_songs\, songs\ and instruments\.
cd /d "%~dp0"
call build_cello_hot_reload.bat || exit /b 1
start "" build\cello_helper_dev.exe

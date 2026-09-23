@echo off
rem Refresh E:\.workspace\8bit_music_box (the git repo that talks to GitHub)
rem from this folder, backing it up first.
rem
rem   copy_to_repo.bat -DryRun      say what would happen, change nothing
rem   copy_to_repo.bat              back up, clear, copy (asks first)
rem   copy_to_repo.bat -Force       ... without the questions
rem   copy_to_repo.bat -Prune 5     ... and keep only the 5 newest backups
rem
rem 8bit_music_box\.git and 8bit_music_box\.gitignore are both preserved: the
rem target is a git repository and the source is not. .temp, build, exports and
rem last_song.txt are not copied across. Nothing is ever written back here.
setlocal
cd /d "%~dp0"
where pwsh >nul 2>&1 && (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "tools\copy_to_repo.ps1" %*
) || (
    powershell -NoProfile -ExecutionPolicy Bypass -File "tools\copy_to_repo.ps1" %*
)

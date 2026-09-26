@echo off
REM Delete every file marked for deletion, and its marker.
REM
REM The convention: a file that should go but could not be removed at the time
REM gets a companion named <file>.delete, whose first lines say why. This walks
REM the tree, and for each marker deletes the file it names and then the marker.
REM
REM It exists because Claude can write files on this machine but not remove
REM them, so a rename lands as "the new file, plus the old one, plus a marker".
REM The same convention as Animal Kingdoms' tools\clean_marked.bat. Run it
REM before copy_to_repo, so marked files do not travel to the repo.
setlocal enabledelayedexpansion
cd /d "%~dp0\.."

set COUNT=0
for /r %%M in (*.delete) do (
    set "MARKER=%%M"
    set "TARGET=%%~dpnM"
    if exist "!TARGET!" (
        echo   deleting !TARGET!
        del /q "!TARGET!"
        set /a COUNT+=1
    ) else (
        echo   already gone: !TARGET!
    )
    del /q "!MARKER!"
)
echo.
echo %COUNT% marked file(s) deleted.
endlocal

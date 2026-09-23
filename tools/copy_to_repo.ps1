<#
.SYNOPSIS
    Back up the 8bit_music_box repo folder, then refresh it from .8bit_music_box.

.DESCRIPTION
    RUN IT THROUGH copy_to_repo.bat IN THE PROJECT ROOT, not by invoking
    this file. Windows refuses unsigned .ps1 files under an AllSigned execution
    policy, and under RemoteSigned it refuses any script carrying the
    mark-of-the-web — both of which report "the file is not digitally signed".
    The .bat passes -ExecutionPolicy Bypass, so neither applies.

    To run this file directly anyway, either:
        powershell -ExecutionPolicy Bypass -File .\copy_to_repo.ps1
    or, if `Get-ExecutionPolicy -List` says RemoteSigned, clear the download
    flag once and it will run normally from then on:
        Unblock-File .\copy_to_repo.ps1

    ---

    Three steps, in this order, and the order is the safety:


      1. Copy the whole of 8bit_music_box\ to 8bit_music_box.bak.YYYY-MM-DD-HH-MM.
         Everything, .git included. If this fails, nothing else runs.
      2. Delete everything in 8bit_music_box\ EXCEPT .git, which is the link to
         GitHub and the reason the folder exists, and .gitignore, which
         belongs to that repository.
      3. Copy .8bit_music_box\ over it, skipping what is generated, local or
         huge - .temp, build, exports, last_song.txt - the not-public-domain
         songs_that_cannot_be_used_for_legal_reasons\, and .gitignore, unless
         the target has none yet, in which case the source's is used to seed it.

    Nothing is written to .8bit_music_box. It is read-only to this script.

.PARAMETER DryRun
    Say what would happen and change nothing. Worth doing the first time.

.PARAMETER Force
    Skip the confirmation prompts. For when you have run it enough times.

.PARAMETER Prune
    After a successful run, keep only this many of the newest backups and
    delete the rest. 0 (the default) keeps all of them.

.PARAMETER Workspace
    The folder holding .8bit_music_box and 8bit_music_box. Defaults to the
    grandparent of this script, which is E:\.workspace in the normal layout.

.EXAMPLE
    .\copy_to_repo.bat -DryRun
.EXAMPLE
    .\copy_to_repo.bat
.EXAMPLE
    .\copy_to_repo.bat -Force -Prune 5
#>

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    [int]    $Prune = 0,
    [string] $Workspace
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Top-level entries of the source that do not travel: the build tree, rendered
# audio, the scratch/reference folder, and the per-machine "last opened song".
#
# .git is on the list for a different and more important reason. The target's
# .git is its link to GitHub and the whole reason the folder exists; step 2
# carefully preserves it. If the source ever grows a .git of its own, step 3
# would copy it straight over the top and quietly replace that link with a
# different repository's. It has no .git today. This is so that the day it gets
# one is not the day this script eats the remote.
#
# .gitignore is on the list for the same shape of reason as .git, one level
# down. The target is a git repository and the source is not, so the file that
# decides what that repository ignores belongs to the TARGET and is maintained
# there. Copying the source's over it would hand control of a repo's ignore
# rules to a folder that has no repo, and the first symptom would be build
# output arriving in a commit.
# songs_that_cannot_be_used_for_legal_reasons holds arrangements of music that is NOT public domain:
# fine to play with here, never to be published, so it never reaches the repo.
$SkipTopLevel = @('.temp', 'build', 'exports', 'last_song.txt', '.git', '.gitignore', 'Claude outputs', 'songs_that_cannot_be_used_for_legal_reasons')

# Kept in the target through step 2, for the reasons above.
$KeepInTarget = @('.git', '.gitignore')

$SourceName = '.8bit_music_box'
$TargetName = '8bit_music_box'

# Files that must exist in the source for it to be the repo and not, say, an
# empty folder of the right name. Cheap insurance against wiping the test
# folder and refilling it with nothing.
$SourceMustHave = @('source', 'songs', 'README.md')


function Say        { param($m) Write-Host $m }
function Step       { param($m) Write-Host ""; Write-Host "  $m" -ForegroundColor Cyan }
function Note       { param($m) Write-Host "    $m" -ForegroundColor DarkGray }
function Warn       { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Die        { param($m) Write-Host ""; Write-Host "  $m" -ForegroundColor Red; Write-Host ""; exit 1 }

function Format-Size {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Measure-Tree {
    param([string] $Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = 0L
    foreach ($f in $files) { $bytes += $f.Length }
    return [pscustomobject]@{ Count = $files.Count; Bytes = $bytes }
}

function Confirm-Or-Exit {
    param([string] $Question)
    if ($Force -or $DryRun) { return }
    Write-Host ""
    $answer = Read-Host "  $Question [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Die 'Nothing was changed.' }
}


# ---------------------------------------------------------------------------
# Work out where everything is, and refuse if anything looks wrong
# ---------------------------------------------------------------------------

if (-not $Workspace) {
    # tools\copy_to_repo.ps1 -> .8bit_music_box -> .workspace
    $Workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$source = Join-Path $Workspace $SourceName
$target = Join-Path $Workspace $TargetName

Say ""
Say "  Refresh $TargetName from $SourceName"
Say "  workspace: $Workspace"

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    Die "No $SourceName folder in $Workspace. Pass -Workspace if it lives somewhere else."
}
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Die "No $TargetName folder in $Workspace. This script refreshes an existing one; it will not create it."
}

foreach ($must in $SourceMustHave) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $must))) {
        Die "$SourceName has no '$must' in it, so it does not look like the repo. Refusing to clear $TargetName from it."
    }
}

# The whole point of the target is its .git. If it is missing, this is not the
# folder we think it is, and clearing it would be a guess.
$targetGit = Join-Path $target '.git'
if (-not (Test-Path -LiteralPath $targetGit)) {
    Die "$TargetName has no .git folder. That is the one thing this script preserves, so its absence means something is wrong. Stopping rather than guessing."
}

$sourceFull = (Resolve-Path -LiteralPath $source).Path
$targetFull = (Resolve-Path -LiteralPath $target).Path
if ($sourceFull -eq $targetFull) { Die 'Source and target are the same folder.' }
if ($targetFull.StartsWith($sourceFull + [IO.Path]::DirectorySeparatorChar)) {
    Die "$TargetName is inside $SourceName. That would not end well."
}


# ---------------------------------------------------------------------------
# Tell the user what is about to happen to their uncommitted work
# ---------------------------------------------------------------------------

$dirty = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    try {
        $dirty = @(git -C $targetFull status --porcelain 2>$null)
    } catch {
        $dirty = $null
    }
}

if ($dirty -and $dirty.Count -gt 0) {
    Say ""
    Write-Host "  $TargetName has $($dirty.Count) uncommitted change(s):" -ForegroundColor Yellow
    foreach ($line in ($dirty | Select-Object -First 8)) { Warn $line }
    if ($dirty.Count -gt 8) { Warn "... and $($dirty.Count - 8) more" }
    Warn 'Step 2 wipes those. They will be in the backup, but not in git.'
    Confirm-Or-Exit 'Carry on anyway?'
}


# ---------------------------------------------------------------------------
# 1. Back up
# ---------------------------------------------------------------------------

$stamp  = Get-Date -Format 'yyyy-MM-dd-HH-mm'
$backup = Join-Path $Workspace "$TargetName.bak.$stamp"

# Two runs in the same minute would otherwise merge into one backup. The
# suffix is zero-padded so -Prune's name sort still puts them in order.
if (Test-Path -LiteralPath $backup) {
    $n = 2
    while (Test-Path -LiteralPath ('{0}-{1:d2}' -f $backup, $n)) { $n++ }
    $backup = '{0}-{1:d2}' -f $backup, $n
}

$before = Measure-Tree $targetFull
Step "1. Back up  ->  $(Split-Path -Leaf $backup)"
Note "$($before.Count) files, $(Format-Size $before.Bytes), .git included"

if ($DryRun) {
    Note '(dry run, not copied)'
} else {
    Copy-Item -LiteralPath $targetFull -Destination $backup -Recurse -Force
    $check = Measure-Tree $backup
    if ($check.Count -lt $before.Count) {
        Die "The backup has $($check.Count) files but $TargetName had $($before.Count). Stopping before anything is deleted; the partial backup is at $backup."
    }
    Note "verified $($check.Count) files"
}


# ---------------------------------------------------------------------------
# 2. Clear, keeping .git
# ---------------------------------------------------------------------------

$doomed = @(Get-ChildItem -LiteralPath $targetFull -Force | Where-Object { $KeepInTarget -notcontains $_.Name })

Step "2. Clear $TargetName, keeping .git and .gitignore"
if ($doomed.Count -eq 0) {
    Note 'already empty'
} else {
    Note "$($doomed.Count) item(s): $(($doomed | Select-Object -First 6 | ForEach-Object { $_.Name }) -join ', ')$(if ($doomed.Count -gt 6) { ', ...' })"
    if ($DryRun) {
        Note '(dry run, not deleted)'
    } else {
        foreach ($item in $doomed) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
        Note 'done'
    }
}


# ---------------------------------------------------------------------------
# 3. Copy the repo across
# ---------------------------------------------------------------------------

$top     = @(Get-ChildItem -LiteralPath $sourceFull -Force)
$copying = @($top | Where-Object { $SkipTopLevel -notcontains $_.Name })
$skipped = @($top | Where-Object { $SkipTopLevel -contains $_.Name })

Step "3. Copy $SourceName  ->  $TargetName"
foreach ($s in $skipped) { Note "skip  $($s.Name)" }

$copied = 0
foreach ($item in $copying) {
    $dest = Join-Path $targetFull $item.Name
    if ($DryRun) {
        $copied++
        continue
    }
    Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
    $copied++
}

# The target's .gitignore is its own; but a brand-new repo with none at all
# gets the source's, so build output does not land in the first commit.
$srcIgnore = Join-Path $sourceFull '.gitignore'
$dstIgnore = Join-Path $targetFull '.gitignore'
if ((Test-Path -LiteralPath $srcIgnore) -and -not (Test-Path -LiteralPath $dstIgnore)) {
    Note "seed  .gitignore (the target had none)"
    if (-not $DryRun) { Copy-Item -LiteralPath $srcIgnore -Destination $dstIgnore -Force }
}

if ($DryRun) {
    Note "(dry run) would copy $copied item(s)"
} else {
    $after = Measure-Tree $targetFull
    Note "copied $copied item(s); $TargetName now holds $($after.Count) files, $(Format-Size $after.Bytes)"
}


# ---------------------------------------------------------------------------
# Optional: thin out old backups
# ---------------------------------------------------------------------------

if ($Prune -gt 0) {
    $all = @(Get-ChildItem -LiteralPath $Workspace -Directory -Force |
             Where-Object { $_.Name -like "$TargetName.bak.*" } |
             Sort-Object Name -Descending)
    $old = @($all | Select-Object -Skip $Prune)

    Step "Prune backups, keeping the newest $Prune"
    if ($old.Count -eq 0) {
        Note "$($all.Count) backup(s), nothing to remove"
    } else {
        foreach ($o in $old) {
            Note "remove  $($o.Name)"
            if (-not $DryRun) { Remove-Item -LiteralPath $o.FullName -Recurse -Force }
        }
    }
}

Say ""
if ($DryRun) {
    Say "  Dry run. Nothing changed. Run it again without -DryRun to do it." 
} else {
    Say "  Done. Backup: $(Split-Path -Leaf $backup)"
    Say "  $TargetName is now a copy of $SourceName, with its own .git untouched."
}
Say ""

<#
.SYNOPSIS
    In-place patcher for the Claude Code VS Code extension (auto-RTL), Windows.
.DESCRIPTION
    Sibling of patch-claude-code-vscode.sh. The extension renders its sidebar UI
    as a plain webview — <ext>\webview\index.js + index.css on disk, no asar, no
    integrity hash, no code-signing, owned by the user. So this patcher just
    appends two shared payloads (src\vscode-rtl-inject.js / .css) between sentinel
    comments. Result: a small floating, draggable AUTO / RTL / LTR panel at the top
    of the webview. AUTO (default) flips each paragraph to RTL/LTR on its own first
    strong character (English and code stay LTR); RTL/LTR force one direction across
    the whole webview while code/editors stay LTR. Mode + panel position persist in
    localStorage. The payloads are shared with the macOS/Linux patcher, so this
    script needs no per-machine editing — it auto-discovers the extension.

    Unlike patch-claude-windows.ps1 this needs NO Administrator rights (the files
    live under %USERPROFILE%). Idempotent: backs up the originals to *.bak on the
    first run and restores from them before every re-patch.
.PARAMETER Action
    Install (default), Restore, EnableAutoUpdate, or DisableAutoUpdate.
.PARAMETER Yes
    Unattended: auto-approve the patch prompt.
.PARAMETER NoAutoUpdate
    Skip registering the auto-re-patch Scheduled Task during Install.
.NOTES
    After any (re)patch, reload the webview: VS Code command palette ->
    "Developer: Reload Window" (or restart VS Code).
#>
[CmdletBinding()]
param(
	[ValidateSet('Install', 'Restore', 'EnableAutoUpdate', 'DisableAutoUpdate')]
	[string]$Action = 'Install',
	[switch]$Yes,
	[switch]$NoAutoUpdate
)

$ErrorActionPreference = 'Stop'

# User-level state (no admin needed): stable bundle + state + watcher live here.
$script:StateDir      = Join-Path $env:LOCALAPPDATA 'ClaudeCodeVscodeRtl'
$script:StateFile     = Join-Path $script:StateDir 'state.json'
$script:StableApp     = Join-Path $script:StateDir 'app'
$script:WatcherPs1    = Join-Path $script:StateDir 'watcher.ps1'
$script:TaskName      = 'ClaudeCodeVscodeRtlAutoPatch'
$script:SentinelBegin = '/* >>> claude-code-rtl (auto) >>> */'
$script:SentinelEnd   = '/* <<< claude-code-rtl (auto) <<< */'

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
function Write-Log($m)   { Write-Host "  [*] $m" -ForegroundColor Cyan }
function Write-Step($m)  { Write-Host "`n> $m" -ForegroundColor Magenta }
function Write-Ok($m)    { Write-Host "  [+] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

function Confirm-Action([string]$Question) {
	if ($Yes) { Write-Log "$Question -> auto-yes (-Yes)"; return $true }
	$ans = Read-Host "$Question [Y/n]"
	return ($ans -eq '' -or $ans -match '^(y|yes)$')
}

# -----------------------------------------------------------------------------
# Locate the Claude Code extension
#
# Search the editors that can host it; pick the most recently modified install
# that actually has a webview (so during an update we patch the NEW folder).
# -----------------------------------------------------------------------------
function Find-ExtDir {
	$roots = @(
		(Join-Path $env:USERPROFILE '.vscode\extensions'),
		(Join-Path $env:USERPROFILE '.vscode-insiders\extensions'),
		(Join-Path $env:USERPROFILE '.cursor\extensions'),
		(Join-Path $env:USERPROFILE '.windsurf\extensions')
	)
	$best = $null
	foreach ($root in $roots) {
		if (-not (Test-Path $root)) { continue }
		Get-ChildItem -Path $root -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
			ForEach-Object {
				$js  = Join-Path $_.FullName 'webview\index.js'
				$css = Join-Path $_.FullName 'webview\index.css'
				if ((Test-Path $js) -and (Test-Path $css)) {
					if ((-not $best) -or ($_.LastWriteTime -gt $best.LastWriteTime)) { $best = $_ }
				}
			}
	}
	if ($best) { return $best.FullName }
	return $null
}

# Resolve the two payload files: repo src\, or a flat bundle next to the script.
function Resolve-SrcDir {
	$scriptDir = Split-Path -Parent $PSCommandPath
	if (Test-Path (Join-Path $scriptDir 'src\vscode-rtl-inject.js')) { return (Join-Path $scriptDir 'src') }
	if (Test-Path (Join-Path $scriptDir 'vscode-rtl-inject.js')) { return $scriptDir }
	return $null
}

function Test-HasInjection([string]$Path) {
	if (-not (Test-Path $Path)) { return $false }
	try { return ([IO.File]::ReadAllText($Path)).Contains($script:SentinelBegin) }
	catch { return $false }
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
function Invoke-Preflight {
	Write-Step 'Checking prerequisites...'
	$extDir = Find-ExtDir
	Write-Host ''
	Write-Host '  Prerequisite check' -ForegroundColor Cyan
	if ($extDir) { Write-Host "  [+] Claude Code extension   $extDir" }
	else { Write-Host '  [X] Claude Code extension   NOT FOUND' }
	Write-Host ''

	if (-not $extDir) {
		throw ('The Claude Code VS Code extension was not found. ' +
			'Install it from the VS Code Marketplace, then re-run.')
	}
	if (-not (Confirm-Action 'Patch the Claude Code webview for auto-RTL now?')) {
		throw 'Aborted by user.'
	}
	return $extDir
}

# -----------------------------------------------------------------------------
# Patch state + stable bundle
# -----------------------------------------------------------------------------
function Save-PatchState([string]$ExtPath) {
	if (-not (Test-Path $script:StateDir)) {
		New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
	}
	@{ patchedExtPath = $ExtPath } | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Save-StableBundle([string]$SrcDir) {
	if (Test-Path $script:StableApp) { Remove-Item $script:StableApp -Recurse -Force }
	New-Item -ItemType Directory -Path $script:StableApp -Force | Out-Null
	Copy-Item $PSCommandPath (Join-Path $script:StableApp 'patch-claude-code-vscode.ps1') -Force
	Copy-Item (Join-Path $SrcDir 'vscode-rtl-inject.js')  (Join-Path $script:StableApp 'vscode-rtl-inject.js')  -Force
	Copy-Item (Join-Path $SrcDir 'vscode-rtl-inject.css') (Join-Path $script:StableApp 'vscode-rtl-inject.css') -Force
}

# -----------------------------------------------------------------------------
# Auto-update watcher (Scheduled Task)
#
# The extension auto-updates into a fresh, pristine, versioned folder — wiping
# the patch. A logon + periodic task re-applies it. Identity = the extension
# folder path; a change (or a missing injection) triggers a re-patch. No admin:
# the task runs as the current interactive user, like the files it edits.
# -----------------------------------------------------------------------------
function Save-WatcherScript {
	if (-not (Test-Path $script:StateDir)) {
		New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
	}
	# Single-quoted here-string: written verbatim, evaluated at run time. Closing
	# '@ MUST be at column 0.
	$body = @'
# Claude Code VS Code RTL — auto-re-patch watcher. Runs from a Scheduled Task at
# logon and every few hours; re-applies the patch when the extension updates into
# a new folder (or if VS Code restored the webview files).
$ErrorActionPreference = 'Continue'
$stateDir  = Join-Path $env:LOCALAPPDATA 'ClaudeCodeVscodeRtl'
$stateFile = Join-Path $stateDir 'state.json'
$patcher   = Join-Path $stateDir 'app\patch-claude-code-vscode.ps1'
$logFile   = Join-Path $stateDir 'watcher.log'
$sentinel  = '/* >>> claude-code-rtl (auto) >>> */'

function WLog($m) {
	try {
		if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
			Move-Item $logFile "$logFile.old" -Force
		}
		"$([DateTime]::Now.ToString('o'))  $m" | Out-File -Append -FilePath $logFile -Encoding UTF8
	} catch {}
}

function FindExt {
	$roots = @(
		(Join-Path $env:USERPROFILE '.vscode\extensions'),
		(Join-Path $env:USERPROFILE '.vscode-insiders\extensions'),
		(Join-Path $env:USERPROFILE '.cursor\extensions'),
		(Join-Path $env:USERPROFILE '.windsurf\extensions')
	)
	$best = $null
	foreach ($root in $roots) {
		if (-not (Test-Path $root)) { continue }
		Get-ChildItem -Path $root -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
			ForEach-Object {
				if (Test-Path (Join-Path $_.FullName 'webview\index.js')) {
					if ((-not $best) -or ($_.LastWriteTime -gt $best.LastWriteTime)) { $best = $_ }
				}
			}
	}
	if ($best) { return $best.FullName }
	return $null
}

$cur = FindExt
if (-not $cur) { WLog 'No extension found; nothing to do.'; return }
$recorded = $null
if (Test-Path $stateFile) {
	try { $recorded = (Get-Content $stateFile -Raw | ConvertFrom-Json).patchedExtPath } catch {}
}
$js = Join-Path $cur 'webview\index.js'
$hasInjection = $false
try { $hasInjection = ([IO.File]::ReadAllText($js)).Contains($sentinel) } catch {}
if (($cur -eq $recorded) -and $hasInjection) { return }

WLog "Re-patching ($recorded -> $cur)"
if (-not (Test-Path $patcher)) { WLog "Patcher missing at $patcher; cannot auto-repatch."; return }
try {
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $patcher -Action Install -Yes -NoAutoUpdate *>&1 |
		ForEach-Object { WLog "  $_" }
	WLog 'Re-patch finished.'
} catch {
	WLog "Re-patch failed: $($_.Exception.Message)"
}
'@
	$utf8Bom = New-Object System.Text.UTF8Encoding $true
	[IO.File]::WriteAllText($script:WatcherPs1, $body, $utf8Bom)
}

function Install-AutoUpdateTask {
	Write-Step 'Enabling auto-re-patch (Scheduled Task)...'
	if (-not (Test-Path $script:StateFile)) {
		Write-Warn2 'No patch state yet — run the patch (Install) first.'
		return
	}
	Save-WatcherScript
	try {
		$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
		$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
			-Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:WatcherPs1`""
		$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
		# Catch a mid-session update without a logon: every 3 hours, effectively
		# forever. [TimeSpan]::MaxValue serializes to a duration Task Scheduler
		# rejects (P99999999...), so use a large but valid finite span.
		$periodic = New-ScheduledTaskTrigger -Once -At ([DateTime]::Today.AddMinutes(5)) `
			-RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Days 3650)
		$triggers = @($atLogon, $periodic)
		$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
			-MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
			-ExecutionTimeLimit ([TimeSpan]::FromMinutes(15))
		# Limited (no admin): the task edits user-owned files and needs nothing more.
		$principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Limited -LogonType Interactive
		Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers `
			-Settings $settings -Principal $principal `
			-Description 'Re-applies the Claude Code VS Code RTL patch after the extension updates.' `
			-Force | Out-Null
		Write-Ok "Auto-re-patch enabled (task '$script:TaskName')."
		Write-Log "Watcher log: $(Join-Path $script:StateDir 'watcher.log')"
		Write-Warn2 'After an auto-re-patch you still need to reload the VS Code window once.'
	} catch {
		Write-Warn2 "Failed to register scheduled task: $($_.Exception.Message)"
	}
}

function Uninstall-AutoUpdateTask {
	Write-Step 'Disabling auto-re-patch...'
	$existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
	if (-not $existing) { Write-Warn2 "Task '$script:TaskName' is not installed."; return }
	try {
		Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
		Write-Ok 'Auto-re-patch disabled.'
	} catch { Write-Warn2 "Failed to remove task: $($_.Exception.Message)" }
}

# =============================================================================
# INSTALL
# =============================================================================
function Install-Patch {
	Write-Host "`n=== Claude Code (VS Code) auto-RTL patch ===`n" -ForegroundColor Cyan
	$extDir = Invoke-Preflight
	$webview = Join-Path $extDir 'webview'
	$css = Join-Path $webview 'index.css'
	$js  = Join-Path $webview 'index.js'
	$srcDir = Resolve-SrcDir
	if (-not $srcDir) { throw 'Payload files (vscode-rtl-inject.*) not found next to this script.' }

	# Safety: an injection already present but no .bak means we'd bake the patch
	# into the backup — refuse rather than lose the pristine original.
	if ((-not (Test-Path "$css.bak")) -and (Test-HasInjection $css)) {
		throw 'index.css already contains an injection but has no .bak. Reinstall the extension, then re-run.'
	}
	if ((-not (Test-Path "$js.bak")) -and (Test-HasInjection $js)) {
		throw 'index.js already contains an injection but has no .bak. Reinstall the extension, then re-run.'
	}

	Write-Step 'Backing up pristine webview files (first run only)...'
	if (-not (Test-Path "$css.bak")) { Copy-Item $css "$css.bak" -Force; Write-Ok 'index.css.bak' }
	if (-not (Test-Path "$js.bak"))  { Copy-Item $js  "$js.bak"  -Force; Write-Ok 'index.js.bak' }

	Write-Step 'Restoring originals before re-injecting (idempotency)...'
	Copy-Item "$css.bak" $css -Force
	Copy-Item "$js.bak"  $js  -Force

	Write-Step 'Injecting auto-RTL payloads...'
	# UTF-8 without BOM: the originals are UTF-8 and the JS payload carries Hebrew
	# glyphs; a BOM mid-file would corrupt both.
	$utf8 = New-Object System.Text.UTF8Encoding $false
	$cssPayload = [IO.File]::ReadAllText((Join-Path $srcDir 'vscode-rtl-inject.css'))
	$jsPayload  = [IO.File]::ReadAllText((Join-Path $srcDir 'vscode-rtl-inject.js'))
	[IO.File]::AppendAllText($css,
		"`n$($script:SentinelBegin)`n$cssPayload`n$($script:SentinelEnd)`n", $utf8)
	Write-Ok 'index.css <- vscode-rtl-inject.css'
	# Lead with a bare ';' so we never glue onto a trailing call expression in the
	# minified bundle; the payload runs under the page's existing CSP nonce.
	[IO.File]::AppendAllText($js,
		"`n;`n$($script:SentinelBegin)`n$jsPayload`n$($script:SentinelEnd)`n", $utf8)
	Write-Ok 'index.js <- vscode-rtl-inject.js'

	Save-PatchState $extDir
	Save-StableBundle $srcDir

	if ($NoAutoUpdate) {
		Write-Log 'Auto-re-patch skipped (-NoAutoUpdate). Re-run after an extension update, or use -Action EnableAutoUpdate.'
	} else {
		Install-AutoUpdateTask
	}

	Write-Host "`n=== PATCH COMPLETE ===" -ForegroundColor Green
	Write-Host '    Reload the webview: VS Code -> "Developer: Reload Window" (or restart VS Code).' -ForegroundColor Yellow
	Write-Host ''
}

# =============================================================================
# RESTORE
# =============================================================================
function Restore-Patch {
	$extDir = Find-ExtDir
	if (-not $extDir) { throw 'Claude Code extension not found.' }
	$css = Join-Path $extDir 'webview\index.css'
	$js  = Join-Path $extDir 'webview\index.js'

	Write-Step 'Restoring original webview files from backup...'
	if (Test-Path "$css.bak") { Copy-Item "$css.bak" $css -Force; Write-Ok 'index.css restored' }
	else { Write-Warn2 'no index.css.bak' }
	if (Test-Path "$js.bak") { Copy-Item "$js.bak" $js -Force; Write-Ok 'index.js restored' }
	else { Write-Warn2 'no index.js.bak' }
	Uninstall-AutoUpdateTask
	Write-Host "`n=== Restore complete (reload the VS Code window) ===`n" -ForegroundColor Green
}

# =============================================================================
switch ($Action) {
	'Install'           { Install-Patch }
	'Restore'           { Restore-Patch }
	'EnableAutoUpdate'  { Install-AutoUpdateTask }
	'DisableAutoUpdate' { Uninstall-AutoUpdateTask }
}

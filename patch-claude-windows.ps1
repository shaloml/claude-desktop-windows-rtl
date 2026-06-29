<#
.SYNOPSIS
    In-place patcher for the official Windows Claude Desktop (MSIX/Store build).
.DESCRIPTION
    Injects this repo's cross-platform extensions (RTL, version label, refresh,
    translate-to-Hebrew, multi-instance) into the installed app's app.asar, then
    keeps Electron's ASAR integrity check happy by byte-replacing the embedded
    SHA-256 header hash inside claude.exe and re-signing the modified binaries
    with a self-signed certificate.

    Technique adapted from shraga100/claude-desktop-rtl-patch (cert/hash dance,
    takeown, fuse-flip fallback). Our difference: we ship a main-process wrapper
    (win-entry.js / win-wrapper.js + the scripts/*-support.js modules) and
    repoint package.json's `main`, rather than injecting RTL into renderer files.

    Re-runnable (idempotent): always restores from *.bak before re-patching.
.PARAMETER Action
    Install (default) or Restore.
.PARAMETER SourceDir
    Directory holding win-entry.js / win-wrapper.js. Defaults to this script's
    folder; the *-support.js modules are resolved from .\src, the same folder, or
    ..\scripts (whichever exists).
.PARAMETER Yes
    Unattended: auto-approve installing missing prerequisites (Node via winget)
    and the patch itself, without prompting.
.NOTES
    Self-elevates via UAC. Runs a prerequisite check first: Claude Desktop (MSIX)
    must be installed; Node.js >= 22.12 is required and offered for automatic
    install via winget if missing.
#>
[CmdletBinding()]
param(
	[ValidateSet('Install', 'Restore', 'EnableAutoUpdate', 'DisableAutoUpdate')]
	[string]$Action = 'Install',
	[string]$SourceDir,
	# Internal: the non-elevated session's PATH, forwarded across the UAC
	# boundary so the elevated run can locate a per-user Node (nvm/winget/scoop).
	# Env vars don't survive RunAs, so this is passed as a parameter.
	[string]$UserPath,
	# Unattended mode: auto-approve installing missing prerequisites (e.g. Node
	# via winget) and the patch itself, without prompting.
	[switch]$Yes,
	# Enable the auto-re-patch watcher (Scheduled Task) without being asked.
	[switch]$EnableAutoUpdate
)

# Make the forwarded user PATH available to Get-NodeCandidateDirs.
if ($UserPath) { $env:CLAUDE_USER_PATH = $UserPath }

$ErrorActionPreference = 'Stop'

# Pinned toolchain (match shraga100; bump by hand after reviewing changelogs).
$script:AsarPackage  = '@electron/asar@4.2.0'
$script:FusesPackage = '@electron/fuses@2.1.1'
$script:MinNodeVersion = '22.12.0'
$global:TmpDir = Join-Path ([IO.Path]::GetTempPath()) 'claude_win_patch_tmp'

# Auto-update (watcher) locations. ProgramData is admin-writable, survives user
# profile changes, and is where the stable bundle + state + watcher script live.
$script:StateDir   = Join-Path $env:ProgramData 'ClaudeWindowsRtl'
$script:StateFile  = Join-Path $script:StateDir 'state.json'
$script:StableApp  = Join-Path $script:StateDir 'app'      # copy of patcher + src
$script:WatcherPs1 = Join-Path $script:StateDir 'watcher.ps1'
$script:TaskName   = 'ClaudeWindowsRtlAutoPatch'

# Files we inject into the asar root. win-entry/win-wrapper come from SourceDir;
# the three support modules come from the repo's scripts/ folder.
$script:EntryMain = 'win-entry.js'

# -----------------------------------------------------------------------------
# Auto-elevation
# -----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
		[Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
	Write-Host 'Requesting Administrator privileges...' -ForegroundColor Yellow
	# Elevation rebuilds PATH from the registry and loses per-user entries (where
	# nvm/winget/scoop Node usually live). Forward THIS (non-elevated) session's
	# PATH to the elevated child as a parameter (env vars don't survive RunAs) so
	# it can still find a user-level Node. See Get-NodeCandidateDirs.
	$argList = @(
		'-NoProfile', '-ExecutionPolicy', 'Bypass',
		'-File', $PSCommandPath, '-Action', $Action,
		'-UserPath', $env:PATH
	)
	if ($SourceDir) { $argList += @('-SourceDir', $SourceDir) }
	if ($Yes) { $argList += '-Yes' }
	Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
	exit
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
function Write-Log($m)     { Write-Host "  [*] $m" -ForegroundColor Cyan }
function Write-Step($m)    { Write-Host "`n> $m" -ForegroundColor Magenta }
function Write-Ok($m)      { Write-Host "  [+] $m" -ForegroundColor Green }
function Write-Warn2($m)   { Write-Host "  [!] $m" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# Byte search (delegates to native String.IndexOf via Latin-1, byte-preserving)
# -----------------------------------------------------------------------------
function Find-Bytes([byte[]]$Haystack, [byte[]]$Needle, [int]$StartIndex = 0) {
	if (-not $Needle -or $Needle.Length -eq 0 -or -not $Haystack -or `
			$Haystack.Length -lt $Needle.Length) { return -1 }
	if ($StartIndex -lt 0) { $StartIndex = 0 }
	if ($StartIndex -gt ($Haystack.Length - $Needle.Length)) { return -1 }
	$enc = [Text.Encoding]::GetEncoding(28591)   # ISO-8859-1
	return $enc.GetString($Haystack).IndexOf(
		$enc.GetString($Needle), $StartIndex, [StringComparison]::Ordinal)
}

# -----------------------------------------------------------------------------
# Locate the installed MSIX Claude
# -----------------------------------------------------------------------------
function Find-ClaudeDir {
	$pkg = Get-AppxPackage | Where-Object {
		$_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*'
	} | Select-Object -First 1
	if ($pkg) { return $pkg.InstallLocation }

	$squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
	if (Test-Path $squirrel) {
		Write-Warn2 "Squirrel install at $squirrel is not handled by this patcher."
	}
	return $null
}

# -----------------------------------------------------------------------------
# Ownership / locking helpers
# -----------------------------------------------------------------------------
function Take-Ownership($Path) {
	Write-Log "Taking ownership of $Path"
	cmd.exe /c "takeown /F `"$Path`" /R /D Y >nul 2>&1"
	cmd.exe /c "icacls `"$Path`" /grant `"*S-1-5-32-544:(OI)(CI)F`" /T /Q >nul 2>&1"
}

function Test-FileLock([string]$Path) {
	if (-not (Test-Path $Path)) { return $false }
	try {
		$fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None'); $fs.Close()
		return $false
	} catch { return $true }
}

function Wait-FileUnlock([string]$Path, [int]$TimeoutSeconds = 20) {
	if (-not (Test-Path $Path)) { return }
	for ($w = 0; $w -lt $TimeoutSeconds; $w++) {
		if (-not (Test-FileLock $Path)) { return }
		Start-Sleep -Seconds 1
	}
	throw "File '$(Split-Path $Path -Leaf)' still locked after ${TimeoutSeconds}s. Reboot and retry."
}

# -----------------------------------------------------------------------------
# Structural validation
# -----------------------------------------------------------------------------
function Compute-AsarHash($AsarPath) {
	$fs = [IO.File]::OpenRead($AsarPath)
	$br = New-Object IO.BinaryReader($fs)
	$fs.Seek(12, 'Begin') | Out-Null
	$jsonSize = $br.ReadUInt32()
	if ($jsonSize -le 0 -or $jsonSize -gt 10485760) {
		$fs.Close(); throw "Abnormal ASAR header size: $jsonSize"
	}
	$jsonBytes = $br.ReadBytes($jsonSize)
	$fs.Close()
	$jsonStr = [Text.Encoding]::UTF8.GetString($jsonBytes)
	$sha = [Security.Cryptography.SHA256]::Create()
	$hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($jsonStr))
	return [BitConverter]::ToString($hash).Replace('-', '').ToLower()
}

function Test-FileValid([string]$Path, [string]$Type) {
	if (-not (Test-Path $Path)) { return $false }
	try {
		$size = (Get-Item -LiteralPath $Path).Length
		if ($size -lt 16) { return $false }
		switch ($Type) {
			'asar' { $null = Compute-AsarHash $Path; return $true }
			'pe' {
				if ($size -lt 1048576) { return $false }
				$fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
				try {
					return ($fs.ReadByte() -eq 0x4D -and $fs.ReadByte() -eq 0x5A)
				} finally { $fs.Close() }
			}
			default { return ($size -gt 0) }
		}
	} catch { return $false }
}

function Copy-FileSafe([string]$Source, [string]$Dest, [string]$ValidateAs) {
	if (-not (Test-Path -LiteralPath $Source)) { throw "Copy-FileSafe: '$Source' missing." }
	if ($ValidateAs -and -not (Test-FileValid -Path $Source -Type $ValidateAs)) {
		throw "Source '$(Split-Path $Source -Leaf)' failed $ValidateAs check; refusing to back up a corrupt file."
	}
	$tmp = "$Dest.tmp"
	if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
	try {
		Copy-Item -LiteralPath $Source -Destination $tmp -Force -ErrorAction Stop
	} catch {
		[IO.File]::WriteAllBytes($tmp, [IO.File]::ReadAllBytes($Source))
	}
	if ((Get-Item -LiteralPath $Source).Length -ne (Get-Item -LiteralPath $tmp).Length) {
		Remove-Item -LiteralPath $tmp -Force
		throw "Copy-FileSafe: size mismatch for $(Split-Path $Dest -Leaf)."
	}
	if ($ValidateAs -and -not (Test-FileValid -Path $tmp -Type $ValidateAs)) {
		Remove-Item -LiteralPath $tmp -Force
		throw "Copy-FileSafe: copy of $(Split-Path $Dest -Leaf) failed $ValidateAs check."
	}
	Move-Item -LiteralPath $tmp -Destination $Dest -Force
}

# -----------------------------------------------------------------------------
# Process / service control
# -----------------------------------------------------------------------------
function Stop-ClaudeServices {
	param([string]$InstallDir)
	Write-Step 'Stopping Claude Desktop and the cowork service...'
	$svc = Get-WmiObject Win32_Service | Where-Object { $_.PathName -match 'cowork-svc' }
	if ($svc) {
		Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
		for ($w = 0; $w -lt 10; $w++) {
			if ((Get-Service -Name $svc.Name -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
			Start-Sleep -Seconds 1
		}
	}
	# CRITICAL: Claude Code (the CLI) also runs an executable named "claude.exe".
	# Killing every "claude" process would terminate the very session driving
	# this patch. Match ONLY processes whose image path lives under the Claude
	# Desktop install dir (or the cowork service binary). Never kill by name alone.
	$installRoot = if ($InstallDir) { $InstallDir } else { (Find-ClaudeDir) }
	Get-Process -Name 'claude', 'cowork-svc' -ErrorAction SilentlyContinue |
		Where-Object {
			$p = $null
			try { $p = $_.Path } catch { $p = $null }
			$p -and $installRoot -and $p.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)
		} |
		Stop-Process -Force -ErrorAction SilentlyContinue
	Start-Sleep -Seconds 2
	Write-Ok 'Claude Desktop processes halted (Claude Code CLI left untouched).'
}

function Start-ClaudeApp {
	$pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' } | Select-Object -First 1
	if ($pkg) {
		try {
			Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!Claude"
			Write-Ok 'Claude Desktop launched.'
		} catch { Write-Warn2 "Could not auto-launch; start Claude from the Start Menu." }
	}
}

# -----------------------------------------------------------------------------
# Electron fuse fallback (used only if the hash isn't found in claude.exe)
# -----------------------------------------------------------------------------
function Invoke-FuseFlip([string]$ExePath) {
	$prev = $env:NODE_NO_WARNINGS; $env:NODE_NO_WARNINGS = '1'
	try {
		$read = cmd.exe /c "npx --yes $($script:FusesPackage) read --app `"$ExePath`" 2>&1" | Out-String
		if ($read -match 'EnableEmbeddedAsarIntegrityValidation[^\r\n]*Disabled') {
			Write-Ok 'ASAR integrity fuse already off.'
			return $true
		}
		cmd.exe /c "npx --yes $($script:FusesPackage) write --app `"$ExePath`" EnableEmbeddedAsarIntegrityValidation=off 2>&1" | Out-Null
		$after = cmd.exe /c "npx --yes $($script:FusesPackage) read --app `"$ExePath`" 2>&1" | Out-String
		return [bool]($after -match 'EnableEmbeddedAsarIntegrityValidation[^\r\n]*Disabled')
	} catch {
		Write-Warn2 "Fuse flip failed: $($_.Exception.Message)"; return $false
	} finally { $env:NODE_NO_WARNINGS = $prev }
}

# -----------------------------------------------------------------------------
# Resolve our injectable source files
# -----------------------------------------------------------------------------
function Resolve-SourceFiles {
	# Supported layouts (each JS file is searched across all candidate dirs):
	#   1. Standalone repo: all five JS files in .\src\ next to this script.
	#   2. Bundle: all five JS files flat next to this script (the ZIP produced
	#      by package-windows.ps1, or this script's own folder).
	#   3. Source repo: this script in windows\, win-* beside it, the shared
	#      support modules in ..\scripts\.
	$src = if ($SourceDir) { $SourceDir } else { $PSScriptRoot }
	$candidates = @(
		(Join-Path $src 'src'),                          # standalone repo
		$src,                                            # flat bundle / beside
		(Join-Path (Split-Path -Parent $src) 'scripts')  # source repo scripts\
	)

	$names = @(
		'win-entry.js', 'win-wrapper.js',
		'rtl-support.js', 'translate-support.js', 'multi-instance-support.js'
	)

	$files = [ordered]@{}
	foreach ($name in $names) {
		$found = $null
		foreach ($dir in $candidates) {
			$p = Join-Path $dir $name
			if (Test-Path $p) { $found = $p; break }
		}
		if (-not $found) {
			throw "Required source file not found: $name (searched: $($candidates -join '; '))."
		}
		$files[$name] = $found
	}
	return $files
}

# -----------------------------------------------------------------------------
# Ensure Node/npx can run @electron/asar
#
# Self-elevation rebuilds PATH from the registry, which DROPS user-level PATH
# entries — so a Node installed per-user (nvm4w / winget / scoop / the official
# user installer) is invisible to the elevated process even though it works in a
# normal shell. We therefore probe a broad set of candidate dirs, prepend the
# first that can actually run the asar tool, and only then give up.
# -----------------------------------------------------------------------------
function Test-NpxRunsAsar {
	$out = cmd.exe /c "npx --yes $($script:AsarPackage) --version 2>&1"
	return @{ Ok = ($LASTEXITCODE -eq 0); Output = ($out | Out-String).Trim() }
}

function Get-NodeCandidateDirs {
	$dirs = New-Object System.Collections.Generic.List[string]
	$add = { param($p) if ($p -and (Test-Path (Join-Path $p 'node.exe'))) { $dirs.Add($p) } }

	# Standard machine + user install locations.
	& $add (Join-Path $env:ProgramFiles 'nodejs')
	& $add (Join-Path ${env:ProgramFiles(x86)} 'nodejs')
	& $add (Join-Path $env:LOCALAPPDATA 'nodejs')

	# nvm-windows: NVM_SYMLINK points at the active version; also scan its store.
	& $add $env:NVM_SYMLINK
	foreach ($base in @($env:NVM_HOME, 'C:\nvm4w\nodejs', (Join-Path $env:APPDATA 'nvm'))) {
		if ($base -and (Test-Path $base)) {
			& $add $base
			Get-ChildItem $base -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
				ForEach-Object { & $add $_.FullName }
		}
	}

	# scoop (current user) and a couple of winget link dirs.
	& $add (Join-Path $env:USERPROFILE 'scoop\apps\nodejs\current')
	& $add (Join-Path $env:USERPROFILE 'scoop\apps\nodejs-lts\current')

	# The invoking (non-elevated) user's own PATH, passed in via env if available,
	# plus the elevated PATH — split and keep any dir that has node.exe.
	foreach ($pathVar in @($env:CLAUDE_USER_PATH, $env:PATH)) {
		if ($pathVar) { $pathVar.Split(';') | ForEach-Object { & $add $_.Trim() } }
	}

	return ($dirs | Select-Object -Unique)
}

function Assert-NodeToolchain {
	$probe = Test-NpxRunsAsar
	if ($probe.Ok) { return }

	foreach ($dir in (Get-NodeCandidateDirs)) {
		Write-Log "Trying Node at $dir"
		$env:PATH = "$dir;$env:PATH"
		$probe = Test-NpxRunsAsar
		if ($probe.Ok) { Write-Ok "Using Node from $dir"; return }
	}

	# Still failing — surface the real npx error and the detected Node version so
	# the cause (missing Node vs. too-old Node vs. broken npx) is obvious.
	$nodeVer = (cmd.exe /c "node --version 2>&1" | Out-String).Trim()
	Write-Warn2 "npx could not run $($script:AsarPackage)."
	if ($nodeVer) { Write-Warn2 "Detected node: $nodeVer" }
	if ($probe.Output) { Write-Warn2 "npx said: $($probe.Output)" }
	throw ("Node.js >= $($script:MinNodeVersion) with npx is required, and none of the " +
		"detected Node locations could run $($script:AsarPackage). " +
		"Install Node from https://nodejs.org (LTS), reboot, and re-run. " +
		"If Node is installed per-user (nvm/winget/scoop), run this patcher from an " +
		"elevated PowerShell that already has 'node --version' working.")
}

# -----------------------------------------------------------------------------
# Preflight: check prerequisites, report what's present/missing, and offer to
# install what's missing (with consent) before any changes are made.
# -----------------------------------------------------------------------------

# Return the runnable Node major.minor.patch as [version], searching candidate
# dirs (and prepending the first that works) so the rest of the run can use it.
function Resolve-NodeVersion {
	# Fast path: node already on PATH.
	$raw = (cmd.exe /c 'node --version 2>nul' | Out-String).Trim()
	if ($raw -match 'v?(\d+)\.(\d+)\.(\d+)') {
		return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
	}
	# Slow path: try known install dirs, prepend the first with a working node.
	foreach ($dir in (Get-NodeCandidateDirs)) {
		$raw = (cmd.exe /c "`"$dir\node.exe`" --version 2>nul" | Out-String).Trim()
		if ($raw -match 'v?(\d+)\.(\d+)\.(\d+)') {
			$env:PATH = "$dir;$env:PATH"
			return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
		}
	}
	return $null
}

function Find-Winget {
	$cmd = Get-Command winget -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	# winget (App Installer) lives under WindowsApps; resolve its real path since
	# the elevated PATH may not include the per-user alias.
	$wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
	if (Test-Path $wa) { return $wa }
	$pkg = Get-ChildItem (Join-Path $env:ProgramFiles 'WindowsApps') `
		-Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if ($pkg) { return $pkg.FullName }
	return $null
}

function Install-NodeViaWinget {
	$winget = Find-Winget
	if (-not $winget) {
		Write-Warn2 'winget (App Installer) is not available on this machine.'
		return $false
	}
	Write-Step 'Installing Node.js LTS via winget...'
	& $winget install --id OpenJS.NodeJS.LTS --silent `
		--accept-package-agreements --accept-source-agreements 2>&1 |
		ForEach-Object { Write-Host "  $_" }
	# winget updates the machine PATH but not this process; pull the new node in.
	$ver = Resolve-NodeVersion
	if ($ver) { Write-Ok "Node $ver installed."; return $true }
	Write-Warn2 'Node install reported done but node is still not runnable in this session.'
	return $false
}

function Confirm-Action([string]$Question) {
	if ($Yes) { Write-Log "$Question -> auto-yes (-Yes)"; return $true }
	$ans = Read-Host "$Question [Y/n]"
	return ($ans -eq '' -or $ans -match '^(y|yes)$')
}

# Returns $ClaudeDir if all prerequisites are satisfied (after any approved
# installs); throws with a clear message otherwise. Prints a status summary.
function Invoke-Preflight {
	Write-Step 'Checking prerequisites...'
	$min = [version]$script:MinNodeVersion

	# 1) Claude Desktop (MSIX).
	$claudeDir = Find-ClaudeDir
	$claudeOk = [bool]$claudeDir -and (Test-Path (Join-Path $claudeDir 'app\resources\app.asar'))

	# 2) Node.js >= min, able to run the asar tool.
	$nodeVer = Resolve-NodeVersion
	$nodeOk = $nodeVer -and ($nodeVer -ge $min)

	# Report card.
	$mark = { param($ok) if ($ok) { '[+]' } else { '[X]' } }
	Write-Host ''
	Write-Host '  Prerequisite check' -ForegroundColor Cyan
	Write-Host ('  {0} Claude Desktop (MSIX)   {1}' -f (& $mark $claudeOk),
		$(if ($claudeDir) { $claudeDir } else { 'NOT FOUND' }))
	Write-Host ('  {0} Node.js >= {1}        {2}' -f (& $mark $nodeOk), $script:MinNodeVersion,
		$(if ($nodeVer) { "v$nodeVer" } else { 'NOT FOUND' }))
	Write-Host ''

	# Claude missing is fatal — we can't install it for the user.
	if (-not $claudeOk) {
		throw ("Claude Desktop (Microsoft Store / MSIX build) was not found. " +
			"Install it from https://claude.ai/download, then re-run.")
	}

	# Node missing/too old — offer to install.
	if (-not $nodeOk) {
		$why = if ($nodeVer) { "Node v$nodeVer is older than the required v$($script:MinNodeVersion)." }
			else { 'Node.js was not found.' }
		Write-Warn2 $why
		if (Confirm-Action 'Install Node.js LTS now (via winget)?') {
			if (Install-NodeViaWinget) {
				$nodeVer = Resolve-NodeVersion
				$nodeOk = $nodeVer -and ($nodeVer -ge $min)
			}
		}
		if (-not $nodeOk) {
			throw ("Node.js >= $($script:MinNodeVersion) is required. " +
				"Install it from https://nodejs.org (LTS), then re-run. " +
				"(Automatic install needs winget / App Installer.)")
		}
		Write-Ok "Node $nodeVer ready."
	}

	# Final confirmation before touching the install.
	Write-Host ''
	if (-not (Confirm-Action "Patch Claude Desktop now?")) {
		throw 'Aborted by user.'
	}
	return $claudeDir
}

# -----------------------------------------------------------------------------
# Auto-update watcher
#
# Claude Desktop auto-updates by installing a NEW MSIX package and replacing all
# files with fresh originals — wiping the patch. A logon + periodic Scheduled
# Task runs a small watcher that compares the installed version to the
# last-patched version and silently re-applies the patch (-Yes) when they differ.
#
# The watcher runs the patcher from a STABLE copy under %ProgramData% (not the
# user's Downloads folder, which may be deleted), so it keeps working forever.
# -----------------------------------------------------------------------------

function Get-ClaudeVersion {
	# Version string of the currently-installed MSIX Claude (e.g. 1.9659.2.0).
	$pkg = Get-AppxPackage | Where-Object {
		$_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*'
	} | Select-Object -First 1
	if ($pkg -and $pkg.Version) { return [string]$pkg.Version }
	# Fallback: parse from the install-folder name Claude_<ver>_x64__...
	$dir = Find-ClaudeDir
	if ($dir -and (Split-Path $dir -Leaf) -match '^Claude_([\d.]+)_') { return $Matches[1] }
	return $null
}

function Save-PatchState([string]$Version) {
	if (-not (Test-Path $script:StateDir)) {
		New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
	}
	$state = [ordered]@{
		patchedVersion = $Version
		patchedAt      = (Get-Date).ToUniversalTime().ToString('o')
	}
	$state | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Get-PatchedVersion {
	if (-not (Test-Path $script:StateFile)) { return $null }
	try { return (Get-Content $script:StateFile -Raw | ConvertFrom-Json).patchedVersion }
	catch { return $null }
}

# Copy the patcher + the five resolved JS payloads into the stable ProgramData
# app dir, so the watcher can re-run the patch independent of where the user
# originally unzipped it.
function Save-StableBundle([hashtable]$Sources) {
	if (Test-Path $script:StableApp) { Remove-Item $script:StableApp -Recurse -Force }
	New-Item -ItemType Directory -Path $script:StableApp -Force | Out-Null
	Copy-Item $PSCommandPath (Join-Path $script:StableApp 'patch-claude-windows.ps1') -Force
	foreach ($name in $Sources.Keys) {
		Copy-Item $Sources[$name] (Join-Path $script:StableApp $name) -Force
	}
	# Stash the shortcut icon so the watcher's stable-copy re-patch can rebuild it.
	$pngIcon = Resolve-IconPng
	if ($pngIcon) { Copy-Item $pngIcon (Join-Path $script:StableApp 'icon128.png') -Force }
}

# Resolve the bundled shortcut icon (PNG): repo media\, or flat beside the script
# (release bundle / the stashed stable copy). Returns $null if not shipped.
function Resolve-IconPng {
	$src = if ($SourceDir) { $SourceDir } else { $PSScriptRoot }
	foreach ($c in @((Join-Path $src 'media\icon128.png'), (Join-Path $src 'icon128.png'))) {
		if (Test-Path $c) { return $c }
	}
	return $null
}

# Wrap a PNG in a minimal .ico (Windows Vista+ renders PNG-compressed icons), so a
# .lnk can use the project PNG without a separate .ico asset.
function ConvertTo-Ico([string]$PngPath, [string]$IcoPath) {
	$png = [IO.File]::ReadAllBytes($PngPath)
	$ms = New-Object System.IO.MemoryStream
	$bw = New-Object System.IO.BinaryWriter($ms)
	try {
		$bw.Write([uint16]0)            # reserved
		$bw.Write([uint16]1)            # type: 1 = icon
		$bw.Write([uint16]1)            # image count
		$bw.Write([byte]128)           # width  (icon128.png is 128x128)
		$bw.Write([byte]128)           # height
		$bw.Write([byte]0)             # palette size
		$bw.Write([byte]0)             # reserved
		$bw.Write([uint16]1)           # color planes
		$bw.Write([uint16]32)          # bits per pixel
		$bw.Write([uint32]$png.Length) # image data size
		$bw.Write([uint32]22)          # offset = 6 (dir) + 16 (entry)
		$bw.Write($png)
		$bw.Flush()
		[IO.File]::WriteAllBytes($IcoPath, $ms.ToArray())
	} finally { $bw.Dispose(); $ms.Dispose() }
}

# --- re-patch desktop shortcut ----------------------------------------------
# A Desktop .lnk that re-applies the patch after a Claude Desktop update. It runs
# the stable-copy patcher, which self-elevates via UAC, so no extra elevation flag
# is needed. Idempotent (overwrites); Restore removes it.
function Save-Shortcut {
	try {
		$desktop = [Environment]::GetFolderPath('Desktop')
		if (-not $desktop) { return }
		$lnk = Join-Path $desktop 'Re-apply Claude RTL.lnk'
		$patcher = Join-Path $script:StableApp 'patch-claude-windows.ps1'
		$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
		$ws = New-Object -ComObject WScript.Shell
		$sc = $ws.CreateShortcut($lnk)
		$sc.TargetPath = $psExe
		$sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$patcher`" -Action Install -Yes"
		$sc.WorkingDirectory = $script:StableApp
		$sc.Description = 'Re-apply the Claude Desktop Hebrew RTL patch (after a Claude update)'
		# Prefer the project icon (PNG -> .ico); fall back to the PowerShell icon.
		$sc.IconLocation = "$psExe,0"
		$pngIcon = Resolve-IconPng
		if ($pngIcon) {
			$ico = Join-Path $script:StateDir 'repatch-icon.ico'
			try { ConvertTo-Ico $pngIcon $ico; if (Test-Path $ico) { $sc.IconLocation = "$ico,0" } } catch { }
		}
		$sc.Save()
		Write-Ok "Re-patch shortcut created ($lnk)"
	} catch {
		Write-Warn2 "Could not create re-patch shortcut: $($_.Exception.Message)"
	}
}

function Remove-Shortcut {
	try {
		$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Re-apply Claude RTL.lnk'
		if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Ok 'Re-patch shortcut removed' }
	} catch { }
}

function Save-WatcherScript {
	if (-not (Test-Path $script:StateDir)) {
		New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
	}
	# Single-quoted here-string: written verbatim, evaluated at run time. Closing
	# '@ MUST be at column 0.
	$body = @'
# Claude Windows RTL — auto-re-patch watcher. Runs elevated from a Scheduled
# Task at logon and on a schedule. Re-applies the patch when Claude Desktop
# updates to a version newer/different than the one last patched.
$ErrorActionPreference = 'Continue'
$stateDir  = Join-Path $env:ProgramData 'ClaudeWindowsRtl'
$stateFile = Join-Path $stateDir 'state.json'
$patcher   = Join-Path $stateDir 'app\patch-claude-windows.ps1'
$logFile   = Join-Path $stateDir 'watcher.log'

function WLog($m) {
	try {
		if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
			Move-Item $logFile "$logFile.old" -Force
		}
		"$([DateTime]::Now.ToString('o'))  $m" | Out-File -Append -FilePath $logFile -Encoding UTF8
	} catch {}
}

function InstalledVersion {
	$pkg = Get-AppxPackage | Where-Object {
		$_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*'
	} | Select-Object -First 1
	if ($pkg -and $pkg.Version) { return [string]$pkg.Version }
	return $null
}

function PatchedVersion {
	if (-not (Test-Path $stateFile)) { return $null }
	try { return (Get-Content $stateFile -Raw | ConvertFrom-Json).patchedVersion }
	catch { return $null }
}

$inst = InstalledVersion
if (-not $inst) { WLog 'No installed Claude found; nothing to do.'; return }
$patched = PatchedVersion
if ($inst -eq $patched) { WLog "Up to date (v$inst already patched)."; return }
if (-not (Test-Path $patcher)) { WLog "Patcher missing at $patcher; cannot auto-repatch."; return }

WLog "Version change detected (installed=$inst, patched=$patched) — re-applying patch..."
try {
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $patcher -Action Install -Yes *>&1 |
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
		Write-Warn2 'No patch state yet — run the patch (option Install) first.'
		return
	}
	Save-WatcherScript
	try {
		$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
		$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
			-Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:WatcherPs1`""
		$triggers = @(
			(New-ScheduledTaskTrigger -AtLogOn -User $user)
		)
		# Add an hourly repetition so an update mid-session is caught without a logon.
		$daily = New-ScheduledTaskTrigger -Once -At ([DateTime]::Today.AddMinutes(5)) `
			-RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration ([TimeSpan]::MaxValue)
		$triggers += $daily
		$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
			-MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
			-ExecutionTimeLimit ([TimeSpan]::FromMinutes(30))
		$principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
		Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers `
			-Settings $settings -Principal $principal `
			-Description 'Re-applies the Claude Windows RTL patch after Claude Desktop updates.' `
			-Force | Out-Null
		Write-Ok "Auto-re-patch enabled (task '$script:TaskName')."
		Write-Log "Watcher log: $(Join-Path $script:StateDir 'watcher.log')"
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
		Write-Ok "Auto-re-patch disabled."
	} catch { Write-Warn2 "Failed to remove task: $($_.Exception.Message)" }
}

# =============================================================================
# INSTALL
# =============================================================================
function Install-Patch {
	Write-Host "`n=== Claude Desktop (Windows) extensions patch ===`n" -ForegroundColor Cyan

	$ClaudeDir = Invoke-Preflight

	$AppDir = Join-Path $ClaudeDir 'app'
	$ResourcesDir = Join-Path $AppDir 'resources'
	$AsarPath = Join-Path $ResourcesDir 'app.asar'
	$ExePath = Join-Path $AppDir 'claude.exe'
	$CoworkSvcPath = Join-Path $ResourcesDir 'cowork-svc.exe'
	if (-not (Test-Path $AsarPath)) { throw 'app.asar not found.' }

	Assert-NodeToolchain
	$sources = Resolve-SourceFiles
	Stop-ClaudeServices -InstallDir $ClaudeDir

	Write-Step 'Taking ownership...'
	Take-Ownership $AppDir
	Take-Ownership $ResourcesDir

	Write-Step 'Backing up (first run only)...'
	Wait-FileUnlock -Path $ExePath -TimeoutSeconds 15
	Wait-FileUnlock -Path $CoworkSvcPath -TimeoutSeconds 15
	if (-not (Test-Path "$AsarPath.bak")) { Copy-FileSafe $AsarPath "$AsarPath.bak" 'asar'; Write-Ok 'app.asar.bak' }
	if (-not (Test-Path "$ExePath.bak")) { Copy-FileSafe $ExePath "$ExePath.bak" 'pe'; Write-Ok 'claude.exe.bak' }
	if (-not (Test-Path "$CoworkSvcPath.bak")) { Copy-FileSafe $CoworkSvcPath "$CoworkSvcPath.bak" 'pe'; Write-Ok 'cowork-svc.exe.bak' }

	Write-Step 'Restoring originals before re-patching (idempotency)...'
	$pairs = @(
		@{ O = $AsarPath; B = "$AsarPath.bak"; T = 'asar' },
		@{ O = $ExePath; B = "$ExePath.bak"; T = 'pe' },
		@{ O = $CoworkSvcPath; B = "$CoworkSvcPath.bak"; T = 'pe' }
	)
	foreach ($p in $pairs) {
		if ((Test-Path $p.B) -and -not (Test-FileValid -Path $p.B -Type $p.T)) {
			throw "Backup '$(Split-Path $p.B -Leaf)' is corrupt. Delete it and reinstall Claude."
		}
	}
	foreach ($p in $pairs) {
		if (Test-Path $p.B) { Wait-FileUnlock -Path $p.O; Copy-Item $p.B $p.O -Force }
	}

	try {
		Write-Step 'Phase 1: inject extensions into app.asar'
		$OldHash = Compute-AsarHash $AsarPath
		Write-Log "Original asar hash: $OldHash"

		if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }
		cmd.exe /c "npx --yes $($script:AsarPackage) extract `"$AsarPath`" `"$global:TmpDir`""
		if ($LASTEXITCODE -ne 0) { throw "asar extract failed ($LASTEXITCODE)." }

		# Copy our files into the asar root.
		$utf8NoBom = New-Object Text.UTF8Encoding $false
		foreach ($name in $sources.Keys) {
			$dest = Join-Path $global:TmpDir $name
			Copy-Item $sources[$name] $dest -Force
			Write-Log "Injected $name"
		}

		# Rewrite package.json: stash original main, point main at our entry.
		$pkgPath = Join-Path $global:TmpDir 'package.json'
		if (-not (Test-Path $pkgPath)) { throw 'package.json missing in extracted asar.' }
		$pkgRaw = [IO.File]::ReadAllText($pkgPath, [Text.Encoding]::UTF8)
		$pkg = $pkgRaw | ConvertFrom-Json
		$hasOrig = ($pkg.PSObject.Properties.Name -contains 'claudeOriginalMain')
		$currentMain = $pkg.main
		# Stash the real entry once. On a re-patch of an already-patched asar the
		# current main is our own entry, so only record a genuine upstream path.
		if ($currentMain -and $currentMain -ne $script:EntryMain) {
			if ($hasOrig) { $pkg.claudeOriginalMain = $currentMain }
			else { $pkg | Add-Member -NotePropertyName 'claudeOriginalMain' -NotePropertyValue $currentMain }
		} elseif (-not $hasOrig) {
			# No prior record and main is already our entry (or empty): fall back
			# to the conventional bootstrap path so win-entry can still chain.
			$pkg | Add-Member -NotePropertyName 'claudeOriginalMain' -NotePropertyValue '.vite/build/index.pre.js'
		}
		if ($pkg.PSObject.Properties.Name -contains 'main') { $pkg.main = $script:EntryMain }
		else { $pkg | Add-Member -NotePropertyName 'main' -NotePropertyValue $script:EntryMain }
		$newPkg = $pkg | ConvertTo-Json -Depth 50
		[IO.File]::WriteAllText($pkgPath, $newPkg, $utf8NoBom)
		Write-Ok "package.json main -> $($script:EntryMain) (original: $($pkg.claudeOriginalMain))"

		$TmpAsar = "$AsarPath.new"
		cmd.exe /c "npx --yes $($script:AsarPackage) pack `"$global:TmpDir`" `"$TmpAsar`""
		if ($LASTEXITCODE -ne 0) {
			if (Test-Path $TmpAsar) { Remove-Item $TmpAsar -Force }
			throw "asar pack failed ($LASTEXITCODE)."
		}
		if (-not (Test-FileValid -Path $TmpAsar -Type 'asar')) {
			Remove-Item $TmpAsar -Force; throw 'Repacked asar failed integrity check.'
		}
		$NewHash = Compute-AsarHash $TmpAsar
		Write-Log "New asar hash: $NewHash"
		Move-Item $TmpAsar $AsarPath -Force
		# `asar pack` emits a sibling "<out>.unpacked" holding the native modules
		# (.node / winpty.*). We never modify those, so the original
		# app.asar.unpacked is still correct and stays in place; discard the
		# freshly-generated orphan to avoid confusing future runs.
		if (Test-Path "$TmpAsar.unpacked") { Remove-Item "$TmpAsar.unpacked" -Recurse -Force -ErrorAction SilentlyContinue }

		Write-Step 'Phase 2/3: patch claude.exe hash + re-sign binaries'
		if ((Test-Path $ExePath) -and (Test-Path $CoworkSvcPath)) {
			$SourceSvc = if (Test-Path "$CoworkSvcPath.bak") { "$CoworkSvcPath.bak" } else { $CoworkSvcPath }
			$SourceExe = if (Test-Path "$ExePath.bak") { "$ExePath.bak" } else { $ExePath }

			# Locate the Anthropic cert blob in cowork-svc.exe.
			$SvcBytes = [IO.File]::ReadAllBytes($SourceSvc)
			$anchor = [Text.Encoding]::ASCII.GetBytes('Anthropic, PBC')
			$StartPos = -1; $OldCertSize = 0; $off = 0
			while ($true) {
				$ap = Find-Bytes -Haystack $SvcBytes -Needle $anchor -StartIndex $off
				if ($ap -eq -1) { break }
				$limit = [Math]::Max(0, $ap - 2000)
				for ($i = $ap; $i -ge $limit; $i--) {
					if ($SvcBytes[$i] -eq 0x30 -and $SvcBytes[$i + 1] -eq 0x82) {
						$tot = 4 + (([int]$SvcBytes[$i + 2] -shl 8) -bor [int]$SvcBytes[$i + 3])
						if ($tot -gt 500 -and $tot -lt 4000 -and $i -lt $ap -and ($i + $tot) -gt $ap) {
							$StartPos = $i; $OldCertSize = $tot; break
						}
					}
				}
				if ($StartPos -ne -1) { break }
				$off = $ap + 1
			}
			if ($StartPos -eq -1) { throw 'Anthropic cert pattern not found in cowork-svc.exe.' }
			Write-Log "cowork-svc cert hole at 0x$([Convert]::ToString($StartPos,16)) size=$OldCertSize"

			# Clone the original signer subject for a low-profile self-signed cert.
			$origSig = Get-AuthenticodeSignature -FilePath $SourceExe
			$subject = if ($origSig -and $origSig.SignerCertificate) { $origSig.SignerCertificate.Subject } else { 'CN=Claude-Win-Patcher' }

			$root = New-Object Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
			$root.Open('ReadWrite')
			$cert = $null; $newCertBytes = $null; $ok = $false; $try = 1
			while (-not $ok -and $try -le 10) {
				$cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert `
					-CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName 'Claude_Win_SelfSigned' `
					-KeyAlgorithm RSA -KeyLength 2048
				$newCertBytes = $cert.RawData
				if ($newCertBytes.Length -le $OldCertSize) {
					$root.Add($cert); $ok = $true
					Write-Ok "Cert fits ($($newCertBytes.Length) <= $OldCertSize bytes)"
				} else {
					Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $cert.Thumbprint } |
						Remove-Item -ErrorAction SilentlyContinue
					$try++
				}
			}
			$root.Close()
			if (-not $ok) { throw 'Could not generate a small-enough certificate.' }

			# Byte-replace the asar hash inside claude.exe.
			Wait-FileUnlock $ExePath
			$ExeBytes = [IO.File]::ReadAllBytes($SourceExe)
			$oldHB = [Text.Encoding]::ASCII.GetBytes($OldHash)
			$newHB = [Text.Encoding]::ASCII.GetBytes($NewHash)
			$oe = 0; $rep = 0
			while ($true) {
				$idx = Find-Bytes -Haystack $ExeBytes -Needle $oldHB -StartIndex $oe
				if ($idx -eq -1) { break }
				[Array]::Copy($newHB, 0, $ExeBytes, $idx, $newHB.Length)
				$oe = $idx + $oldHB.Length; $rep++
			}
			if ($rep -gt 0) {
				[IO.File]::WriteAllBytes($ExePath, $ExeBytes)
				Write-Ok "Replaced $rep asar hash(es) in claude.exe"
			} else {
				Write-Warn2 'Hash not found in claude.exe; falling back to fuse flip.'
				if (-not (Invoke-FuseFlip -ExePath $ExePath)) {
					throw 'Both hash-replace and fuse-flip failed.'
				}
				Write-Ok 'ASAR integrity bypassed via fuse.'
			}

			Write-Log 'Re-signing claude.exe...'
			$s1 = Set-AuthenticodeSignature -FilePath $ExePath -Certificate $cert -HashAlgorithm SHA256
			if ($s1.Status -ne 'Valid') { throw "claude.exe re-sign failed: $($s1.Status)" }
			Write-Ok 'claude.exe re-signed.'

			# Swap the cert in cowork-svc.exe and re-sign it too.
			Wait-FileUnlock $CoworkSvcPath
			$padded = New-Object byte[] $OldCertSize
			[Array]::Copy($newCertBytes, 0, $padded, 0, $newCertBytes.Length)
			[Array]::Copy($padded, 0, $SvcBytes, $StartPos, $OldCertSize)
			[IO.File]::WriteAllBytes($CoworkSvcPath, $SvcBytes)
			$s2 = Set-AuthenticodeSignature -FilePath $CoworkSvcPath -Certificate $cert -HashAlgorithm SHA256
			if ($s2.Status -ne 'Valid') { throw "cowork-svc.exe re-sign failed: $($s2.Status)" }
			Write-Ok 'cowork-svc.exe cert swapped + re-signed.'

			# Wipe the private key (public cert stays in Root for verification).
			try {
				$my = New-Object Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
				$my.Open('ReadWrite')
				$f = $my.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
				if ($f) {
					if ($f.HasPrivateKey) {
						$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($f)
						if ($rsa -is [Security.Cryptography.RSACng]) { $rsa.Key.Delete() }
						elseif ($rsa -is [Security.Cryptography.RSACryptoServiceProvider]) { $rsa.PersistKeyInCsp = $false; $rsa.Clear() }
					}
					$my.Remove($f)
				}
				$my.Close()
				Write-Ok 'Private signing key wiped (Root cert retained).'
			} catch { Write-Warn2 "Could not wipe private key: $($_.Exception.Message)" }
		} else {
			Write-Warn2 'claude.exe or cowork-svc.exe missing; binary patch skipped.'
		}

		if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }

		# Record what we patched + stash a stable copy of the bundle so the
		# auto-update watcher can re-apply the patch after a Claude update.
		$ver = Get-ClaudeVersion
		Save-PatchState $ver
		try { Save-StableBundle $sources } catch { Write-Warn2 "Could not stash stable bundle: $($_.Exception.Message)" }
		Save-Shortcut

		Write-Host "`n=== PATCH COMPLETE ===`n" -ForegroundColor Green

		# Offer (or auto-enable) auto-re-patch so Claude updates don't silently
		# drop the extensions. Skip the prompt if the task already exists.
		$taskExists = [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
		if ($taskExists) {
			# Keep the stable bundle + watcher current with this version.
			Save-WatcherScript
			Write-Log 'Auto-re-patch already enabled; refreshed.'
		} elseif ($EnableAutoUpdate -or (Confirm-Action 'Auto-re-apply this patch after Claude Desktop updates?')) {
			Install-AutoUpdateTask
		} else {
			Write-Log "Tip: re-run after a Claude update, or enable auto-re-patch with -Action EnableAutoUpdate."
		}

		Start-ClaudeApp
	} catch {
		Write-Host "`n[X] ERROR: $($_.Exception.Message)" -ForegroundColor Red
		Write-Warn2 'Rolling back from backups...'
		Restore-Patch -IsRollback
		throw
	}
}

# =============================================================================
# RESTORE
# =============================================================================
function Restore-Patch {
	param([switch]$IsRollback)
	if (-not $IsRollback) { Write-Host "`n=== Restoring Claude to original state ===`n" -ForegroundColor Cyan }

	$ClaudeDir = Find-ClaudeDir
	if (-not $ClaudeDir) { Write-Warn2 'Claude install not found.'; return }
	$AppDir = Join-Path $ClaudeDir 'app'
	$ResourcesDir = Join-Path $AppDir 'resources'

	Stop-ClaudeServices -InstallDir $ClaudeDir
	Take-Ownership $AppDir
	Take-Ownership $ResourcesDir

	$items = @(
		@{ O = Join-Path $ResourcesDir 'app.asar'; B = Join-Path $ResourcesDir 'app.asar.bak'; T = 'asar' },
		@{ O = Join-Path $AppDir 'claude.exe'; B = Join-Path $AppDir 'claude.exe.bak'; T = 'pe' },
		@{ O = Join-Path $ResourcesDir 'cowork-svc.exe'; B = Join-Path $ResourcesDir 'cowork-svc.exe.bak'; T = 'pe' }
	)
	$bad = @()
	foreach ($it in $items) {
		if ((Test-Path $it.B) -and -not (Test-FileValid -Path $it.B -Type $it.T)) {
			$bad += (Split-Path $it.B -Leaf)
		}
	}
	if ($bad.Count -gt 0) {
		Write-Warn2 "Corrupt backup(s): $($bad -join ', '). Aborting restore to avoid making things worse."
		return
	}
	foreach ($it in $items) {
		if (Test-Path $it.B) {
			Wait-FileUnlock -Path $it.O
			Copy-Item $it.B $it.O -Force
			Write-Ok "Restored $(Split-Path $it.O -Leaf)"
		}
	}
	if (-not $IsRollback) {
		# A deliberate restore means "I'm done" — stop the watcher so it doesn't
		# silently re-patch on the next Claude update. (Rollback leaves it alone.)
		if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
			Uninstall-AutoUpdateTask
		}
		Remove-Shortcut
		Write-Host "`n=== Restore complete ===`n" -ForegroundColor Green
	}
}

# =============================================================================
switch ($Action) {
	'Install'           { Install-Patch }
	'Restore'           { Restore-Patch }
	'EnableAutoUpdate'  { Install-AutoUpdateTask }
	'DisableAutoUpdate' { Uninstall-AutoUpdateTask }
}

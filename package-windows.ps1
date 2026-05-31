<#
.SYNOPSIS
    Assemble a self-contained, distributable ZIP of the Windows extensions patch.
.DESCRIPTION
    Collects the patcher plus its five JS payload files (from .\src\) into a
    single flat folder and zips it. The patcher's Resolve-SourceFiles detects
    this flat "bundle" layout, so the ZIP is fully self-contained — the target
    machine needs only Node.js and the MSIX Claude Desktop, no repo checkout.

    Output (under .\dist\ by default):
        claude-desktop-windows-rtl[-vX.Y.Z]\     the unpacked bundle
        claude-desktop-windows-rtl[-vX.Y.Z].zip  the shippable archive
.PARAMETER OutDir
    Where to write the bundle. Defaults to .\dist next to this script.
.PARAMETER Version
    Optional version (e.g. 1.0.0 or v1.0.0). When set, the bundle/zip names get a
    -vX.Y.Z suffix so each download is self-identifying.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\package-windows.ps1 -Version 1.0.0
#>
[CmdletBinding()]
param(
	[string]$OutDir,
	[string]$Version
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$srcDir = Join-Path $scriptDir 'src'

if (-not $OutDir) { $OutDir = Join-Path $scriptDir 'dist' }

# Bundle/zip are named after the project. A version suffix (e.g. -v1.0.0) is
# added when -Version is supplied so every download is self-identifying. Accepts
# "1.0.0" or "v1.0.0".
$projectName = 'claude-desktop-windows-rtl'
$verSuffix = ''
if ($Version) {
	$v = $Version.TrimStart('v', 'V')
	$verSuffix = "-v$v"
}
$bundleName = "$projectName$verSuffix"
$bundleDir = Join-Path $OutDir $bundleName
$zipPath = Join-Path $OutDir "$bundleName.zip"

# (file name, source dir) — patcher at root, the five JS payloads in src\.
$payload = @(
	@{ Name = 'patch-claude-windows.ps1';   Dir = $scriptDir },
	@{ Name = 'win-entry.js';               Dir = $srcDir },
	@{ Name = 'win-wrapper.js';             Dir = $srcDir },
	@{ Name = 'rtl-support.js';             Dir = $srcDir },
	@{ Name = 'translate-support.js';       Dir = $srcDir },
	@{ Name = 'multi-instance-support.js';  Dir = $srcDir }
)

foreach ($p in $payload) {
	$full = Join-Path $p.Dir $p.Name
	if (-not (Test-Path $full)) { throw "Missing payload file: $full" }
}

if (Test-Path $bundleDir) { Remove-Item $bundleDir -Recurse -Force }
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

foreach ($p in $payload) {
	Copy-Item (Join-Path $p.Dir $p.Name) (Join-Path $bundleDir $p.Name) -Force
}

$install = @'
Claude Desktop — Windows extensions patch
=========================================

Adds RTL (Hebrew/Arabic) support, a version label, page refresh,
translate-to-Hebrew, and a "new window" item to the official Windows
Claude Desktop, by patching the installed app in place.

REQUIREMENTS
------------
- Windows 10/11 with the official Claude Desktop installed
  (Microsoft Store / MSIX build).
- Administrator rights (the script elevates itself via UAC).
- Node.js 22.12+ — the patcher checks for it and, if missing/too old, offers
  to install Node LTS via winget (with your confirmation).

INSTALL
-------
1. Unzip this folder anywhere (e.g. your Desktop).
2. Right-click "Run-Patch.cmd" -> Run as administrator.
   (Or in PowerShell:  powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1 )
3. The patcher runs a prerequisite check, shows what's present/missing, and
   asks before installing Node or patching. Approve the prompts; Claude
   closes, gets patched, and relaunches.

Unattended (auto-approve all prompts):
   powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1 -Yes

STAYING PATCHED ACROSS UPDATES
------------------------------
Claude Desktop auto-updates by installing a fresh copy, which removes the
patch. At the end of a successful patch the installer offers to enable
auto-re-patch (a Scheduled Task that re-applies the patch automatically when
Claude updates). You can also toggle it manually:
   ...\patch-claude-windows.ps1 -Action EnableAutoUpdate
   ...\patch-claude-windows.ps1 -Action DisableAutoUpdate
Or just re-run the patcher yourself after each Claude update.

UNINSTALL / RESTORE ORIGINAL
----------------------------
   powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1 -Action Restore

NOTES
-----
- The patcher backs up app.asar / claude.exe / cowork-svc.exe to *.bak
  before changing anything; Restore puts them back.
- Patching re-signs the binaries with a self-signed certificate added to
  the machine Root store. Some endpoint-protection (EDR) products may flag
  or block this; if Claude fails to launch after patching, run Restore and
  add an EDR exclusion for the Claude install folder, then retry.
'@
Set-Content (Join-Path $bundleDir 'INSTALL.txt') -Value $install -Encoding utf8

$cmd = @'
@echo off
REM Elevates and runs the patcher. Right-click -> Run as administrator,
REM or just double-click and approve the UAC prompt.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0patch-claude-windows.ps1'"
'@
Set-Content (Join-Path $bundleDir 'Run-Patch.cmd') -Value $cmd -Encoding ascii

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Bundle assembled:" -ForegroundColor Green
Write-Host "  folder : $bundleDir"
Write-Host "  zip    : $zipPath  ($([math]::Round((Get-Item $zipPath).Length/1KB,1)) KB)"
Write-Host ""
Get-ChildItem $bundleDir | ForEach-Object { Write-Host "  $($_.Name)" }

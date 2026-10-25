# wipe installer for Windows:  irm https://wipemode.vercel.app/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$e = [char]27
$a = "$e[38;5;173m"; $m = "$e[38;5;245m"; $b = "$e[1m"; $r = "$e[0m"

$dir = Join-Path $env:LOCALAPPDATA 'wipe'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$exe = Join-Path $dir 'wipe.exe'

Write-Host ""
Write-Host "   $a●$r ${b}wipe$r  ${m}installing...$r"
Invoke-WebRequest "https://wipemode.vercel.app/dist/wipe-windows-$arch.exe" -OutFile $exe -UseBasicParsing

# Make `wipe` work in this window and in new ones.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';') + ';' + $dir).TrimStart(';')), 'User')
}
if (($env:Path -split ';') -notcontains $dir) { $env:Path += ";$dir" }

Write-Host "   $a✓$r ${b}wipe$r  ${m}installed - next time just type$r wipe"
& $exe

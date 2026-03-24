<#
.SYNOPSIS
    Installs the DockerSqlHook startup hook for local development.

.DESCRIPTION
    1. Builds the DockerSqlHook project
    2. Copies the output DLL to a well-known location
    3. Sets user-level environment variables:
       - DOTNET_STARTUP_HOOKS  → path to the hook DLL
       - DOCKER_SQL_PASSWORD   → SA password for the Docker SQL container
       - DOCKER_SQL_USER       → (optional) defaults to "sa"

    After running this script, restart any terminal / IDE sessions
    so they pick up the new environment variables.

.PARAMETER SqlPassword
    The SA password used by your Docker SQL Server container.
    Default: Passw0rd

.PARAMETER SqlUser
    The SQL login to use. Default: sa

.PARAMETER InstallDir
    Where to place the built DLL. Default: V:\tools\DockerSqlHook

.PARAMETER Uninstall
    Removes the environment variables and deletes the install directory.

.EXAMPLE
    .\Install-DockerSqlHook.ps1 -SqlPassword "MyP@ssw0rd!"

.EXAMPLE
    .\Install-DockerSqlHook.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$SqlPassword = "Passw0rd",
    [string]$SqlUser = "sa",
    [string]$InstallDir = "V:\tools\DockerSqlHook",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "  → $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }

# ── Uninstall ────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host "`nUninstalling DockerSqlHook..." -ForegroundColor Yellow

    # Remove env vars
    foreach ($var in @("DOTNET_STARTUP_HOOKS", "DOCKER_SQL_PASSWORD", "DOCKER_SQL_USER")) {
        $current = [Environment]::GetEnvironmentVariable($var, "User")
        if ($current) {
            # For DOTNET_STARTUP_HOOKS, only remove our entry (there may be others)
            if ($var -eq "DOTNET_STARTUP_HOOKS") {
                $entries = $current -split [IO.Path]::PathSeparator |
                    Where-Object { $_ -notlike "*DockerSqlHook*" }
                $newVal = ($entries -join [IO.Path]::PathSeparator).Trim([IO.Path]::PathSeparator)
                if ($newVal) {
                    [Environment]::SetEnvironmentVariable($var, $newVal, "User")
                    Write-OK "Removed DockerSqlHook from $var (kept other hooks)"
                } else {
                    [Environment]::SetEnvironmentVariable($var, $null, "User")
                    Write-OK "Removed $var"
                }
            } else {
                [Environment]::SetEnvironmentVariable($var, $null, "User")
                Write-OK "Removed $var"
            }
        }
    }

    # Remove install directory
    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir
        Write-OK "Deleted $InstallDir"
    }

    Write-Host "`nDone. Restart your terminal / IDE to apply.`n" -ForegroundColor Green
    return
}

# ── Install ──────────────────────────────────────────────────
Write-Host "`nInstalling DockerSqlHook...`n" -ForegroundColor Cyan

# 1. Build
$projectDir = $PSScriptRoot
$csproj = Join-Path $projectDir "DockerSqlHook.csproj"

if (-not (Test-Path $csproj)) {
    throw "Cannot find DockerSqlHook.csproj in $projectDir"
}

Write-Step "Building project..."
dotnet build $csproj -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "Build failed" }
Write-OK "Build succeeded"

# 2. Determine which TFM to use based on the running dotnet version
$dotnetVersion = [int](dotnet --version).Split('.')[0]
$tfm = "net$dotnetVersion.0"

# Validate the TFM was built
$buildOutput = Join-Path $projectDir "bin\Release\$tfm"
if (-not (Test-Path $buildOutput)) {
    # Fall back to the highest available TFM
    $available = Get-ChildItem (Join-Path $projectDir "bin\Release") -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
    $tfm = $available.Name
    $buildOutput = $available.FullName
    Write-Warn "Falling back to $tfm"
}

Write-OK "Using $tfm"

# 3. Copy to install directory
Write-Step "Copying to $InstallDir..."
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Copy the DLL and its dependencies
Copy-Item "$buildOutput\*" -Destination $InstallDir -Recurse -Force
Write-OK "Files copied"

# 4. Set environment variables
$dllPath = Join-Path $InstallDir "DockerSqlHook.dll"

# Handle DOTNET_STARTUP_HOOKS — append, don't overwrite (other hooks may exist)
$existingHooks = [Environment]::GetEnvironmentVariable("DOTNET_STARTUP_HOOKS", "User")
if ($existingHooks -and $existingHooks -notlike "*DockerSqlHook*") {
    $newHooks = "$existingHooks$([IO.Path]::PathSeparator)$dllPath"
} else {
    $newHooks = $dllPath
}

[Environment]::SetEnvironmentVariable("DOTNET_STARTUP_HOOKS", $newHooks, "User")
Write-OK "DOTNET_STARTUP_HOOKS = $newHooks"

[Environment]::SetEnvironmentVariable("DOCKER_SQL_PASSWORD", $SqlPassword, "User")
Write-OK "DOCKER_SQL_PASSWORD = $SqlPassword"

if ($SqlUser -ne "sa") {
    [Environment]::SetEnvironmentVariable("DOCKER_SQL_USER", $SqlUser, "User")
    Write-OK "DOCKER_SQL_USER = $SqlUser"
}

# 5. Summary
Write-Host "`n────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Hook DLL:  $dllPath"
Write-Host "  SQL User:  $SqlUser"
Write-Host "  SQL Pass:  $SqlPassword"
Write-Host ""
Write-Host "  What happens now:" -ForegroundColor White
Write-Host "    • Any .NET app launched from a new terminal session"
Write-Host "      will have SSPI connection strings automatically"
Write-Host "      rewritten to SQL Authentication."
Write-Host "    • Apps on developers without these env vars are unaffected."
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Restart your terminal / IDE / Visual Studio"
Write-Host "    2. Make sure your Docker SQL container is running on :1433"
Write-Host "    3. Run your .NET solutions as usual"
Write-Host ""
Write-Host "  To uninstall:  .\Install-DockerSqlHook.ps1 -Uninstall" -ForegroundColor Yellow
Write-Host ""

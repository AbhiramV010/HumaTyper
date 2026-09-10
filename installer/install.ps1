<#
.SYNOPSIS
    Installs HumaTyper by cloning the repo, pointing humatype.bat at it, and
    putting that launcher on PATH.

.DESCRIPTION
    Four independent steps, each safe to re-run:

      1. Install-Repository   clone (or fast-forward) the repo into $InstallDir
      2. Install-Dependencies npm install, plus the Electron runtime
      3. Set-LauncherTarget   rewrite humatype.bat's `cd /d` to $InstallDir
      4. Register-OnPath      add $InstallDir to PATH

    One launcher on PATH covers cmd, Windows PowerShell 5, and PowerShell 7 alike:
    .BAT is in PATHEXT, and all three resolve PATHEXT entries from PATH.

.PARAMETER InstallDir
    Where to install. Defaults to <system drive>\HumaTyper.

    Program Files is a poor default here and is not used unless you ask for it:
    humatype.bat writes launch.vbs beside itself, and `npm start` runs a build
    that writes into the install directory. Both fail for a standard user under
    Program Files. Pass -InstallDir 'C:\Program Files\HumaTyper' if you want it
    anyway -- you will need an elevated shell.

.PARAMETER Uninstall
    Remove the PATH entry and delete the install directory.

.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -InstallDir D:\Tools\HumaTyper
.EXAMPLE
    .\install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:SystemDrive 'HumaTyper'),
    [string]$RepoUrl    = 'https://github.com/AbhiramV010/AutoTyper.git',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$LauncherName = 'humatype.bat'

# ---------------------------------------------------------------- helpers ----

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Info { param([string]$Text) Write-Host "    $Text" }

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Prerequisites {
    Write-Step 'Checking prerequisites'
    foreach ($tool in 'git', 'node', 'npm') {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if (-not $found) {
            throw "'$tool' was not found on PATH. Install Git (https://git-scm.com) and Node.js (https://nodejs.org), then try again."
        }
        Write-Info "$tool -> $($found.Source)"
    }
}

# PATH lives in a different hive depending on whether we can write machine state.
function Get-PathScope {
    if (Test-Elevated) {
        [pscustomobject]@{
            Name = 'system'
            Key  = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        }
    } else {
        [pscustomobject]@{ Name = 'user'; Key = 'Registry::HKEY_CURRENT_USER\Environment' }
    }
}

# Let Explorer know, so newly opened shells pick the change up without a reboot.
function Publish-EnvironmentChange {
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    [UIntPtr]$result = [UIntPtr]::Zero
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $null = [Win32.NativeMethods]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

# ------------------------------------------------------------------ steps ----

function Install-Repository {
    param([string]$Dir, [string]$Url)

    Write-Step "Installing repository to $Dir"

    if (Test-Path (Join-Path $Dir '.git')) {
        Write-Info 'Existing clone found - fetching latest.'
        git -C $Dir remote set-url origin $Url
        git -C $Dir fetch --depth 1 origin
        # The working tree is a deployment target, not a place to keep edits.
        git -C $Dir reset --hard origin/HEAD
        if ($LASTEXITCODE -ne 0) { throw "git update failed in $Dir." }
        return
    }

    if (Test-Path $Dir) {
        $entries = @(Get-ChildItem -LiteralPath $Dir -Force)
        if ($entries.Count -gt 0) {
            throw "$Dir already exists and is not a git clone. Move it aside, or pass a different -InstallDir."
        }
    }

    $parent = Split-Path -Parent $Dir
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    git clone --depth 1 $Url $Dir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed. Check the URL and your network: $Url" }
}

function Install-Dependencies {
    param([string]$Dir)

    Write-Step 'Installing dependencies'

    # --include=dev: electron and typescript are devDependencies, so a machine with
    # NODE_ENV=production (or npm's omit=dev) would skip them and break the build.
    Push-Location $Dir
    try {
        npm install --include=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }

        # Electron 43+ ships no postinstall script, so npm install fetches the
        # package but NOT the ~350 MB runtime under dist/. It has to be requested
        # explicitly, or `electron .` later fails on a missing binary.
        $exe = Join-Path $Dir 'node_modules\electron\dist\electron.exe'
        if (Test-Path $exe) {
            Write-Info 'Electron runtime already present.'
        } else {
            Write-Info 'Downloading Electron runtime (~350 MB, this can take a few minutes)...'
            node (Join-Path $Dir 'node_modules\electron\install.js')
            if ($LASTEXITCODE -ne 0) { throw 'Failed to download the Electron runtime.' }
        }
        if (-not (Test-Path $exe)) {
            throw "Electron runtime is still missing (expected $exe)."
        }
    } finally {
        Pop-Location
    }
}

function Set-LauncherTarget {
    param([string]$Dir)

    Write-Step "Pointing $LauncherName at $Dir"

    $bat = Join-Path $Dir $LauncherName

    # The launcher normally rides along in the clone and we just retarget it. If the
    # repo does not carry it (it is currently untracked), write the canonical version
    # so a fresh clone still yields a working install.
    if (-not (Test-Path $bat)) {
        Write-Info "$LauncherName is not in the repo - creating it."
        $template = @(
            '@echo off'
            'cd /d "{0}"' -f $Dir
            'echo Set WshShell = CreateObject("WScript.Shell") > launch.vbs'
            'echo WshShell.Run "cmd /c npm start", 0, False >> launch.vbs'
            'cscript //nologo launch.vbs'
            'del launch.vbs'
            'exit'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($bat, $template + "`r`n", [System.Text.UTF8Encoding]::new($false))
        Write-Info ('cd /d "{0}"' -f $Dir)
        return
    }

    $content = Get-Content -LiteralPath $bat -Raw

    # Rewrite the `cd /d "..."` line to the install location.
    # The trailing \r? matters: in multiline mode $ matches before \n, so on a CRLF
    # file the carriage return is still part of the line and must be consumed.
    $pattern = '(?m)^[ \t]*cd[ \t]+/d[ \t]+"[^"]*"[ \t]*\r?$'
    if ($content -notmatch $pattern) {
        throw "Could not find a 'cd /d' line to update in $bat."
    }

    # Escape $ so .NET does not treat it as a substitution group reference.
    $replacement = ('cd /d "{0}"' -f $Dir).Replace('$', '$$')
    $updated = [regex]::Replace($content, $pattern, $replacement)

    # Batch files are read in the OEM codepage; UTF-8 without BOM is byte-identical
    # to ASCII for these contents and avoids a BOM confusing cmd.exe.
    [System.IO.File]::WriteAllText($bat, $updated, [System.Text.UTF8Encoding]::new($false))

    Write-Info (($updated -split "`r?`n" | Where-Object { $_ -match '^\s*cd\s+/d' }) -join '')
}

function Register-OnPath {
    param([string]$Dir)

    $scope = Get-PathScope
    Write-Step "Adding to $($scope.Name) PATH"

    $current = (Get-ItemProperty -Path $scope.Key -Name Path -ErrorAction SilentlyContinue).Path
    if ($null -eq $current) { $current = '' }

    $already = @($current -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') })
    if ($already.Count -gt 0) {
        Write-Info 'Already on PATH.'
        return
    }

    $new = if ($current.Trim()) { $current.TrimEnd(';') + ';' + $Dir } else { $Dir }
    # ExpandString keeps %SystemRoot%-style entries already in PATH intact.
    Set-ItemProperty -Path $scope.Key -Name Path -Value $new -Type ExpandString
    Publish-EnvironmentChange
    Write-Info "Added $Dir"
}

function Unregister-FromPath {
    param([string]$Dir)

    $scope = Get-PathScope
    Write-Step "Removing from $($scope.Name) PATH"

    $current = (Get-ItemProperty -Path $scope.Key -Name Path -ErrorAction SilentlyContinue).Path
    if (-not $current) { Write-Info 'Nothing to remove.'; return }

    $kept = @($current -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Dir.TrimEnd('\') })
    Set-ItemProperty -Path $scope.Key -Name Path -Value ($kept -join ';') -Type ExpandString
    Publish-EnvironmentChange
    Write-Info 'Removed.'
}

function Remove-Installation {
    param([string]$Dir)

    Unregister-FromPath -Dir $Dir

    Write-Step "Removing $Dir"
    if (Test-Path $Dir) {
        Remove-Item -LiteralPath $Dir -Recurse -Force
        Write-Info 'Deleted.'
    } else {
        Write-Info 'Nothing to delete.'
    }
}

# ------------------------------------------------------------------- main ----

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if ($Uninstall) {
    Remove-Installation -Dir $InstallDir
    Write-Host "`nHumaTyper uninstalled.`n" -ForegroundColor Green
    return
}

if ($InstallDir -like "$env:ProgramFiles*" -and -not (Test-Elevated)) {
    throw "Installing to '$InstallDir' needs an elevated shell. Re-run as Administrator, or use the default location."
}

Assert-Prerequisites
Install-Repository   -Dir $InstallDir -Url $RepoUrl
Install-Dependencies -Dir $InstallDir
Set-LauncherTarget   -Dir $InstallDir
Register-OnPath      -Dir $InstallDir

Write-Host "`nHumaTyper installed to $InstallDir" -ForegroundColor Green
Write-Host "Open a NEW terminal (cmd, PowerShell 5, or pwsh 7) and type: humatype`n"

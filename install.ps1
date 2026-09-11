# Usage: irm https://github.com/AbhiramV010/HumaTyper/raw/main/install.ps1 | iex
# iex can't pass params: & ([scriptblock]::Create((irm <url>))) -InstallDir <dir> | -Package <zip> | -Uninstall

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:SystemDrive 'HumaTyper'),
    [string]$Package,
    [switch]$Uninstall
)

# iex runs in the caller's scope; this keeps settings from leaking into it.
& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    # PS5's progress bar slows the download from seconds to minutes.
    $ProgressPreference = 'SilentlyContinue'

    $Repo         = 'AbhiramV010/HumaTyper'
    $ExeName      = 'HumaTyper.exe'
    $LauncherName = 'humatype.cmd'

    function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
    function Write-Info { param([string]$Text) Write-Host "    $Text" }

    function Test-Elevated {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # Unexpanded, so %VAR% entries aren't frozen into literal paths on rewrite.
    function Get-RawPath {
        param([string]$Key)
        (Get-Item -Path $Key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    }

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

    # New shells see the change without a reboot.
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

    # A running copy locks its files.
    function Stop-RunningCopy {
        param([string]$Dir)
        $running = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($ExeName)) -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($Dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -gt 0) {
            Write-Info 'Closing the running copy of HumaTyper.'
            $running | Stop-Process -Force
            $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
        }
    }

    # Never delete a directory that isn't ours.
    function Assert-OwnedOrEmpty {
        param([string]$Dir)
        if (-not (Test-Path $Dir)) { return }
        if (Test-Path (Join-Path $Dir $ExeName)) { return }
        if (@(Get-ChildItem -LiteralPath $Dir -Force).Count -eq 0) { return }
        throw "$Dir already exists and does not look like a HumaTyper install. Move it aside, or pass a different -InstallDir."
    }

    function Get-ReleasePackage {
        param([string]$Destination)

        Write-Step 'Finding the latest release'

        # Older PS5 defaults to TLS 1.0, which GitHub refuses.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        try {
            $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
        } catch {
            throw "Could not read the latest release of $Repo. Check your network, or that a release has been published: $($_.Exception.Message)"
        }

        $asset = @($release.assets | Where-Object { $_.name -like '*-win.zip' }) | Select-Object -First 1
        if (-not $asset) {
            throw "Release $($release.tag_name) has no *-win.zip asset to install."
        }

        Write-Info ('{0}: {1} ({2:N0} MB)' -f $release.tag_name, $asset.name, ($asset.size / 1MB))
        Write-Info 'Downloading...'
        Invoke-WebRequest $asset.browser_download_url -OutFile $Destination -UseBasicParsing
    }

    function Install-Files {
        param([string]$Dir, [string]$Zip)

        Write-Step "Installing to $Dir"

        Assert-OwnedOrEmpty -Dir $Dir

        # Stage first so a failed unpack leaves the old install intact.
        $staging = "$Dir.partial"
        if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        $parent = Split-Path -Parent $Dir
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

        # Expand-Archive is several times slower on PS5.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $staging)

        if (-not (Test-Path (Join-Path $staging $ExeName))) {
            Remove-Item -LiteralPath $staging -Recurse -Force
            throw "The package does not contain $ExeName at its root."
        }

        Stop-RunningCopy -Dir $Dir
        if (Test-Path $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
        Move-Item -LiteralPath $staging -Destination $Dir
    }

    function Write-Launcher {
        param([string]$Dir)

        Write-Step "Writing $LauncherName"

        # start "" frees the terminal; %~dp0 survives the folder moving.
        $content = @(
            '@echo off'
            ('start "" "%~dp0{0}" %*' -f $ExeName)
        ) -join "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $Dir $LauncherName), $content + "`r`n", [System.Text.UTF8Encoding]::new($false))
    }

    function Register-OnPath {
        param([string]$Dir)

        $scope = Get-PathScope
        Write-Step "Adding to $($scope.Name) PATH"

        $current = Get-RawPath -Key $scope.Key

        $already = @($current -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') })
        if ($already.Count -gt 0) {
            Write-Info 'Already on PATH.'
            return
        }

        $new = if ($current.Trim()) { $current.TrimEnd(';') + ';' + $Dir } else { $Dir }
        # ExpandString keeps %SystemRoot%-style entries expanding.
        Set-ItemProperty -Path $scope.Key -Name Path -Value $new -Type ExpandString
        Publish-EnvironmentChange
        Write-Info "Added $Dir"
    }

    function Unregister-FromPath {
        param([string]$Dir)

        $scope = Get-PathScope
        Write-Step "Removing from $($scope.Name) PATH"

        $current = Get-RawPath -Key $scope.Key
        if (-not $current) { Write-Info 'Nothing to remove.'; return }

        $entries = @($current -split ';')
        $kept = @($entries | Where-Object { $_.TrimEnd('\') -ine $Dir.TrimEnd('\') })
        if ($kept.Count -eq $entries.Count) { Write-Info 'Not on PATH.'; return }
        Set-ItemProperty -Path $scope.Key -Name Path -Value ($kept -join ';') -Type ExpandString
        Publish-EnvironmentChange
        Write-Info 'Removed.'
    }

    function Remove-Installation {
        param([string]$Dir)

        Assert-OwnedOrEmpty -Dir $Dir
        Unregister-FromPath -Dir $Dir

        Write-Step "Removing $Dir"
        if (Test-Path $Dir) {
            Stop-RunningCopy -Dir $Dir
            Remove-Item -LiteralPath $Dir -Recurse -Force
            Write-Info 'Deleted.'
        } else {
            Write-Info 'Nothing to delete.'
        }
    }

    $InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

    if ($Uninstall) {
        Remove-Installation -Dir $InstallDir
        Write-Host "`nHumaTyper uninstalled.`n" -ForegroundColor Green
        return
    }

    if ($InstallDir -like "$env:ProgramFiles*" -and -not (Test-Elevated)) {
        throw "Installing to '$InstallDir' needs an elevated shell. Re-run as Administrator, or use the default location."
    }

    # Fail before downloading.
    Assert-OwnedOrEmpty -Dir $InstallDir

    if ($Package) {
        $zip = (Resolve-Path -LiteralPath $Package).Path
        Install-Files -Dir $InstallDir -Zip $zip
    } else {
        $zip = Join-Path ([IO.Path]::GetTempPath()) ("HumaTyper-{0}.zip" -f [guid]::NewGuid())
        try {
            Get-ReleasePackage -Destination $zip
            Install-Files -Dir $InstallDir -Zip $zip
        } finally {
            if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
        }
    }

    Write-Launcher  -Dir $InstallDir
    Register-OnPath -Dir $InstallDir

    Write-Host "`nHumaTyper installed to $InstallDir" -ForegroundColor Green
    Write-Host "Open a NEW terminal (cmd, PowerShell 5, or pwsh 7) and type: humatype`n"
}

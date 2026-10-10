# Runs outside the tray process so replacing/stopping Ceratops cannot stop its
# recovery. Windows PowerShell 5.1 is sufficient; no account or extra runtime is
# needed. Dot-source this file to exercise its operations without starting them.
[CmdletBinding()]
param([switch]$Apply, [string]$TargetVersion)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ReleaseRepository = 'Ceratops-Code/Ceratops-Keyboard-Layout-Fix'
$script:InstallerAssetName = 'CeratopsKeyboardLayout-Setup.exe'
$script:MaximumInstallerBytes = 128MB

function ConvertTo-AppVersion {
    param([string]$Text)
    if ($Text -notmatch '^v?(\d+\.\d+\.\d+)(\.\d+)?$') {
        throw 'The release does not have a numeric application version.'
    }
    $numeric = $Text.TrimStart('v')
    if ($numeric.Split('.').Count -eq 3) { $numeric += '.0' }
    return [version]$numeric
}

function Get-AppVersionText {
    param([version]$Version)
    if ($Version.Revision -eq 0) { return $Version.ToString(3) }
    return $Version.ToString(4)
}

function Get-InstalledAppVersion {
    param([string]$InstallDirectory)
    # This exact machine-wide registration belongs to the Inno Setup installer.
    # An unpacked source checkout must never upgrade the installed application.
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Ceratops Keyboard Layout_is1')
        if ($null -eq $key) { return $null }
        $location = [string]$key.GetValue('InstallLocation', '')
        if (-not $location -or
            [IO.Path]::GetFullPath($location).TrimEnd('\') -ine
            [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')) { return $null }
        return ConvertTo-AppVersion ([string]$key.GetValue('DisplayVersion', ''))
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Open-GitHubResponse {
    param([uri]$Uri)
    # Follow only HTTPS redirects to GitHub-owned download hosts. GitHub's
    # release API supplies the digest; the downloaded bytes must match it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($redirect = 0; $redirect -lt 8; $redirect++) {
        if ($Uri.Scheme -ne 'https' -or $Uri.UserInfo -or
            ($Uri.Host -notin @('api.github.com', 'github.com') -and
             -not $Uri.Host.EndsWith('.githubusercontent.com'))) {
            throw 'The release download redirected outside GitHub HTTPS.'
        }
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.UserAgent = 'CeratopsKeyboardLayout-Updater'
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 30000
        $request.AllowAutoRedirect = $false
        if ($Uri.Host -eq 'api.github.com') {
            $request.Accept = 'application/vnd.github+json'
            $request.Headers['X-GitHub-Api-Version'] = '2026-03-10'
        }
        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        if ($status -eq 200) { return $response }
        try {
            if ($status -notin @(301, 302, 303, 307, 308)) {
                throw "GitHub returned HTTP $status."
            }
            $Uri = [uri]::new($Uri, $response.Headers['Location'])
        } finally { $response.Dispose() }
    }
    throw 'GitHub returned too many redirects.'
}

function ConvertFrom-InstallerRelease {
    param($Release, [version]$ExpectedVersion)
    if ($Release.draft -ne $false -or $Release.prerelease -ne $false) {
        throw 'Only published stable releases can be installed.'
    }
    $version = ConvertTo-AppVersion ([string]$Release.tag_name)
    if ($null -ne $ExpectedVersion -and $version -ne $ExpectedVersion) {
        throw 'GitHub returned a different application version.'
    }
    $assets = @($Release.assets | Where-Object { $_.name -ceq $script:InstallerAssetName })
    if ($assets.Count -ne 1) { throw 'The release must contain exactly one installer.' }
    $asset = $assets[0]
    $expectedUrl = 'https://github.com/{0}/releases/download/{1}/{2}' -f
        $script:ReleaseRepository, $Release.tag_name, $script:InstallerAssetName
    if ($asset.browser_download_url -cne $expectedUrl -or
        $asset.digest -cnotmatch '^sha256:[a-fA-F0-9]{64}$' -or
        $asset.size -le 0 -or $asset.size -gt $script:MaximumInstallerBytes) {
        throw 'The release installer has incomplete or unsafe download metadata.'
    }
    return [pscustomobject]@{
        Version = $version; Uri = [uri]$expectedUrl
        Digest = $asset.digest.Substring(7).ToLowerInvariant(); Size = [long]$asset.size
    }
}

function Get-GitHubInstallerRelease {
    param([string]$VersionText)
    $suffix = 'latest'
    $expected = $null
    if ($VersionText) {
        $expected = ConvertTo-AppVersion $VersionText
        $suffix = 'tags/v' + (Get-AppVersionText $expected)
    }
    $response = Open-GitHubResponse ([uri](
        'https://api.github.com/repos/{0}/releases/{1}' -f $script:ReleaseRepository, $suffix))
    $stream = $null
    $memory = [IO.MemoryStream]::new()
    try {
        if ($response.ContentLength -gt 1MB) { throw 'The release response is too large.' }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($deadline.Elapsed.TotalSeconds -gt 30) { throw 'The release request timed out.' }
            if ($memory.Length + $count -gt 1MB) { throw 'The release response is too large.' }
            $memory.Write($buffer, 0, $count)
        }
        $release = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
        return ConvertFrom-InstallerRelease $release $expected
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $response.Dispose()
        $memory.Dispose()
    }
}

function Open-CheckedInstaller {
    param([string]$Path, $Release)
    # Compute the digest after denying writes/deletion, and keep that same handle
    # until setup (including recovery) finishes. Acceptance cannot race a replace.
    $handle = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha.ComputeHash($handle)).Replace('-', '').ToLowerInvariant()
        if ($handle.Length -ne $Release.Size -or $digest -cne $Release.Digest) {
            throw 'The downloaded installer does not match its GitHub checksum and size.'
        }
        return [pscustomobject]@{ Path = $Path; Handle = $handle }
    } catch {
        $handle.Dispose()
        throw
    } finally { $sha.Dispose() }
}

function Receive-ReleaseInstaller {
    param($Release, [string]$Path)
    $response = Open-GitHubResponse $Release.Uri
    $inputStream = $null
    $outputStream = $null
    try {
        if ($response.ContentLength -gt 0 -and $response.ContentLength -ne $Release.Size) {
            throw 'The installer download has the wrong size.'
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($deadline.Elapsed.TotalSeconds -gt 180) { throw 'The installer download timed out.' }
            if ($outputStream.Length + $count -gt $Release.Size) {
                throw 'The installer download exceeded its declared size.'
            }
            $outputStream.Write($buffer, 0, $count)
        }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        $response.Dispose()
    }
    return Open-CheckedInstaller $Path $Release
}

function Assert-PlainDirectoryTree {
    param([string]$Path)
    # The runtime cache is below the administrator-writable installation, never
    # below a user-writable temp folder. Refuse links even in that protected tree.
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $entry = $pending.Pop()
        $attributes = [IO.File]::GetAttributes($entry)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'An update cache path is a link; it was left untouched.'
        }
        if ($attributes -band [IO.FileAttributes]::Directory) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($entry)) {
                $pending.Push($child)
            }
        }
    }
}

function Remove-UpdateAttempts {
    param([string]$CacheRoot, [string]$KeepPath)
    if (-not [IO.Directory]::Exists($CacheRoot)) { return }
    Assert-PlainDirectoryTree $CacheRoot
    foreach ($directory in [IO.Directory]::EnumerateDirectories($CacheRoot)) {
        if ([IO.Path]::GetFileName($directory) -match '^attempt-[a-f0-9]{32}$' -and
            $directory -ine $KeepPath) { [IO.Directory]::Delete($directory, $true) }
    }
}

function New-UpdateAttempt {
    param([string]$CacheRoot)
    # The caller owns the machine-wide upgrade mutex. Retain at most the newest
    # recovery attempt while preparing a replacement; ordinary orphans are gone.
    if ([IO.Directory]::Exists($CacheRoot)) {
        Assert-PlainDirectoryTree $CacheRoot
        $recovery = @(Get-ChildItem -LiteralPath $CacheRoot -Directory |
            Where-Object { $_.Name -match '^attempt-[a-f0-9]{32}$' -and
                [IO.File]::Exists((Join-Path $_.FullName 'recovery.txt')) } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        $keep = if ($recovery.Count) { $recovery[0].FullName } else { '' }
        Remove-UpdateAttempts $CacheRoot $keep
    } else { $null = [IO.Directory]::CreateDirectory($CacheRoot) }
    $path = Join-Path $CacheRoot ('attempt-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($path)
    return $path
}

function Invoke-InstallerProcess {
    param([string]$Path, [bool]$Recovery)
    $silent = if ($Recovery) { '/VERYSILENT' } else { '/SILENT' }
    $arguments = "$silent /SUPPRESSMSGBOXES /NORESTART /SP- /CERATOPSUPGRADE=1"
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
    try { $process.WaitForExit(); return $process.ExitCode }
    finally { $process.Dispose() }
}

function Get-UpdateOperations {
    # Substitute these four boundaries in tests; the transaction itself is real.
    return @{
        ReadVersion = { param($directory) Get-InstalledAppVersion $directory }
        GetRelease = { param($version) Get-GitHubInstallerRelease $version }
        GetPackage = { param($release, $path) Receive-ReleaseInstaller $release $path }
        RunSetup = { param($path, $recovery) Invoke-InstallerProcess $path $recovery }
    }
}

function Invoke-AppUpgrade {
    param([string]$InstallDirectory, [version]$Version, [string]$CacheRoot,
        [hashtable]$Operations)
    $attempt = $null; $previous = $null; $upgrade = $null
    $installationStarted = $false; $keepRecovery = $false
    $result = $null
    try {
        $current = & $Operations.ReadVersion $InstallDirectory
        if ($null -eq $current) { throw 'The installed application could not be found.' }
        if ($Version -le $current) {
            $result = [pscustomobject]@{ Status = 'Current' }
            return $result
        }
        $attempt = New-UpdateAttempt $CacheRoot
        $oldRelease = & $Operations.GetRelease (Get-AppVersionText $current)
        $newRelease = & $Operations.GetRelease (Get-AppVersionText $Version)
        $previous = & $Operations.GetPackage $oldRelease (Join-Path $attempt 'previous.exe')
        $upgrade = & $Operations.GetPackage $newRelease (Join-Path $attempt 'upgrade.exe')
        if ((& $Operations.ReadVersion $InstallDirectory) -ne $current) {
            throw 'Another installation changed Ceratops while the update was downloading.'
        }
        $installationStarted = $true
        $exitCode = & $Operations.RunSetup $upgrade.Path $false
        if ($exitCode -ne 0 -or (& $Operations.ReadVersion $InstallDirectory) -ne $Version) {
            throw "The new installer did not complete successfully (exit $exitCode)."
        }
        $result = [pscustomobject]@{ Status = 'Upgraded' }
        return $result
    } catch {
        $failure = $_.Exception.Message
        if (-not $installationStarted) {
            $result = [pscustomobject]@{ Status = 'Untouched'; Detail = $failure }
            return $result
        }
        try {
            $exitCode = & $Operations.RunSetup $previous.Path $true
            if ($exitCode -ne 0 -or (& $Operations.ReadVersion $InstallDirectory) -ne $current) {
                throw "The recovery installer did not complete successfully (exit $exitCode)."
            }
            $result = [pscustomobject]@{ Status = 'Restored'; Detail = $failure }
            return $result
        } catch {
            $keepRecovery = $true
            $detail = "Upgrade failed: $failure`r`nRecovery failed: $($_.Exception.Message)"
            $result = [pscustomobject]@{
                Status = 'RecoveryFailed'; Detail = $detail; RecoveryPath = $previous.Path
            }
            try {
                [IO.File]::WriteAllText((Join-Path $attempt 'recovery.txt'),
                    $detail.Substring(0, [Math]::Min(8192, $detail.Length)))
            } catch { $result | Add-Member CacheWarning $_.Exception.Message }
            return $result
        }
    } finally {
        if ($null -ne $upgrade) { $upgrade.Handle.Dispose() }
        if ($null -ne $previous) { $previous.Handle.Dispose() }
        try {
            if ($null -ne $attempt) {
                if ($keepRecovery) {
                    if ($null -ne $upgrade) { [IO.File]::Delete($upgrade.Path) }
                    Remove-UpdateAttempts $CacheRoot $attempt
                } else {
                    Assert-PlainDirectoryTree $attempt
                    [IO.Directory]::Delete($attempt, $true)
                    if ($installationStarted) { Remove-UpdateAttempts $CacheRoot '' }
                }
            }
        } catch {
            # Housekeeping must not relabel a successful install as a failed
            # upgrade or erase the location of a surviving recovery installer.
            if ($null -eq $result) { throw }
            $result | Add-Member CacheWarning $_.Exception.Message -Force
        }
    }
}

function Get-UpgradeOutcomeMessage {
    param($Result)
    $message = switch ($Result.Status) {
        'Untouched' { "Upgrade failed. The current version was not changed.`r`n`r`n" + $Result.Detail }
        'Restored' { 'Upgrade failed. The previous version has been restored and restarted.' }
        'RecoveryFailed' {
            "Upgrade failed, and automatic recovery also failed. Run the saved previous installer:`r`n`r`n" +
                $Result.RecoveryPath + "`r`n`r`n" + $Result.Detail
        }
        default { '' }
    }
    if ($Result.PSObject.Properties['CacheWarning']) {
        $message += "`r`n`r`nThe update cache could not be cleared: " + $Result.CacheWarning
    }
    return $message.Trim()
}

function Show-UpdateMessage {
    param([string]$Text, [switch]$Ask)
    Add-Type -AssemblyName System.Windows.Forms
    $buttons = if ($Ask) { [Windows.Forms.MessageBoxButtons]::YesNo }
        else { [Windows.Forms.MessageBoxButtons]::OK }
    $icon = if ($Ask) { [Windows.Forms.MessageBoxIcon]::Question }
        else { [Windows.Forms.MessageBoxIcon]::Warning }
    $default = if ($Ask) { [Windows.Forms.MessageBoxDefaultButton]::Button2 }
        else { [Windows.Forms.MessageBoxDefaultButton]::Button1 }
    # ServiceNotification shows on the active desktop even when no owner window
    # exists. The helper itself still runs as the signed-in user, never SYSTEM.
    $answer = [Windows.Forms.MessageBox]::Show($Text, 'Ceratops Keyboard Layout',
        $buttons, $icon, $default,
        [Windows.Forms.MessageBoxOptions]::ServiceNotification)
    return $answer -eq [Windows.Forms.DialogResult]::Yes
}

function Test-UpdateAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Enter-UpdateMutex {
    param([string]$Name)
    $mutex = [Threading.Mutex]::new($false, $Name)
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { return $mutex }
        $mutex.Dispose()
        return $null
    } catch { $mutex.Dispose(); throw }
}

function Start-UpgradeWorker {
    param([version]$Version)
    $executable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $PSScriptRoot 'Update-AppInstall.ps1'
    # Windows paths cannot contain quotes; versions have already been parsed.
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Apply -TargetVersion {1}' -f
        $scriptPath, (Get-AppVersionText $Version)
    $options = @{ FilePath = $executable; ArgumentList = $arguments
        WindowStyle = 'Hidden'; PassThru = $true }
    if (-not (Test-UpdateAdministrator)) { $options.Verb = 'RunAs' }
    $process = Start-Process @options
    try { $process.WaitForExit() }
    finally { $process.Dispose() }
}

function Invoke-StartupUpdateCheck {
    param([string]$InstallDirectory = $PSScriptRoot,
        [hashtable]$Operations = (Get-UpdateOperations),
        [scriptblock]$Prompt = { param($message) Show-UpdateMessage $message -Ask },
        [scriptblock]$StartUpgrade = { param($version) Start-UpgradeWorker $version })
    # Offline, GitHub rate limits and unregistered/portable copies are quiet.
    try {
        $current = & $Operations.ReadVersion $InstallDirectory
        if ($null -eq $current) { return }
        $release = & $Operations.GetRelease ''
        if ($release.Version -le $current) { return }
    } catch { return }
    $message = 'Ceratops Keyboard Layout {0} is available (installed: {1}).{2}{2}Upgrade now? Hotkeys pause briefly during installation.' -f
        (Get-AppVersionText $release.Version), (Get-AppVersionText $current), [Environment]::NewLine
    if (& $Prompt $message) {
        try { & $StartUpgrade $release.Version }
        catch { $null = Show-UpdateMessage 'Upgrade failed. The current version was not changed.' }
    }
}

function Invoke-ElevatedUpgrade {
    param([string]$VersionText)
    $mutex = $null
    try {
        if (-not (Test-UpdateAdministrator)) { throw 'Installation needs administrator approval.' }
        if ($null -eq (Get-InstalledAppVersion $PSScriptRoot)) {
            throw 'This helper must run from the registered installation.'
        }
        $mutex = Enter-UpdateMutex 'Global\CeratopsKeyboardLayoutUpgrade'
        if ($null -eq $mutex) { throw 'Another Ceratops upgrade is already running.' }
        $result = Invoke-AppUpgrade $PSScriptRoot (ConvertTo-AppVersion $VersionText) `
            (Join-Path $PSScriptRoot 'UpdateCache') (Get-UpdateOperations)
        $message = Get-UpgradeOutcomeMessage $result
        if ($message) { $null = Show-UpdateMessage $message }
    } catch {
        $null = Show-UpdateMessage ("Upgrade failed. " + $_.Exception.Message)
    } finally {
        if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Apply) { Invoke-ElevatedUpgrade $TargetVersion }
    else {
        $startupMutex = $null
        try {
            $startupMutex = Enter-UpdateMutex 'Local\CeratopsKeyboardLayoutUpdateCheck'
            if ($null -ne $startupMutex) { Invoke-StartupUpdateCheck }
        } catch {
            # A failed background check must never disable keyboard conversion.
        } finally {
            if ($null -ne $startupMutex) { $startupMutex.ReleaseMutex(); $startupMutex.Dispose() }
        }
    }
}

# Noninteractive update checks: real release parsing, locked package acceptance,
# cache ownership and upgrade behavior, with HTTP/setup boundaries substituted.
# No Windows installation, service, GitHub release or user clipboard is changed.
[CmdletBinding()]
param([string]$TempRoot, [string]$CasePattern = '.*')

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-AppInstall.ps1')
if (-not $TempRoot) {
    $commonGit = & git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { throw 'Supply -TempRoot when running outside a Git checkout.' }
    $primary = Split-Path $commonGit -Parent
    $TempRoot = Join-Path (Split-Path $primary -Parent) (
        'tmp/' + (Split-Path $primary -Leaf) + '/app-update-tests')
}
$testRoot = Join-Path $TempRoot ('app-update-tests-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$script:Passed = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Assert-Fails {
    param([scriptblock]$Operation, [string]$ExpectedMessage)
    $failed = $false
    try { & $Operation | Out-Null } catch {
        if ($ExpectedMessage -and -not $_.Exception.Message.Contains($ExpectedMessage)) { throw }
        $failed = $true
    }
    if (-not $failed) { throw 'The unsafe operation was accepted.' }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Operation)
    if ($Name -notmatch $CasePattern) { return }
    try { & $Operation; $script:Passed++ }
    catch { throw "${Name}: $($_.Exception.Message)" }
}

function New-ReleaseFixture {
    param([string]$Version = '1.0.11')
    return [pscustomobject]@{
        tag_name = 'v' + $Version; draft = $false; prerelease = $false
        assets = @([pscustomobject]@{
            name = "CeratopsKeyboardLayout-Setup-$Version.exe"; size = 12
            digest = 'sha256:' + ('a' * 64)
            browser_download_url = 'https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix/releases/download/v' +
                $Version + "/CeratopsKeyboardLayout-Setup-$Version.exe"
        })
    }
}

class UpdateTestResponse : System.IDisposable {
    [long]$ContentLength
    [IO.MemoryStream]$Stream
    UpdateTestResponse([byte[]]$bytes, [long]$declaredLength) {
        $this.ContentLength = $declaredLength
        $this.Stream = [IO.MemoryStream]::new($bytes, $false)
    }
    [IO.Stream] GetResponseStream() { return $this.Stream }
    [void] Dispose() { $this.Stream.Dispose() }
}

# Only the transport boundary is replaced. The JSON and streaming operations,
# including byte limits and checksum acceptance, execute the production code.
function Open-GitHubResponse {
    param([uri]$Uri)
    return $script:NextResponse
}

function New-UpgradeFixture {
    # Closures live in dynamic modules. Capture the helper blocks explicitly so
    # invoking this suite as a child script (as CI does) needs no global functions.
    $convertAppVersion = ${function:ConvertTo-AppVersion}
    $formatAppVersion = ${function:Get-AppVersionText}
    $openCheckedInstaller = ${function:Open-CheckedInstaller}
    $state = [pscustomobject]@{
        Version = (ConvertTo-AppVersion '1.0.10'); Target = (ConvertTo-AppVersion '1.0.11')
        Calls = [Collections.Generic.List[string]]::new(); Mode = ''; Reads = 0
        InstallDirectories = [Collections.Generic.List[string]]::new()
    }
    $operations = @{
        ReadVersion = {
            param($directory)
            $state.Reads++
            if ($state.Mode -eq 'ConcurrentInstall' -and $state.Reads -gt 1) {
                $state.Version = & $convertAppVersion '1.0.12'
            }
            return $state.Version
        }.GetNewClosure()
        GetRelease = {
            param($version)
            $state.Calls.Add("release:$version")
            if ($state.Mode -eq 'UnpublishedCurrent' -and $version -eq '1.0.10') { throw 'Current release missing' }
            return [pscustomobject]@{ Version = (& $convertAppVersion $version) }
        }.GetNewClosure()
        GetPackage = {
            param($release, $path)
            $state.Calls.Add('package:' + [IO.Path]::GetFileName($path))
            if ($state.Mode -eq 'DownloadFailure') { throw 'Download failed' }
            $bytes = [Text.Encoding]::UTF8.GetBytes((& $formatAppVersion $release.Version))
            [IO.File]::WriteAllBytes($path, $bytes)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $release | Add-Member Digest ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant())
                $release | Add-Member Size $bytes.Length
            } finally { $sha.Dispose() }
            if ($state.Mode -eq 'BadNewPackage' -and $release.Version -eq $state.Target) {
                $release.Digest = '0' * 64
            }
            return & $openCheckedInstaller $path $release
        }.GetNewClosure()
        RunSetup = {
            param($path, $directory)
            $state.Calls.Add('setup')
            $state.InstallDirectories.Add($directory)
            if ($state.Mode -eq 'SetupThrows') { throw 'Setup process failed to start' }
            if ($state.Mode -eq 'SetupFailure') {
                $state.Version = $null
                return 5
            }
            if ($state.Mode -eq 'PartialInstall') {
                $state.Version = & $convertAppVersion '1.0.12'
                return 5
            }
            if ($state.Mode -ne 'WrongVersion') { $state.Version = $state.Target }
            return 0
        }.GetNewClosure()
    }
    return [pscustomobject]@{ State = $state; Operations = $operations }
}

function Invoke-UpgradeFixture {
    param($Fixture, [string]$Cache = (Join-Path $testRoot ([guid]::NewGuid().ToString('N'))),
        [string]$InstallDirectory = 'fixture-install')
    return Invoke-AppUpgrade $InstallDirectory $Fixture.State.Target $Cache $Fixture.Operations
}

try {
    Test-Case 'automatic checks upgrade newer stable releases without prompts' {
        foreach ($mode in @('Portable', 'Offline', 'Current', 'Older', 'Newer', 'UpgradeFailure')) {
            $state = [pscustomobject]@{ Mode = $mode; Prompts = 0; Notices = 0; Upgrades = 0; Requests = 0 }
            $operations = @{
                ReadVersion = { param($directory)
                    if ($state.Mode -eq 'Portable') { return $null }
                    return [version]'1.0.21.0'
                }.GetNewClosure()
                GetRelease = { param($version)
                    $state.Requests++
                    if ($state.Mode -eq 'Offline') { throw 'offline' }
                    $value = switch ($state.Mode) { 'Current' { '1.0.21.0' }; 'Older' { '1.0.20.0' }; default { '1.0.22.0' } }
                    return [pscustomobject]@{ Version = [version]$value }
                }.GetNewClosure()
            }
            $prompt = { param($message) $state.Prompts++; return $true }.GetNewClosure()
            $notify = { param($message, $success) $state.Notices++ }.GetNewClosure()
            $upgrade = { param($version)
                $state.Upgrades++
                if ($version -ne [version]'1.0.22.0') { throw 'Wrong automatic target.' }
                if ($state.Mode -eq 'UpgradeFailure') { throw 'Upgrade failed.' }
            }.GetNewClosure()
            Invoke-AppUpdateCheck -Automatic -Operations $operations -Prompt $prompt -Notify $notify -StartUpgrade $upgrade
            Assert-Equal $state.Prompts 0 'Automatic updates never ask for consent'
            Assert-Equal $state.Notices 0 'A SYSTEM worker never opens a dialog'
            Assert-Equal $state.Upgrades ([int]($mode -in @('Newer', 'UpgradeFailure'))) 'Only a newer stable release starts setup'
            if ($mode -eq 'Portable') { Assert-Equal $state.Requests 0 'An unpacked worker cannot upgrade the installed app' }
        }
    }
    Test-Case 'numeric versions' {
        Assert-Equal ((ConvertTo-AppVersion 'v1.0.10') -gt (ConvertTo-AppVersion '1.0.9')) $true 'Numeric ordering'
        Assert-Equal (ConvertTo-AppVersion '1.0.11') (ConvertTo-AppVersion '1.0.11.0') 'Equivalent versions'
        Assert-Fails { ConvertTo-AppVersion '1.0.11-beta' }
    }
    Test-Case 'stable exact release asset' {
        $release = ConvertFrom-InstallerRelease (New-ReleaseFixture) (ConvertTo-AppVersion '1.0.11')
        Assert-Equal $release.Version (ConvertTo-AppVersion '1.0.11') 'Release version'
        foreach ($property in @('draft', 'prerelease')) {
            $fixture = New-ReleaseFixture
            $fixture.$property = $true
            Assert-Fails { ConvertFrom-InstallerRelease $fixture }
        }
        Assert-Fails { ConvertFrom-InstallerRelease (New-ReleaseFixture) (ConvertTo-AppVersion '1.0.12') }
    }
    Test-Case 'versioned asset matches each release tag and download URL' {
        foreach ($versionText in @('1.0.12', '1.0.13', '2.3.4')) {
            $fixture = New-ReleaseFixture $versionText
            $release = ConvertFrom-InstallerRelease $fixture (ConvertTo-AppVersion $versionText)
            Assert-Equal $release.Uri.AbsoluteUri (
                'https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix/releases/download/v' +
                $versionText + "/CeratopsKeyboardLayout-Setup-$versionText.exe") 'Versioned installer URL'
            $fixture.assets[0].name = 'CeratopsKeyboardLayout-Setup-9.9.9.exe'
            Assert-Fails { ConvertFrom-InstallerRelease $fixture }
        }
    }
    Test-Case 'unsafe or incomplete metadata' {
        foreach ($property in @('name', 'digest', 'browser_download_url', 'size')) {
            $fixture = New-ReleaseFixture
            $fixture.assets[0].$property = if ($property -eq 'size') { 256MB } else { 'untrusted' }
            Assert-Fails { ConvertFrom-InstallerRelease $fixture }
        }
        $fixture = New-ReleaseFixture
        $fixture.assets += $fixture.assets[0]
        Assert-Fails { ConvertFrom-InstallerRelease $fixture }
    }
    Test-Case 'real release JSON parsing' {
        $json = New-ReleaseFixture | ConvertTo-Json -Depth 4
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $script:NextResponse = [UpdateTestResponse]::new($bytes, $bytes.Length)
        Assert-Equal (Get-GitHubInstallerRelease '1.0.11').Version (ConvertTo-AppVersion '1.0.11') 'JSON release'
        $script:NextResponse = [UpdateTestResponse]::new((New-Object byte[] (1MB + 1)), -1)
        Assert-Fails { Get-GitHubInstallerRelease }
    }
    Test-Case 'streamed bytes and checksum' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('test installer')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $release = [pscustomobject]@{ Size = $bytes.Length; Digest = $digest; Uri = [uri]'https://github.com/fixture' }
        $script:NextResponse = [UpdateTestResponse]::new($bytes, -1)
        $package = Receive-ReleaseInstaller $release (Join-Path $testRoot 'accepted.exe')
        try {
            if ($env:OS -eq 'Windows_NT') {
                Assert-Fails { [IO.File]::WriteAllText($package.Path, 'replacement') }
                Assert-Fails { [IO.File]::Delete($package.Path) }
            }
        } finally { $package.Handle.Dispose() }
        $script:NextResponse = [UpdateTestResponse]::new($bytes, $bytes.Length + 1)
        Assert-Fails { Receive-ReleaseInstaller $release (Join-Path $testRoot 'wrong-size.exe') }
        $script:NextResponse = [UpdateTestResponse]::new($bytes[0..3], -1)
        Assert-Fails { Receive-ReleaseInstaller $release (Join-Path $testRoot 'truncated.exe') }
        $release.Digest = '0' * 64
        $script:NextResponse = [UpdateTestResponse]::new($bytes, -1)
        Assert-Fails { Receive-ReleaseInstaller $release (Join-Path $testRoot 'bad-hash.exe') }
        $release.Size = 3
        $script:NextResponse = [UpdateTestResponse]::new($bytes, -1)
        Assert-Fails { Receive-ReleaseInstaller $release (Join-Path $testRoot 'oversized.exe') }
    }
    Test-Case 'startup without installation, offline, current, older and declined' {
        foreach ($mode in @('Unregistered', 'Offline', 'Current', 'Older', 'Declined')) {
            $state = [pscustomobject]@{ Mode = $mode; Requests = 0; Prompts = 0; Installs = 0; Notices = 0 }
            $ops = @{
                ReadVersion = { param($directory)
                    if ($state.Mode -ne 'Unregistered') { return ConvertTo-AppVersion '1.0.10' }
                }
                GetRelease = { param($version)
                    $state.Requests++
                    if ($state.Mode -eq 'Offline') { throw 'Offline' }
                    $v = switch ($state.Mode) { Current { '1.0.10' }; Older { '1.0.9' }; default { '1.0.11' } }
                    return [pscustomobject]@{ Version = (ConvertTo-AppVersion $v) }
                }
            }
            Invoke-AppUpdateCheck 'fixture-install' $ops `
                { param($message) $state.Prompts++; return $false } { param($v) $state.Installs++ } `
                -Notify { param($message) $state.Notices++ }
            Assert-Equal $state.Installs 0 'No unwanted installations'
            Assert-Equal $state.Prompts ([int]($mode -eq 'Declined')) 'Only newer stable versions prompt'
            Assert-Equal $state.Notices 0 'Routine startup outcomes stay quiet'
            if ($mode -eq 'Unregistered') { Assert-Equal $state.Requests 0 'Portable copy does not access GitHub' }
        }
    }
    Test-Case 'startup consent hands off the exact release' {
        $state = [pscustomobject]@{ Version = $null }
        $ops = @{
            ReadVersion = { param($directory) ConvertTo-AppVersion '1.0.10' }
            GetRelease = { param($version) [pscustomobject]@{ Version = (ConvertTo-AppVersion '1.0.11') } }
        }
        Invoke-AppUpdateCheck 'fixture-install' $ops { param($message) return $true } `
            { param($version) $state.Version = $version }
        Assert-Equal $state.Version (ConvertTo-AppVersion '1.0.11') 'Approved version'
    }
    Test-Case 'manual check reports outcomes and keeps consent and upgrade handoff' {
        foreach ($mode in @('Unregistered', 'Offline', 'Current', 'Older', 'Declined', 'Accepted', 'WorkerFailure')) {
            $state = [pscustomobject]@{ Mode = $mode; Requests = 0; Prompts = 0; Installs = 0
                Notice = ''; Version = $null; Success = $false }
            $ops = @{
                ReadVersion = { param($directory)
                    if ($state.Mode -ne 'Unregistered') { return ConvertTo-AppVersion '1.0.10' }
                }
                GetRelease = { param($version)
                    $state.Requests++
                    if ($state.Mode -eq 'Offline') { throw 'Offline fixture' }
                    $v = switch ($state.Mode) { Current { '1.0.10' }; Older { '1.0.9' }; default { '1.0.11' } }
                    return [pscustomobject]@{ Version = (ConvertTo-AppVersion $v) }
                }
            }
            Invoke-AppUpdateCheck 'fixture-install' $ops `
                { param($message) $state.Prompts++; return $state.Mode -ne 'Declined' } `
                { param($version)
                    $state.Installs++; $state.Version = $version
                    if ($state.Mode -eq 'WorkerFailure') { throw 'Worker could not start' }
                } -Manual -Notify {
                    param($message, [bool]$success = $false)
                    $state.Notice = $message; $state.Success = $success
                }
            Assert-Equal $state.Prompts ([int]($mode -in @('Declined', 'Accepted', 'WorkerFailure'))) 'Only newer versions prompt'
            Assert-Equal $state.Installs ([int]($mode -in @('Accepted', 'WorkerFailure'))) 'No upgrade without consent'
            Assert-Equal $state.Success ($mode -in @('Current', 'Older')) 'Only a successful current-version check is green'
            if ($mode -eq 'Unregistered') {
                Assert-Equal $state.Requests 0 'Portable manual check does not access GitHub'
                Assert-Equal ($state.Notice.Contains('installed Ceratops')) $true 'Unregistered result shown'
            } elseif ($mode -eq 'Offline') {
                Assert-Equal ($state.Notice.StartsWith('Could not check for updates.')) $true 'Network failure shown'
            } elseif ($mode -in @('Current', 'Older')) {
                Assert-Equal $state.Notice 'Ceratops Keyboard Layout 1.0.10 is up to date.' 'Current version shown'
            } elseif ($mode -eq 'WorkerFailure') {
                Assert-Equal $state.Notice 'Upgrade failed. The current version was not changed.' 'Launch failure shown'
            } else {
                Assert-Equal $state.Notice '' 'No misleading extra outcome'
            }
            if ($state.Installs) {
                Assert-Equal $state.Version (ConvertTo-AppVersion '1.0.11') 'Exact approved release handed off'
            }
        }
    }
    Test-Case 'success notice interruption closes its dialog and fresh notices work' {
        & {
            $state = [pscustomobject]@{ Boundary = ''; Visible = $false; Shown = 0; Disposed = 0 }
            function New-UpdateSuccessDialog {
                param([string]$Text)
                $dialog = [pscustomobject]@{ State = $state }
                Add-Member -InputObject $dialog -MemberType ScriptMethod -Name ShowDialog -Value {
                    if ($this.State.Boundary -eq 'show-before') { throw 'notice-test-interruption' }
                    $this.State.Visible = $true; $this.State.Shown++
                    if ($this.State.Boundary -in @('show-after', 'close-before')) { throw 'notice-test-interruption' }
                    $this.State.Visible = $false
                    if ($this.State.Boundary -eq 'close-after') { throw 'notice-test-interruption' }
                    return 'OK'
                }
                Add-Member -InputObject $dialog -MemberType ScriptMethod -Name Dispose -Value {
                    $this.State.Visible = $false; $this.State.Disposed++
                }
                return $dialog
            }
            # Stop immediately on either side of opening and closing. The real
            # message owner must dispose a failed dialog; a fresh request builds
            # another one through the ordinary entrypoint, with no saved step.
            foreach ($boundary in @('show-before', 'show-after', 'close-before', 'close-after')) {
                $state.Boundary = $boundary
                $disposed = $state.Disposed
                Assert-Fails { Show-UpdateMessage 'Current version' -Success } 'notice-test-interruption'
                Assert-Equal $state.Visible $false 'Interrupted notice cannot leave a window open'
                Assert-Equal $state.Disposed ($disposed + 1) 'Interrupted dialog disposed'
                $state.Boundary = ''
                for ($repeat = 0; $repeat -lt 2; $repeat++) {
                    $shown = $state.Shown
                    Assert-Equal (Show-UpdateMessage 'Current version' -Success) $false 'Success notice is not upgrade consent'
                    Assert-Equal $state.Shown ($shown + 1) 'Fresh notice shown once'
                    Assert-Equal $state.Visible $false 'Fresh notice closes cleanly'
                }
            }
        }
    }
    Test-Case 'manual notice interruption keeps the installation and fresh check outcome' {
        $state = [pscustomobject]@{ Boundary = ''; Installs = 0; Prompts = 0
            Version = (ConvertTo-AppVersion '1.0.14'); Notices = [Collections.Generic.List[object]]::new() }
        $ops = @{
            ReadVersion = { param($directory) return $state.Version }
            GetRelease = { param($version) return [pscustomobject]@{ Version = $state.Version } }
        }
        $notice = {
            param($message, [bool]$success = $false)
            if ($success -and $state.Boundary -eq 'before') { throw 'notice-test-interruption' }
            $state.Notices.Add([pscustomobject]@{ Text = $message; Success = $success })
            if ($success -and $state.Boundary -eq 'after') { throw 'notice-test-interruption' }
        }
        foreach ($boundary in @('before', 'after')) {
            $state.Boundary = $boundary
            Invoke-AppUpdateCheck 'fixture-install' $ops { $state.Prompts++; return $true } `
                { $state.Installs++ } -Manual -Notify $notice
            $state.Boundary = ''
            for ($repeat = 0; $repeat -lt 2; $repeat++) {
                Invoke-AppUpdateCheck 'fixture-install' $ops { $state.Prompts++; return $true } `
                    { $state.Installs++ } -Manual -Notify $notice
                Assert-Equal $state.Notices[$state.Notices.Count - 1].Success $true 'Fresh current-version check succeeds'
                Assert-Equal $state.Notices[$state.Notices.Count - 1].Text `
                    'Ceratops Keyboard Layout 1.0.14 is up to date.' 'Fresh notice uses current inputs'
            }
            Assert-Equal $state.Version (ConvertTo-AppVersion '1.0.14') 'Notice interruption keeps the installed version'
            Assert-Equal $state.Installs 0 'No installation as notification recovery'
            Assert-Equal $state.Prompts 0 'No upgrade consent for a current version'
        }
    }
    Test-Case 'preparation failure preserves old installation' {
        foreach ($mode in @('DownloadFailure', 'BadNewPackage')) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = $mode
            Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Untouched' 'Preparation status'
            Assert-Equal (@($fixture.State.Calls | Where-Object { $_ -eq 'setup' }).Count) 0 'No setup started'
            Assert-Equal $fixture.State.Version (ConvertTo-AppVersion '1.0.10') 'Original version'
        }
    }
    Test-Case 'unpublished current version upgrades without rollback lookup' {
        $fixture = New-UpgradeFixture
        $fixture.State.Mode = 'UnpublishedCurrent'
        Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Upgraded' 'Upgrade status'
        Assert-Equal ($fixture.State.Calls -join ',') `
            'release:1.0.11,package:upgrade.exe,setup' 'Operation order'
        Assert-Equal $fixture.State.Version $fixture.State.Target 'Installed version'
        $calls = $fixture.State.Calls.Count
        Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Current' 'Repeated upgrade is current'
        Assert-Equal $fixture.State.Calls.Count $calls 'Repeated upgrade adds no effects'
    }
    Test-Case 'installer failure, exception and wrong version report incomplete installation' {
        foreach ($mode in @('SetupFailure', 'SetupThrows', 'WrongVersion', 'PartialInstall')) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = $mode
            $result = Invoke-UpgradeFixture $fixture
            Assert-Equal $result.Status 'InstallFailed' 'Post-setup status'
            Assert-Equal $fixture.State.Calls[$fixture.State.Calls.Count - 1] 'setup' 'Setup ran once'
            Assert-Equal (@($fixture.State.Calls | Where-Object { $_ -eq 'setup' }).Count) 1 'No rollback setup'
            Assert-Equal ((Get-UpgradeOutcomeMessage $result).Contains('installation may be incomplete')) `
                $true 'No unchanged-version claim after setup'
        }
    }
    Test-Case 'upgrade retains the current install directory' {
        $directory = Join-Path $testRoot 'custom installation'
        foreach ($mode in @('', 'SetupFailure')) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = $mode
            $result = Invoke-UpgradeFixture $fixture -InstallDirectory $directory
            $expected = if ($mode) { 'InstallFailed' } else { 'Upgraded' }
            Assert-Equal $result.Status $expected 'Custom installation outcome'
            Assert-Equal $fixture.State.InstallDirectories.Count 1 'One installer ran'
            foreach ($actual in $fixture.State.InstallDirectories) {
                Assert-Equal $actual $directory 'Installer retains the registered directory'
            }
        }
    }
    Test-Case 'installer command passes the custom directory as one argument' {
        & {
            # Replace only process creation; exercise the production launch code.
            # This child scope restores the real command before later checks.
            function Start-Process {
                param([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
                $script:InstallerInvocation = [pscustomobject]@{ Path = $FilePath; Arguments = $ArgumentList }
                $process = [pscustomobject]@{ ExitCode = 0 }
                Add-Member -InputObject $process -MemberType ScriptMethod -Name WaitForExit -Value {}
                Add-Member -InputObject $process -MemberType ScriptMethod -Name Dispose -Value {}
                return $process
            }
            $directory = Join-Path $testRoot 'custom installation'
            $operations = Get-UpdateOperations
            Assert-Equal (& $operations.RunSetup 'fixture.exe' $directory) 0 'Setup exit code'
            Assert-Equal $script:InstallerInvocation.Path 'fixture.exe' 'Exact installer path'
            Assert-Equal ($script:InstallerInvocation.Arguments.Contains(' /DIR="' + $directory + '"')) `
                $true 'Quoted directory reaches the installer process'
            Assert-Fails { Invoke-InstallerProcess 'fixture.exe' 'unsafe"directory' }
        }
    }
    Test-Case 'concurrent newer install cannot be downgraded' {
        $fixture = New-UpgradeFixture
        $fixture.State.Version = ConvertTo-AppVersion '1.0.12'
        Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Current' 'No downgrade'
        Assert-Equal $fixture.State.Calls.Count 0 'No downloads or installers'
        $fixture = New-UpgradeFixture
        $fixture.State.Mode = 'ConcurrentInstall'
        Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Untouched' 'Changed baseline stops setup'
        Assert-Equal (@($fixture.State.Calls | Where-Object { $_ -eq 'setup' }).Count) 0 'No concurrent overwrite'
    }
    Test-Case 'failure notices are explicit' {
        foreach ($status in @('Untouched', 'InstallFailed')) {
            $result = [pscustomobject]@{ Status = $status; Detail = 'fixture error' }
            $message = Get-UpgradeOutcomeMessage $result
            Assert-Equal ($message.StartsWith('Upgrade failed')) $true 'Visible failure notice'
            if ($status -eq 'InstallFailed') {
                Assert-Equal ($message.Contains('/releases')) $true 'Manual installer location shown'
            }
        }
        Assert-Equal (Get-UpgradeOutcomeMessage ([pscustomobject]@{ Status = 'Upgraded' })) '' 'No false failure notice'
    }
    Test-Case 'cache cleanup preserves older manual recovery until success' {
        $cache = Join-Path $testRoot 'cache'
        $foreign = Join-Path $cache 'unrelated'
        $null = [IO.Directory]::CreateDirectory($foreign)
        $orphan = Join-Path $cache ('attempt-' + ('a' * 32))
        $null = [IO.Directory]::CreateDirectory($orphan)
        [IO.File]::WriteAllText((Join-Path $orphan 'recovery.txt'), 'stale recovery')
        [IO.File]::WriteAllText((Join-Path $orphan 'previous.exe'), 'older installer')
        $abandoned = Join-Path $cache ('attempt-' + ('b' * 32))
        $null = [IO.Directory]::CreateDirectory($abandoned)
        for ($i = 0; $i -lt 3; $i++) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = 'SetupFailure'
            $result = Invoke-UpgradeFixture $fixture $cache
            Assert-Equal $result.Status 'InstallFailed' 'Honest setup failure'
            Assert-Equal (@(Get-ChildItem -LiteralPath $cache -Directory -Filter 'attempt-*').Count) 1 'One older recovery retained'
            Assert-Equal ([IO.File]::Exists((Join-Path $orphan 'previous.exe'))) $true 'Older installer retained on failure'
        }
        Assert-Equal ([IO.Directory]::Exists($abandoned)) $false 'Abandoned download removed'
        Assert-Equal ([IO.Directory]::Exists($foreign)) $true 'Unrelated directory retained'
        $fixture = New-UpgradeFixture
        Assert-Equal (Invoke-UpgradeFixture $fixture $cache).Status 'Upgraded' 'Later success'
        Assert-Equal (@(Get-ChildItem -LiteralPath $cache -Directory -Filter 'attempt-*').Count) 0 'Download removed after success'
        Assert-Equal ([IO.Directory]::Exists($orphan)) $false 'Older recovery removed after success'
    }
    if ($env:OS -eq 'Windows_NT') {
        Test-Case 'successful check dialog has a green check and keyboard dismissal' {
            $text = 'Ceratops Keyboard Layout 1.0.13 is up to date.'
            $dialog = New-UpdateSuccessDialog $text
            try {
                $dialog.Show()
                [Windows.Forms.Application]::DoEvents()
                $mark = $dialog.Controls.Find('SuccessMark', $true)[0]
                $message = $dialog.Controls.Find('UpdateMessage', $true)[0]
                Assert-Equal $mark.Text ([string][char]0x2713) 'Success check glyph'
                Assert-Equal $mark.ForeColor.ToArgb() ([Drawing.Color]::ForestGreen.ToArgb()) 'Green success color'
                Assert-Equal $message.Text $text 'Version message retained'
                Assert-Equal ($mark.Right -le $message.Left) $true 'Check does not overlap message'
                Assert-Equal ($message.Right -le $dialog.ClientSize.Width) $true 'Message fits the dialog'
                Assert-Equal $dialog.AcceptButton.Text 'OK' 'Enter dismisses the notice'
                Assert-Equal ($dialog.CancelButton -eq $dialog.AcceptButton) $true 'Escape dismisses the notice'
            } finally { $dialog.Dispose() }
        }
        Test-Case 'cache links are refused without touching their targets' {
            $cache = Join-Path $testRoot 'linked-cache'
            $target = Join-Path $testRoot 'link-target'
            $null = [IO.Directory]::CreateDirectory($cache)
            $null = [IO.Directory]::CreateDirectory($target)
            $sentinel = Join-Path $target 'unrelated.txt'
            [IO.File]::WriteAllText($sentinel, 'keep')
            $link = Join-Path $cache ('attempt-' + ('b' * 32))
            $null = New-Item -ItemType Junction -Path $link -Target $target
            try {
                Assert-Fails { New-UpdateAttempt $cache }
                Assert-Fails { Remove-UpdateAttempts $cache '' }
                Assert-Equal ([IO.File]::ReadAllText($sentinel)) 'keep' 'Link target retained'
            } finally { [IO.Directory]::Delete($link) }
        }
        Test-Case 'busy and abandoned updater locks' {
            $name = 'Local\CeratopsUpdateTest-' + [guid]::NewGuid().ToString('N')
            $ready = Join-Path $testRoot 'mutex-ready'
            $childScript = Join-Path $testRoot 'Hold-TestMutex.ps1'
            [IO.File]::WriteAllText($childScript, @'
param([string]$Name, [string]$ReadyPath)
$mutex = [Threading.Mutex]::new($false, $Name)
try {
    $null = $mutex.WaitOne()
    [IO.File]::WriteAllText($ReadyPath, 'ready')
    [Threading.Thread]::Sleep(15000)
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
'@)
            $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Name "{1}" -ReadyPath "{2}"' -f
                $childScript, $name, $ready
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $observer = $null
            try {
                $deadline = [Diagnostics.Stopwatch]::StartNew()
                while (-not [IO.File]::Exists($ready) -and $deadline.Elapsed.TotalSeconds -lt 5) {
                    [Threading.Thread]::Sleep(25)
                }
                Assert-Equal ([IO.File]::Exists($ready)) $true 'Child owns lock'
                Assert-Equal (Enter-UpdateMutex $name) $null 'Concurrent updater refused'
                $observer = [Threading.Mutex]::OpenExisting($name)
                $process.Kill(); $process.WaitForExit()
                $mutex = Enter-UpdateMutex $name
                Assert-Equal ($null -ne $mutex) $true 'Abandoned lock recovered'
                $mutex.ReleaseMutex(); $mutex.Dispose()
            } finally {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                $process.Dispose()
                if ($null -ne $observer) { $observer.Dispose() }
            }
        }
        Test-Case 'updater log writer outcomes and interrupted effects' {
            $directory = Join-Path $testRoot '_log-writer'
            $null = [IO.Directory]::CreateDirectory($directory)
            $runtime = Join-Path $directory 'CeratopsKeyboardLayout.exe'
            $original = Join-Path (Split-Path $PSScriptRoot -Parent) 'CeratopsKeyboardLayout.exe'
            [IO.File]::Copy($original, $runtime)
            [IO.File]::WriteAllText((Join-Path $directory 'Write-AppEventLog.ahk'), '; fixture presence')
            [IO.File]::WriteAllText((Join-Path $directory 'CeratopsKeyboardLayout-Service.ahk'), @'
#Requires AutoHotkey v2.0.19+
#SingleInstance Off
#NoTrayIcon
code := Integer(A_Args[4])
if code = 11 {
    FileAppend("fixture stdout", "*")
    FileAppend("fixture stderr", "**")
    ExitApp(7)
}
if code = 13
    Sleep(30000)
FileAppend(code "`n", A_ScriptDir "\_events.txt")
ExitApp(code = 12 ? 7 : 0)
'@)
            $previous = $script:AppUpdateLogEnabled
            $script:AppUpdateLogEnabled = $true
            try {
                foreach ($code in @(0, 0, 11, 12, 13)) {
                    $warnings = @()
                    $result = @(Write-AppUpdateEvent INFO test.writer $code $directory `
                        -WarningVariable warnings -WarningAction SilentlyContinue)
                    Assert-Equal $result.Count 0 'Logging does not alter the updater result'
                    Assert-Equal @($warnings).Count ([int]($code -ne 0)) 'Writer failure warning count'
                    if ($code -ne 0) {
                        $message = [string]$warnings[0]
                        if (-not $message.Contains($runtime) -or -not $message.Contains('--write-event INFO test.writer') -or
                            -not $message.Contains('exit=') -or -not $message.Contains('stdout=') -or -not $message.Contains('stderr=')) {
                            throw "Writer failure lost command diagnostics: $message"
                        }
                        if ($code -eq 11 -and (-not $message.Contains('fixture stdout') -or -not $message.Contains('fixture stderr'))) {
                            throw 'Writer failure lost child output streams.'
                        }
                        if ($code -eq 13 -and -not $message.Contains('timed out')) { throw 'Stuck writer was not bounded.' }
                        # A new call after either side of a record effect succeeds.
                        Write-AppUpdateEvent INFO test.writer 0 $directory
                    }
                }
                [IO.File]::Delete($runtime)
                $warnings = @()
                Write-AppUpdateEvent INFO test.writer 0 $directory -WarningVariable warnings -WarningAction SilentlyContinue
                Assert-Equal @($warnings).Count 1 'Missing runtime reports a launch failure'
                [IO.File]::Copy($original, $runtime)
                Write-AppUpdateEvent INFO test.writer 0 $directory
                Assert-Equal ([IO.File]::ReadAllLines((Join-Path $directory '_events.txt')).Length) 7 'Fresh calls complete after interruptions'
            } finally { $script:AppUpdateLogEnabled = $previous }
        }
        Test-Case 'native service thread process lookup' {
            $repositoryRoot = Split-Path $PSScriptRoot -Parent
            $runtime = Join-Path $repositoryRoot 'CeratopsKeyboardLayout.exe'
            $probeScript = Join-Path $testRoot '_check-service-thread.ahk'
            $probeSource = @'
#Requires AutoHotkey v2.0.19+
#Include __SERVICE_SCRIPT__
nativeFailure := ""
ReadProcessesOnNativeThread(boundary) {
    global nativeFailure
    ownsApartment := false, interrupted := false
    apartment := 0, qualifier := 0
    try {
        if DllCall("ole32\CoGetApartmentType", "Int*", &apartment, "Int*", &qualifier, "Int") != -2147221008
            throw Error("The native test thread must initially have no COM apartment")
        if boundary = 1
            throw Error("service-thread-test-interruption")
        ownsApartment := InitializeServiceThreadCom()
        if !ownsApartment
            throw Error("The service did not initialize the native thread")
        if boundary = 2
            throw Error("service-thread-test-interruption")
        Loop 2 {
            found := false
            for process in ReadRunningAppProcesses() {
                if process.Pid = DllCall("GetCurrentProcessId", "UInt")
                    found := true
            }
            if !found
                throw Error("The native service lookup did not find its own process")
        }
        if boundary = 3
            throw Error("service-thread-test-interruption")
    } catch Error as failure {
        if boundary && failure.Message = "service-thread-test-interruption"
            interrupted := true
        else
            nativeFailure := failure.Message
    } finally {
        if ownsApartment
            DllCall("ole32\CoUninitialize")
    }
    if boundary && !interrupted
        nativeFailure := "The requested interruption did not occur"
    if DllCall("ole32\CoGetApartmentType", "Int*", &apartment, "Int*", &qualifier, "Int") != -2147221008
        nativeFailure := "The native service thread leaked its COM apartment"
    return 0
}
try {
    callback := CallbackCreate(ReadProcessesOnNativeThread, , 1)
    for boundary in [0, 1, 2, 3] {
        nativeThreadHandle := DllCall("CreateThread", "Ptr", 0, "UPtr", 0, "Ptr", callback,
            "Ptr", boundary, "UInt", 0, "Ptr", 0, "Ptr")
        if !nativeThreadHandle
            throw OSError()
        try {
            if DllCall("WaitForSingleObject", "Ptr", nativeThreadHandle, "UInt", 10000, "UInt") != 0
                throw Error("The native service lookup timed out")
        } finally DllCall("CloseHandle", "Ptr", nativeThreadHandle)
        if nativeFailure != ""
            throw Error(nativeFailure)
    }
    CallbackFree(callback) ; Every native thread has exited before freeing code.
    FileAppend("PASS native service lookups, repeated calls and interruption cleanup`n", "*")
    ExitApp(0)
} catch Error as failure {
    FileAppend("FAIL native service thread: " failure.Message "`n", "**")
    ExitApp(1) ; Process exit also retires a timed-out callback without freeing live code.
}
'@
            [IO.File]::WriteAllText($probeScript, $probeSource.Replace('__SERVICE_SCRIPT__',
                (Join-Path $repositoryRoot 'CeratopsKeyboardLayout-Service.ahk')))
            $arguments = '/ErrorStdOut=UTF-8 "{0}"' -f $probeScript
            $process = [Diagnostics.Process]::new()
            $process.StartInfo.FileName = $runtime
            $process.StartInfo.Arguments = $arguments
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            try {
                $null = $process.Start()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $timedOut = -not $process.WaitForExit(20000)
                if ($timedOut) { $process.Kill(); $null = $process.WaitForExit(5000) }
                $output = $stdout.GetAwaiter().GetResult()
                $errors = $stderr.GetAwaiter().GetResult()
                if ($timedOut -or $process.ExitCode -ne 0) {
                    throw ('Command: "{0}" {1}; Exit: {2}; Timed out: {3}; stdout: {4}; stderr: {5}' -f
                        $runtime, $arguments, $process.ExitCode, $timedOut,
                        $(if ($output) { $output } else { '<absent>' }),
                        $(if ($errors) { $errors } else { '<absent>' }))
                }
                Assert-Equal ($output.Contains('PASS native service lookups')) $true 'Native thread completed'
            } finally { $process.Dispose() }
        }
        Test-Case 'bounded operational logs' {
            $repositoryRoot = Split-Path $PSScriptRoot -Parent
            $runtime = Join-Path $repositoryRoot 'CeratopsKeyboardLayout.exe'
            $test = Join-Path $PSScriptRoot 'Test-ShortcutKeys.ahk'
            $arguments = '/ErrorStdOut=UTF-8 "{0}" "{1}" --diagnostics-only' -f $test, $testRoot
            $process = [Diagnostics.Process]::new()
            $process.StartInfo.FileName = $runtime
            $process.StartInfo.Arguments = $arguments
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            try {
                $null = $process.Start()
                if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Log checks timed out.' }
                if ($process.ExitCode -ne 0) {
                    throw "Log checks failed: $runtime $arguments (exit $($process.ExitCode)); stdout=$($process.StandardOutput.ReadToEnd()); stderr=$($process.StandardError.ReadToEnd())"
                }
            } finally { $process.Dispose() }
        }
        Test-Case 'Windows can execute an accepted file while writes are denied' {
            $path = Join-Path $testRoot 'locked-command.exe'
            [IO.File]::Copy((Join-Path $env:WINDIR 'System32\cmd.exe'), $path)
            $bytes = [IO.File]::ReadAllBytes($path)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $package = Open-CheckedInstaller $path ([pscustomobject]@{ Size = $bytes.Length; Digest = $digest })
            try {
                $process = Start-Process -FilePath $path -ArgumentList '/c exit 7' -WindowStyle Hidden -PassThru
                try { $process.WaitForExit(); Assert-Equal $process.ExitCode 7 'Locked executable exit' }
                finally { $process.Dispose() }
            } finally { $package.Handle.Dispose() }
        }
        Test-Case 'ordinary relaunch and fresh launch after interruption' {
            # Include the production script without running its tray startup. The
            # workers use the same script path, so its real singleton policy
            # decides whether the second launch can disturb the first.
            $repositoryRoot = Split-Path $PSScriptRoot -Parent
            $runtime = Join-Path $repositoryRoot 'CeratopsKeyboardLayout.exe'
            $appScript = Join-Path $repositoryRoot 'CeratopsKeyboardLayout.ahk'
            $probeScript = Join-Path $testRoot '_single-instance-probe.ahk'
            $ready = Join-Path $testRoot '_single-instance-ready-'
            [IO.File]::WriteAllText($probeScript, (@'
#Requires AutoHotkey v2.0.19+
#Include {0}
marker := A_Args[1] DllCall("GetCurrentProcessId", "UInt")
FileAppend(DllCall("GetCurrentProcessId", "UInt") "`n", marker ".tmp")
FileMove(marker ".tmp", marker ".done")
Sleep(30000)
'@ -f $appScript))
            $arguments = '/ErrorStdOut=UTF-8 "{0}" "{1}"' -f $probeScript, $ready
            $workers = [Collections.Generic.List[Diagnostics.Process]]::new()
            try {
                $first = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru
                $workers.Add($first)
                # Each child publishes its own marker only after closing the file.
                # Readers never open the live writer's file or a partial record.
                $firstReady = '{0}{1}.done' -f $ready, $first.Id
                $deadline = [Diagnostics.Stopwatch]::StartNew()
                while ((-not [IO.File]::Exists($firstReady)) -and $deadline.Elapsed.TotalSeconds -lt 10) {
                    [Threading.Thread]::Sleep(25)
                }
                Assert-Equal ([IO.File]::Exists($firstReady)) $true 'First companion started'
                Assert-Equal ([IO.File]::ReadAllLines($firstReady).Length) 1 'First companion reached its body'

                foreach ($attempt in 1..2) {
                    $duplicate = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru
                    $workers.Add($duplicate)
                    Assert-Equal ($duplicate.WaitForExit(10000)) $true "Duplicate $attempt exited"
                    $first.Refresh()
                    Assert-Equal $first.HasExited $false "Duplicate $attempt preserved the first companion"
                    Assert-Equal ([IO.Directory]::GetFiles($testRoot, '_single-instance-ready-*.done').Length) 1 "Duplicate $attempt skipped startup"
                }

                # Recovery is tested through the service owner's exact-path kill
                # checks in Test-ShortcutKeys. This fixture checks the singleton.
                $first.Kill(); $first.WaitForExit()
                $replacement = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru
                $workers.Add($replacement)
                $replacementReady = '{0}{1}.done' -f $ready, $replacement.Id
                $deadline.Restart()
                while ((-not [IO.File]::Exists($replacementReady)) -and $deadline.Elapsed.TotalSeconds -lt 10) {
                    [Threading.Thread]::Sleep(25)
                }
                Assert-Equal ([IO.File]::Exists($replacementReady)) $true 'Fresh companion started after interruption'
                Assert-Equal ([IO.File]::ReadAllLines($replacementReady).Length) 1 'Fresh companion reached its body'
                $replacement.Refresh()
                Assert-Equal $replacement.HasExited $false 'Fresh companion remains active'
                $duplicate = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru
                $workers.Add($duplicate)
                Assert-Equal ($duplicate.WaitForExit(10000)) $true 'Fresh companion rejects a repeat launch'
                $replacement.Refresh()
                Assert-Equal $replacement.HasExited $false 'Repeat launch preserves fresh companion'
                Assert-Equal ([IO.Directory]::GetFiles($testRoot, '_single-instance-ready-*.done').Length) 2 'Repeat launch skipped startup'
            } finally {
                foreach ($worker in $workers) {
                    $worker.Refresh()
                    if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }
                    $worker.Dispose()
                }
            }
        }
    }
    Write-Output "PASS: $script:Passed update checks"
} finally {
    Assert-PlainDirectoryTree $testRoot
    [IO.Directory]::Delete($testRoot, $true)
}

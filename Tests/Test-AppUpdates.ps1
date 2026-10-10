# Noninteractive update checks: real release parsing, locked package acceptance,
# cache ownership and transaction behavior, with HTTP/setup boundaries substituted.
# No Windows installation, service, GitHub release or user clipboard is changed.
[CmdletBinding()]
param([string]$TempRoot)

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
    param([scriptblock]$Operation)
    $failed = $false
    try { & $Operation | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'The unsafe operation was accepted.' }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Operation)
    try { & $Operation; $script:Passed++ }
    catch { throw "${Name}: $($_.Exception.Message)" }
}

function New-ReleaseFixture {
    param([string]$Version = '1.0.11')
    return [pscustomobject]@{
        tag_name = 'v' + $Version; draft = $false; prerelease = $false
        assets = @([pscustomobject]@{
            name = 'CeratopsKeyboardLayout-Setup.exe'; size = 12
            digest = 'sha256:' + ('a' * 64)
            browser_download_url = 'https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix/releases/download/v' +
                $Version + '/CeratopsKeyboardLayout-Setup.exe'
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
    $state = [pscustomobject]@{
        Version = (ConvertTo-AppVersion '1.0.10'); Target = (ConvertTo-AppVersion '1.0.11')
        Calls = [Collections.Generic.List[string]]::new(); Mode = ''; Reads = 0
    }
    $operations = @{
        ReadVersion = {
            param($directory)
            $state.Reads++
            if ($state.Mode -eq 'ConcurrentInstall' -and $state.Reads -gt 1) {
                $state.Version = ConvertTo-AppVersion '1.0.12'
            }
            return $state.Version
        }.GetNewClosure()
        GetRelease = {
            param($version)
            $state.Calls.Add("release:$version")
            if ($state.Mode -eq 'MissingRollback' -and $version -eq '1.0.10') { throw 'Release missing' }
            return [pscustomobject]@{ Version = (ConvertTo-AppVersion $version) }
        }.GetNewClosure()
        GetPackage = {
            param($release, $path)
            $state.Calls.Add('package:' + [IO.Path]::GetFileName($path))
            if ($state.Mode -eq 'DownloadFailure') { throw 'Download failed' }
            $bytes = [Text.Encoding]::UTF8.GetBytes((Get-AppVersionText $release.Version))
            [IO.File]::WriteAllBytes($path, $bytes)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $release | Add-Member Digest ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant())
                $release | Add-Member Size $bytes.Length
            } finally { $sha.Dispose() }
            if ($state.Mode -eq 'BadNewPackage' -and $release.Version -eq $state.Target) {
                $release.Digest = '0' * 64
            }
            return Open-CheckedInstaller $path $release
        }.GetNewClosure()
        RunSetup = {
            param($path, $recovery)
            $state.Calls.Add('setup:' + $recovery)
            if ($recovery) {
                if ($state.Mode -eq 'RecoveryFailure') { return 5 }
                $state.Version = ConvertTo-AppVersion '1.0.10'
                return 0
            }
            if ($state.Mode -eq 'SetupThrows') { throw 'Setup process failed to start' }
            if ($state.Mode -eq 'SetupFailure' -or $state.Mode -eq 'RecoveryFailure') {
                $state.Version = $null
                return 5
            }
            if ($state.Mode -ne 'WrongVersion') { $state.Version = $state.Target }
            return 0
        }.GetNewClosure()
    }
    return [pscustomobject]@{ State = $state; Operations = $operations }
}

function Invoke-UpgradeFixture {
    param($Fixture, [string]$Cache = (Join-Path $testRoot ([guid]::NewGuid().ToString('N'))))
    return Invoke-AppUpgrade 'fixture-install' $Fixture.State.Target $Cache $Fixture.Operations
}

try {
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
            $state = [pscustomobject]@{ Mode = $mode; Requests = 0; Prompts = 0; Installs = 0 }
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
            Invoke-StartupUpdateCheck 'fixture-install' $ops `
                { param($message) $state.Prompts++; return $false } { param($v) $state.Installs++ }
            Assert-Equal $state.Installs 0 'No unwanted installations'
            Assert-Equal $state.Prompts ([int]($mode -eq 'Declined')) 'Only newer stable versions prompt'
            if ($mode -eq 'Unregistered') { Assert-Equal $state.Requests 0 'Portable copy does not access GitHub' }
        }
    }
    Test-Case 'startup consent hands off the exact release' {
        $state = [pscustomobject]@{ Version = $null }
        $ops = @{
            ReadVersion = { param($directory) ConvertTo-AppVersion '1.0.10' }
            GetRelease = { param($version) [pscustomobject]@{ Version = (ConvertTo-AppVersion '1.0.11') } }
        }
        Invoke-StartupUpdateCheck 'fixture-install' $ops { param($message) return $true } `
            { param($version) $state.Version = $version }
        Assert-Equal $state.Version (ConvertTo-AppVersion '1.0.11') 'Approved version'
    }
    Test-Case 'preparation failure preserves old installation' {
        foreach ($mode in @('MissingRollback', 'DownloadFailure', 'BadNewPackage')) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = $mode
            Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Untouched' 'Preparation status'
            Assert-Equal (@($fixture.State.Calls | Where-Object { $_ -like 'setup:*' }).Count) 0 'No setup started'
            Assert-Equal $fixture.State.Version (ConvertTo-AppVersion '1.0.10') 'Original version'
        }
    }
    Test-Case 'success prepares recovery before changing anything' {
        $fixture = New-UpgradeFixture
        Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Upgraded' 'Upgrade status'
        Assert-Equal ($fixture.State.Calls -join ',') `
            'release:1.0.10,release:1.0.11,package:previous.exe,package:upgrade.exe,setup:False' 'Operation order'
        Assert-Equal $fixture.State.Version $fixture.State.Target 'Installed version'
    }
    Test-Case 'installer failure, exception and wrong version recover' {
        foreach ($mode in @('SetupFailure', 'SetupThrows', 'WrongVersion')) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = $mode
            Assert-Equal (Invoke-UpgradeFixture $fixture).Status 'Restored' 'Recovery status'
            Assert-Equal $fixture.State.Calls[$fixture.State.Calls.Count - 1] 'setup:True' 'Recovery ran'
            Assert-Equal $fixture.State.Version (ConvertTo-AppVersion '1.0.10') 'Previous version restored'
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
        Assert-Equal (@($fixture.State.Calls | Where-Object { $_ -like 'setup:*' }).Count) 0 'No concurrent overwrite'
    }
    Test-Case 'failure notices are explicit' {
        foreach ($status in @('Untouched', 'Restored', 'RecoveryFailed')) {
            $result = [pscustomobject]@{ Status = $status; Detail = 'fixture error'; RecoveryPath = 'saved-previous.exe' }
            $message = Get-UpgradeOutcomeMessage $result
            Assert-Equal ($message.StartsWith('Upgrade failed')) $true 'Visible failure notice'
            if ($status -eq 'RecoveryFailed') {
                Assert-Equal ($message.Contains('saved-previous.exe')) $true 'Recovery location shown'
            }
        }
        Assert-Equal (Get-UpgradeOutcomeMessage ([pscustomobject]@{ Status = 'Upgraded' })) '' 'No false failure notice'
    }
    Test-Case 'cache retention and recovery failure' {
        $cache = Join-Path $testRoot 'cache'
        $foreign = Join-Path $cache 'unrelated'
        $null = [IO.Directory]::CreateDirectory($foreign)
        $orphan = Join-Path $cache ('attempt-' + ('a' * 32))
        $null = [IO.Directory]::CreateDirectory($orphan)
        for ($i = 0; $i -lt 3; $i++) {
            $fixture = New-UpgradeFixture
            $fixture.State.Mode = 'RecoveryFailure'
            $result = Invoke-UpgradeFixture $fixture $cache
            Assert-Equal $result.Status 'RecoveryFailed' 'Honest recovery failure'
            Assert-Equal ([IO.File]::Exists($result.RecoveryPath)) $true 'Previous installer retained'
            Assert-Equal (@(Get-ChildItem -LiteralPath $cache -Directory -Filter 'attempt-*').Count) 1 'Bounded recovery attempts'
        }
        Assert-Equal ([IO.Directory]::Exists($orphan)) $false 'Abandoned attempt removed'
        Assert-Equal ([IO.Directory]::Exists($foreign)) $true 'Unrelated directory retained'
        $fixture = New-UpgradeFixture
        Assert-Equal (Invoke-UpgradeFixture $fixture $cache).Status 'Upgraded' 'Later success'
        Assert-Equal (@(Get-ChildItem -LiteralPath $cache -Directory -Filter 'attempt-*').Count) 0 'Recovery removed after success'
    }
    if ($env:OS -eq 'Windows_NT') {
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
    }
    Write-Output "PASS: $script:Passed update checks"
} finally {
    Assert-PlainDirectoryTree $testRoot
    [IO.Directory]::Delete($testRoot, $true)
}

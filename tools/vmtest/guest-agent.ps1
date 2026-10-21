<#
    Guest side of tools\vmtest.ps1. Runs inside the VM under Windows PowerShell 5.1, launched by
    `VBoxManage guestcontrol run` (a medium-integrity, UAC-filtered token).

    Every mode except Status needs admin, so the medium-token invocation re-launches itself with
    `Start-Process -Verb RunAs` (silent when ConsentPromptBehaviorAdmin=0, i.e. the UAC slider is at
    "Never notify"; a filtered token has no other prompt-free way up) and relays the elevated
    result. Jobs (the AME apply, the optional revert) run from a scheduled task this script
    registers itself: RunLevel Highest, Interactive logon as the signed-in user, so AME's
    `runas: currentUserElevated` steps and HKCU land in the real desktop session.

    Protocol: results are printed as JSON between VMTEST_JSON_BEGIN/END, then VMTEST_EXIT=<n>.
    guestcontrol's own exit code is not the guest exit code, so the host only trusts these lines.

    Keep this file ASCII-only (PS 5.1 reads BOM-less files as ANSI), avoid aliases, and do not use
    $Matches (use [regex]::Match results instead).
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Start', 'Status', 'Stop', 'Collect')]
    [string]$Mode,
    [ValidateSet('apply', 'revert')]
    [string]$Job = 'apply',
    [string]$Root = 'C:\vmtest',
    [switch]$NoDefenderRemediation,
    [switch]$Elevated,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$inDir = Join-Path $Root 'in'
$stateDir = Join-Path $Root 'state'
$jobsDir = Join-Path $Root 'jobs'
$cliDir = Join-Path $Root 'cli'
$pbDir = Join-Path $Root 'pb'

function Write-VmtResult {
    param([hashtable]$Result, [int]$ExitCode)
    $json = ConvertTo-Json -InputObject $Result -Depth 6
    if ($ResultFile) {
        [IO.File]::WriteAllText($ResultFile, $json, [Text.Encoding]::UTF8)
    }
    else {
        [Console]::Out.WriteLine('VMTEST_JSON_BEGIN')
        [Console]::Out.WriteLine($json)
        [Console]::Out.WriteLine('VMTEST_JSON_END')
        [Console]::Out.WriteLine("VMTEST_EXIT=$ExitCode")
    }
    exit $ExitCode
}

function Test-VmtElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VmtRegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

# Mirrors TrustedUninstaller.CLI's GetDefenderToggles (trusted-uninstaller-cli,
# TrustedUninstaller.CLI/CLI.cs): any toggle still "on" makes the CLI loop on Console.ReadKey.
function Get-VmtDefenderToggles {
    $def = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'

    $rt = Get-VmtRegValue "$pol\Real-Time Protection" 'DisableRealtimeMonitoring'
    if ($null -eq $rt) { $rt = Get-VmtRegValue "$def\Real-Time Protection" 'DisableRealtimeMonitoring' }

    $spynetPath = if (Test-Path -LiteralPath "$pol\SpyNet") { "$pol\SpyNet" } else { "$def\SpyNet" }
    $reporting = Get-VmtRegValue $spynetPath 'SpyNetReporting'
    if ($null -eq $reporting) { $reporting = Get-VmtRegValue "$def\SpyNet" 'SpyNetReporting' }
    $consent = Get-VmtRegValue $spynetPath 'SubmitSamplesConsent'
    if ($null -eq $consent) { $consent = Get-VmtRegValue "$def\SpyNet" 'SubmitSamplesConsent' }
    $tamper = Get-VmtRegValue "$def\Features" 'TamperProtection'

    $state = [ordered]@{
        realtimeOn = ($rt -ne 1)
        cloudOn    = ($null -ne $reporting -and $reporting -ne 0)
        samplesOn  = ($null -ne $consent -and @(0, 2, 4) -notcontains $consent)
        tamperOn   = ($null -ne $tamper -and @(0, 4) -notcontains $tamper)
        msMpEng    = [bool](Get-Process -Name 'MsMpEng' -ErrorAction SilentlyContinue)
    }
    $state.anyOn = ($state.realtimeOn -or $state.cloudOn -or $state.samplesOn -or $state.tamperOn)
    return $state
}

function Get-VmtInteractiveUser {
    $owners = @()
    foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'")) {
        $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner
        if ($owner.ReturnValue -eq 0) { $owners += "$($owner.Domain)\$($owner.User)" }
    }
    return @($owners | Select-Object -Unique)
}

function Copy-VmtFileShared {
    # Copy-Item fails on files AME still holds open; read with FileShare.ReadWrite instead.
    param([string]$Source, [string]$Destination)
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $out = [IO.File]::Create($Destination)
        try { $in.CopyTo($out) } finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
}

function Copy-VmtTree {
    param([string]$Source, [string]$Destination, [System.Collections.ArrayList]$Errors)
    if (-not (Test-Path -LiteralPath $Source)) { return 0 }
    $count = 0
    $base = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $file.FullName.Substring($base.Length).TrimStart('\')
        try {
            Copy-VmtFileShared -Source $file.FullName -Destination (Join-Path $Destination $rel)
            $count++
        }
        catch { [void]$Errors.Add("$($file.FullName): $($_.Exception.Message)") }
    }
    return $count
}

function Get-VmtJobPaths {
    param([string]$Name)
    $dir = Join-Path $jobsDir $Name
    return @{
        Dir      = $dir
        Cmd      = Join-Path $dir 'run.cmd'
        Stdout   = Join-Path $dir 'stdout.txt'
        ExitFile = Join-Path $dir 'exit.txt'
        Started  = Join-Path $dir 'started.txt'
        Task     = "vmtest-$Name"
    }
}

function Get-VmtJobStatus {
    param([string]$Name)
    $paths = Get-VmtJobPaths $Name
    $exitCode = $null
    if (Test-Path -LiteralPath $paths.ExitFile) {
        $raw = ([IO.File]::ReadAllText($paths.ExitFile)).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed)) { $exitCode = $parsed } else { $exitCode = -999 }
    }
    $tail = @()
    if (Test-Path -LiteralPath $paths.Stdout) {
        $fs = [IO.File]::Open($paths.Stdout, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader($fs)
            $tail = @(($reader.ReadToEnd() -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 3)
        }
        finally { $fs.Dispose() }
    }
    $procNames = if ($Name -eq 'apply') { @('TrustedUninstaller.CLI') } else { @() }
    $alive = @()
    foreach ($procName in $procNames) {
        $alive += @(Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    }
    return [ordered]@{
        job       = $Name
        started   = (Test-Path -LiteralPath $paths.Started)
        finished  = ($null -ne $exitCode)
        exitCode  = $exitCode
        processes = $alive
        tail      = $tail
        guestTime = (Get-Date).ToString('o')
    }
}

# ---------------------------------------------------------------- medium-token entry point
if ($Mode -eq 'Status') {
    Write-VmtResult -Result (Get-VmtJobStatus $Job) -ExitCode 0
}

if (-not $Elevated -and -not (Test-VmtElevated)) {
    $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-VmtRegValue $sys 'EnableLUA'
    $consentAdmin = Get-VmtRegValue $sys 'ConsentPromptBehaviorAdmin'
    if ($lua -ne 0 -and $consentAdmin -ne 0) {
        Write-VmtResult -ExitCode 10 -Result @{
            error = "Cannot elevate without a prompt: EnableLUA=$lua, ConsentPromptBehaviorAdmin=$consentAdmin. " +
                    'Set the guest UAC slider to "Never notify" (ConsentPromptBehaviorAdmin=0) in the snapshot.'
        }
    }
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $resultPath = Join-Path $stateDir ("{0}-{1}.json" -f $Mode, [Guid]::NewGuid().ToString('N'))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-Mode', $Mode, '-Job', $Job, '-Root', $Root, '-Elevated', '-ResultFile', $resultPath)
    if ($NoDefenderRemediation) { $argList += '-NoDefenderRemediation' }
    $proc = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru
    if (-not $proc.WaitForExit(600000)) {
        Write-VmtResult -ExitCode 11 -Result @{ error = "Elevated $Mode did not finish within 10 minutes" }
    }
    if (-not (Test-Path -LiteralPath $resultPath)) {
        Write-VmtResult -ExitCode 12 -Result @{ error = "Elevated $Mode exited ($($proc.ExitCode)) without writing a result" }
    }
    $relayed = Get-Content -LiteralPath $resultPath -Raw
    [Console]::Out.WriteLine('VMTEST_JSON_BEGIN')
    [Console]::Out.WriteLine($relayed)
    [Console]::Out.WriteLine('VMTEST_JSON_END')
    [Console]::Out.WriteLine("VMTEST_EXIT=$($proc.ExitCode)")
    exit $proc.ExitCode
}

# ---------------------------------------------------------------- elevated modes
try {
    switch ($Mode) {
        'Prepare' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            foreach ($pair in @(@('cli.zip', $cliDir), @('playbook.zip', $pbDir))) {
                $zipPath = Join-Path $inDir $pair[0]
                if (-not (Test-Path -LiteralPath $zipPath)) { throw "Missing $zipPath" }
                if (Test-Path -LiteralPath $pair[1]) { Remove-Item -LiteralPath $pair[1] -Recurse -Force }
                [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $pair[1])
            }
            if (-not (Test-Path -LiteralPath (Join-Path $cliDir 'TrustedUninstaller.CLI.exe'))) { throw 'TrustedUninstaller.CLI.exe not found after extracting cli.zip' }
            if (-not (Test-Path -LiteralPath (Join-Path $pbDir 'playbook.conf'))) { throw 'playbook.conf not found after extracting playbook.zip' }

            $users = @(Get-VmtInteractiveUser)
            $before = Get-VmtDefenderToggles
            $remediated = $false
            if ($before.anyOn -and -not $before.tamperOn -and -not $NoDefenderRemediation) {
                # Windows turns real-time protection back on by itself; the snapshot was prepared
                # with these off, and with Tamper Protection off Set-MpPreference may restore that.
                Set-MpPreference -DisableRealtimeMonitoring $true -MAPSReporting Disabled -SubmitSamplesConsent NeverSend
                Start-Sleep -Seconds 3
                $remediated = $true
            }
            $after = Get-VmtDefenderToggles
            $build = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $result = [ordered]@{
                interactiveUsers = $users
                defenderBefore   = $before
                defenderAfter    = $after
                defenderRemediated = $remediated
                osBuild          = "$($build.CurrentBuild).$($build.UBR)"
                displayVersion   = $build.DisplayVersion
            }
            $code = 0
            if ($users.Count -eq 0) { $result.error = 'No interactive user session (explorer.exe) - the scheduled task needs a logged-on user'; $code = 20 }
            elseif ($after.anyOn) {
                $result.error = if ($after.tamperOn) { 'Tamper Protection is on; turn it off in Windows Security and re-take the snapshot' }
                                else { 'Defender toggles are still on after remediation; the AME CLI would block on a keypress' }
                $code = 21
            }
            Write-VmtResult -Result $result -ExitCode $code
        }

        'Start' {
            $paths = Get-VmtJobPaths $Job
            if (Test-Path -LiteralPath $paths.Dir) { Remove-Item -LiteralPath $paths.Dir -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $paths.Dir | Out-Null

            if ($Job -eq 'apply') {
                $optFile = Join-Path $inDir 'options.txt'
                $options = @()
                if (Test-Path -LiteralPath $optFile) {
                    $options = @(Get-Content -LiteralPath $optFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9!._-]+$' })
                }
                # The CLI dereferences its option list unconditionally (CLI.cs: options.ToArray()),
                # so it must get at least one. "<nul" turns any Console.ReadKey into an exception
                # instead of an invisible hang.
                $exe = Join-Path $cliDir 'TrustedUninstaller.CLI.exe'
                $line = "`"$exe`" `"$pbDir`" $($options -join ' ') <nul >`"$($paths.Stdout)`" 2>&1"
                # Redirect first: "echo 0>file" would redirect stream 0 instead of writing "0".
                $body = @('@echo off', "cd /d `"$cliDir`"", ">`"$($paths.Started)`" echo %DATE% %TIME%", $line, ">`"$($paths.ExitFile)`" echo %ERRORLEVEL%")
            }
            else {
                $script = Join-Path $inDir 'revert.ps1'
                if (-not (Test-Path -LiteralPath $script)) { throw "No revert script at $script" }
                $line = "`"$PSHOME\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$script`" <nul >`"$($paths.Stdout)`" 2>&1"
                $body = @('@echo off', "cd /d `"$inDir`"", ">`"$($paths.Started)`" echo %DATE% %TIME%", $line, ">`"$($paths.ExitFile)`" echo %ERRORLEVEL%")
            }
            [IO.File]::WriteAllLines($paths.Cmd, [string[]]$body, (New-Object Text.ASCIIEncoding))

            # @() matters: a one-element result unrolls to a string and $users[0] is its first char.
            $users = @(Get-VmtInteractiveUser)
            if ($users.Count -eq 0) { throw 'No interactive user session to run the job in' }
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"$($paths.Cmd)`""
            $principal = New-ScheduledTaskPrincipal -UserId $users[0] -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
            Unregister-ScheduledTask -TaskName $paths.Task -Confirm:$false -ErrorAction SilentlyContinue
            Register-ScheduledTask -TaskName $paths.Task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $paths.Task

            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath $paths.Started) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
            $info = Get-ScheduledTaskInfo -TaskName $paths.Task
            $result = [ordered]@{ job = $Job; task = $paths.Task; runAs = $users[0]; started = (Test-Path -LiteralPath $paths.Started); lastTaskResult = $info.LastTaskResult; command = $line }
            if (-not $result.started) { $result.error = "Task $($paths.Task) did not start within 60s (LastTaskResult $($info.LastTaskResult))"; Write-VmtResult -Result $result -ExitCode 30 }
            Write-VmtResult -Result $result -ExitCode 0
        }

        'Stop' {
            $paths = Get-VmtJobPaths $Job
            Stop-ScheduledTask -TaskName $paths.Task -ErrorAction SilentlyContinue
            $killed = @()
            $names = if ($Job -eq 'apply') { @('TrustedUninstaller.CLI') } else { @() }
            foreach ($procName in $names) {
                foreach ($p in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
                    & "$env:SystemRoot\System32\taskkill.exe" /F /T /PID $p.Id | Out-Null
                    $killed += $p.Id
                }
            }
            Write-VmtResult -Result ([ordered]@{ job = $Job; killed = $killed }) -ExitCode 0
        }

        'Collect' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $collect = Join-Path $Root 'collect'
            if (Test-Path -LiteralPath $collect) { Remove-Item -LiteralPath $collect -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $collect | Out-Null
            $errors = New-Object System.Collections.ArrayList
            $counts = [ordered]@{}
            # The CLI logs into its own directory (it passes Environment.CurrentDirectory as logFolder).
            foreach ($name in @('Output.txt', 'Log.yml', 'OutputBuffer.txt')) {
                $src = Join-Path $cliDir $name
                if (Test-Path -LiteralPath $src) {
                    try { Copy-VmtFileShared -Source $src -Destination (Join-Path $collect "cli\$name"); $counts["cli\$name"] = 1 }
                    catch { [void]$errors.Add("${src}: $($_.Exception.Message)") }
                }
            }
            $counts['cli\Logs'] = Copy-VmtTree -Source (Join-Path $cliDir 'Logs') -Destination (Join-Path $collect 'cli\Logs') -Errors $errors
            $counts['jobs'] = Copy-VmtTree -Source $jobsDir -Destination (Join-Path $collect 'jobs') -Errors $errors
            $counts['state'] = Copy-VmtTree -Source $stateDir -Destination (Join-Path $collect 'state') -Errors $errors
            $counts['ProgramData-AME-Logs'] = Copy-VmtTree -Source "$env:ProgramData\AME\Logs" -Destination (Join-Path $collect 'ProgramData-AME-Logs') -Errors $errors
            $manifest = [ordered]@{ counts = $counts; errors = @($errors) }
            [IO.File]::WriteAllText((Join-Path $collect 'collect.json'), (ConvertTo-Json -InputObject $manifest -Depth 4))

            $zip = Join-Path $Root 'logs.zip'
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
            [IO.Compression.ZipFile]::CreateFromDirectory($collect, $zip)
            $manifest.zip = $zip
            $manifest.sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            Write-VmtResult -Result $manifest -ExitCode 0
        }
    }
}
catch {
    Write-VmtResult -ExitCode 1 -Result @{ error = "$Mode failed: $($_.Exception.Message)"; at = "$($_.InvocationInfo.ScriptLineNumber)" }
}

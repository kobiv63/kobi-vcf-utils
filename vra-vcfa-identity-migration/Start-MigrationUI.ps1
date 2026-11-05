<#
.SYNOPSIS
    Opens the browser page for the vRA to VCFA identity migration and runs the scripts in this folder from it.
.DESCRIPTION
    Serves migration-ui.html on 127.0.0.1 and starts the existing scripts (Export-VraIdentity.ps1, Import-Vcfa.ps1,
    Sync-IdentitySource.ps1, or the Python versions) as child processes. It uses only what Windows PowerShell 5.1
    already has, so there is nothing to install.

    Safety:
    - Listens on 127.0.0.1 only. Requests must use the 127.0.0.1 or localhost address, must not come from another
      web page (Origin check), and must carry the token that is written into the page.
    - Passwords and tokens go to the child process as environment variables only. They are not put on the command
      line, not written to a file and not logged.
    - The child's stdin is redirected, so the scripts never wait for a prompt. Missing input stops the step with a message.
    - One step runs at a time. A step that writes (load with apply) needs the page's typed 'yes' and is refused without it.
    - Sync-IdentitySource 'apply' (the one write to VCF Operations) opens its own console window, so its own
      dry-run and typed 'yes' gates still apply.
.PARAMETER Port
    Port on 127.0.0.1. The next nine ports are tried if it is busy. Default 8765.
.PARAMETER NoBrowser
    Do not open the page in the default browser.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-MigrationUI.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

# ---- State ------------------------------------------------------------------
$script:ScriptDir = $PSScriptRoot
$script:Jobs = New-Object System.Collections.ArrayList   # newest first
$script:Current = $null                                 # the running child job, if any
$script:NextId = 1
$script:Stop = $false
$script:Token = ''
$script:ListenPort = 0
$script:ReportNames = @('vra-export-report.html', 'vcfa-load-report.html')
$script:KnownFiles = @('vra-export.json', 'vcfa-import.json', 'vra-export-report.html', 'vcfa-plan.json', 'vcfa-load-report.html', 'identity-sources.json')
$script:Titles = @{
    'export-login' = 'Test the vRA login'
    'export-all' = 'Export from vRA'
    'export-domains' = 'List the vRA domains'
    'load-login' = 'Test the VCFA connection'
    'load-dry' = 'VCFA dry run'
    'load-apply' = 'Create in VCFA'
    'sync-login' = 'Test both logins'
    'sync-extract' = 'Read the base DNs'
    'sync-compare' = 'Compare the base DNs'
    'sync-apply-console' = 'Add a base DN (console window)'
}

# ---- Small helpers ----------------------------------------------------------
function Get-Field($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-Text($Obj, [string]$Name) {
    $v = Get-Field $Obj $Name
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

function Test-PlainText([string]$Text, [int]$Max) {
    if ($null -eq $Text) { return $false }
    if ($Text.Length -gt $Max) { return $false }
    return ($Text -notmatch '[\x00-\x1f\x7f]')
}

function Test-HostText([string]$Text) {
    return ($Text -match '^(https?://)?[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~\-]*)*/?$')
}

function Test-TokenText([string]$Text) {
    return ($Text -match '^[A-Za-z0-9._~+/=\-]{20,8192}$')
}

function Quote-Arg([string]$Value) {
    if ($Value -eq '' -or $Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function New-UiToken {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLower()
}

function Get-OutputEncoding {
    try { return [Console]::OutputEncoding } catch { return [Text.Encoding]::Default }
}

# ---- Engines ----------------------------------------------------------------
function Get-PowerShellExe { return (Get-Process -Id $PID).Path }

function Get-PythonInfo {
    # Checked once at start-up (Initialize-Engines). Native stderr must not stop the script, so errors are read as text.
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ ok = $false; exe = ''; label = 'python was not found on PATH' } }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $ver = [string]((& $cmd.Source --version 2>&1) | Out-String)
        if ($ver -notmatch 'Python 3') { return @{ ok = $false; exe = ''; label = 'python on PATH is not Python 3' } }
        $null = (& $cmd.Source -c 'import requests' 2>&1)
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; exe = ''; label = 'the requests package is missing (run: python -m pip install requests)' } }
        return @{ ok = $true; exe = $cmd.Source; label = ($ver.Trim() + ' with requests') }
    } catch {
        return @{ ok = $false; exe = ''; label = 'python could not be started' }
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Get-PythonInfoCached {
    if ($null -eq $script:PyInfo) { $script:PyInfo = Get-PythonInfo }
    return $script:PyInfo
}

# ---- Building one run -------------------------------------------------------
function New-RunSpec {
    param([string]$Action, [string]$Engine, [string]$Folder, $Values)

    $bad = { param([string]$m) return @{ Ok = $false; Error = $m } }
    if (-not $script:Titles.ContainsKey($Action)) { return (& $bad "Unknown step '$Action'.") }
    if ($Action.StartsWith('sync-')) { $Engine = 'powershell' }
    if ($Engine -notin @('powershell', 'python')) { return (& $bad "Unknown engine '$Engine'.") }
    if (-not $Folder -or -not [System.IO.Path]::IsPathRooted($Folder) -or -not (Test-PlainText $Folder 260)) {
        return (& $bad 'The output folder must be a full path, for example C:\exports\customer1.')
    }
    $v = $Values
    if ($null -eq $v) { $v = New-Object PSObject }

    $envVars = @{}
    $argList = New-Object System.Collections.ArrayList
    $flags = New-Object System.Collections.ArrayList
    $consoleOpen = $false
    $display = ''

    # Helper: a plain text field, no control characters, no quotes (they break the command line).
    $text = { param([string]$Name, [int]$Max = 256) return (Get-Text $v $Name) }
    $checkText = { param([string]$Label, [string]$Value, [int]$Max = 256)
        if ($Value -ne '' -and (-not (Test-PlainText $Value $Max) -or $Value.Contains('"'))) { return "$Label has characters that are not allowed." }
        return ''
    }

    $vraHost = & $text 'vraHost'; $vraUser = & $text 'vraUsername'; $vraPass = Get-Field $v 'vraPassword'
    $vraDomain = & $text 'vraDomain'; $vraProj = & $text 'vraProjectDomain'
    $vraDomains = & $text 'vraDomains' 1024
    # The page sends a real boolean; anything else (for example the text "false") counts as off.
    $tlsText = if ((Get-Field $v 'verifyTls') -eq $true) { 'true' } else { 'false' }
    $vcfaHost = & $text 'vcfaHost'; $vcfaOrg = & $text 'vcfaOrg'; $vcfaMethod = & $text 'vcfaMethod'
    if (-not $vcfaMethod) { $vcfaMethod = 'browser' }
    $vcfaToken = & $text 'vcfaToken' 8192; $importFile = & $text 'importFile'
    $scope = & $text 'scope'; if (-not $scope) { $scope = 'free' }
    $confirm = & $text 'confirm'
    $allowMissing = [bool](Get-Field $v 'allowMissingRoles')
    $idmHost = & $text 'idmHost'; $idmMethod = & $text 'idmMethod'; $idmUser = & $text 'idmUsername'
    $idmPass = Get-Field $v 'idmPassword'; $idmToken = & $text 'idmToken' 8192
    $opsHost = & $text 'opsHost'; $opsMethod = & $text 'opsMethod'; $opsUser = & $text 'opsUsername'
    $opsPass = Get-Field $v 'opsPassword'; $opsAuth = & $text 'opsAuthSource'; $opsToken = & $text 'opsToken' 8192
    if (-not $idmMethod) { $idmMethod = 'password' }
    if (-not $opsMethod) { $opsMethod = 'password' }
    $ssoId = & $text 'ssoDomainId' 64; $addDn = & $text 'addBaseDn' 512

    # Common checks for typed values
    foreach ($pair in @(
        @('vRA username', $vraUser), @('vRA domain', $vraDomain), @('project user domain', $vraProj),
        @('VCFA organization name', $vcfaOrg), @('import file name', $importFile),
        @('IDM username', $idmUser), @('VCF Operations username', $opsUser), @('VCF Operations auth source', $opsAuth))) {
        $msg = & $checkText $pair[0] $pair[1]
        if ($msg) { return (& $bad $msg) }
    }
    if ($vraHost -and -not (Test-HostText $vraHost)) { return (& $bad 'The vRA host does not look like a host name, for example dev.vra.local.') }
    if ($vcfaHost -and -not (Test-HostText $vcfaHost)) { return (& $bad 'The VCFA host does not look like a host name, for example vcfa.corp.local.') }
    if ($idmHost -and -not (Test-HostText $idmHost)) { return (& $bad 'The IDM host does not look like a host name.') }
    if ($opsHost -and -not (Test-HostText $opsHost)) { return (& $bad 'The VCF Operations host does not look like a host name.') }
    if ($ssoId -and $ssoId -notmatch '^[A-Za-z0-9\-]{1,64}$') { return (& $bad 'The SSO domain ID should contain only letters, digits and dashes.') }
    if ($addDn -and ($addDn -notmatch '^[A-Za-z0-9=,.\- _]{1,512}$' -or $addDn.Contains('"'))) { return (& $bad 'The base DN has characters that are not allowed.') }
    if ($importFile -and ($importFile.Contains('"') -or -not (Test-PlainText $importFile 260))) { return (& $bad 'The import file name has characters that are not allowed.') }

    $sets = @{}
    $pyEnv = @{ 'PYTHONIOENCODING' = 'utf-8'; 'PYTHONUNBUFFERED' = '1' }
    $here = $script:ScriptDir

    if ($Action -in @('export-login', 'export-all', 'export-domains')) {
        if (-not $vraHost) { return (& $bad 'Fill in the vRA host.') }
        if (-not $vraUser) { return (& $bad 'Fill in the vRA username.') }
        if (-not $vraPass) { return (& $bad 'Fill in the vRA password.') }
        if (-not (Test-PlainText ([string]$vraPass) 1024)) { return (& $bad 'The vRA password has characters that are not allowed.') }
        $envVars['VRA_HOST'] = $vraHost; $envVars['VRA_USERNAME'] = $vraUser; $envVars['VRA_PASSWORD'] = [string]$vraPass
        if ($vraDomain) { $envVars['VRA_DOMAIN'] = $vraDomain }
        if ($vraProj) { $envVars['VRA_PROJECT_USER_DOMAIN'] = $vraProj }
        $envVars['VRA_VERIFY_TLS'] = $tlsText
        # Domains to export: 'all', or a list of names (the page sends the names it found and the user kept).
        $domainNames = @()
        if ($vraDomains -and $vraDomains.ToLower() -ne 'all') {
            foreach ($n in @($vraDomains.Split(','))) {
                $t = $n.Trim()
                if (-not $t) { continue }
                if (-not (Test-PlainText $t 256) -or $t.Contains('"')) { return (& $bad "The domain '$t' has characters that are not allowed.") }
                $domainNames += $t
            }
            if ($domainNames.Count -eq 0) { return (& $bad 'List at least one vRA domain, or choose all.') }
        }
        $envVars['VRA_DOMAINS'] = if ($domainNames.Count -gt 0) { $domainNames -join ',' } else { 'all' }
        $step = if ($Action -eq 'export-login') { 'login' } elseif ($Action -eq 'export-domains') { 'domains' } else { 'all' }
        if ($Engine -eq 'python') {
            $exe = (Get-PythonInfoCached).exe
            if (-not $exe) { return (& $bad 'Python is not set up. Choose PowerShell in Setup.') }
            $scriptPath = Join-Path $here 'export_vra_identity.py'
            $argList.AddRange(@((Quote-Arg $scriptPath), $step)) | Out-Null
            foreach ($k in $pyEnv.Keys) { $envVars[$k] = $pyEnv[$k] }
        } else {
            $exe = Get-PowerShellExe
            $scriptPath = Join-Path $here 'Export-VraIdentity.ps1'
            $argList.AddRange(@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $scriptPath), '-Step', $step)) | Out-Null
        }
    }
    elseif ($Action -like 'load-*') {
        if (-not $vcfaHost) { return (& $bad 'Fill in the VCFA host.') }
        if (-not $vcfaOrg) { return (& $bad 'Fill in the organization name.') }
        if (-not $vcfaToken) { return (& $bad 'Paste a token in step 2 first.') }
        if (-not (Test-TokenText $vcfaToken)) { return (& $bad 'The token does not look right. Paste only the token, or the whole copied request so the page can take the token out.') }
        if ($vcfaMethod -notin @('browser', 'api')) { return (& $bad "Unknown token method '$vcfaMethod'.") }
        if ($scope -notin @('free', 'groups', 'users', 'only')) { return (& $bad "Unknown scope '$scope'.") }
        if ($Action -eq 'load-apply' -and $confirm -ne 'yes') { return (& $bad "Type yes in step 4 to confirm the create.") }

        $only = @()
        foreach ($n in @(Get-Field $v 'only')) {
            $t = ([string]$n).Trim()
            if (-not $t) { continue }
            if ($t.StartsWith('-') -or $t.Contains('"') -or -not (Test-PlainText $t 256)) { return (& $bad "The name '$t' has characters that are not allowed, or starts with a dash.") }
            $only += $t
        }
        if ($scope -eq 'only' -and $only.Count -eq 0) { return (& $bad 'List at least one group or user name, one per line.') }
        # Names are used only with the "only" scope; anything left in the box for other scopes is ignored.
        if ($scope -ne 'only') { $only = @() }

        $envVars['VCFA_HOST'] = $vcfaHost; $envVars['VCFA_ORG'] = $vcfaOrg; $envVars['VCFA_VERIFY_TLS'] = $tlsText
        if ($vcfaMethod -eq 'api') { $envVars['VCFA_API_TOKEN'] = $vcfaToken } else { $envVars['VCFA_BROWSER_TOKEN'] = $vcfaToken }
        if (-not $importFile) { $importFile = 'vcfa-import.json' }

        if ($Engine -eq 'python') {
            $exe = (Get-PythonInfoCached).exe
            if (-not $exe) { return (& $bad 'Python is not set up. Choose PowerShell in Setup.') }
            $scriptPath = Join-Path $here 'load_vcfa.py'
            $argList.AddRange(@((Quote-Arg $scriptPath), '--org', (Quote-Arg $vcfaOrg), $(if ($vcfaMethod -eq 'api') { '--api-token' } else { '--browser-token' }))) | Out-Null
            if ($scope -eq 'groups') { $argList.Add('--groups-only') | Out-Null }
            if ($scope -eq 'users') { $argList.Add('--users') | Out-Null }
            foreach ($n in $only) { $argList.Add('--only') | Out-Null; $argList.Add((Quote-Arg $n)) | Out-Null }
            if ($Action -eq 'load-login') { $argList.Add('--login-only') | Out-Null }
            if ($Action -eq 'load-apply') { $argList.Add('--apply') | Out-Null }
            if ($allowMissing -and $Action -eq 'load-apply') { $argList.Add('--allow-missing-roles') | Out-Null }
            $argList.AddRange(@('--import-file', (Quote-Arg $importFile))) | Out-Null
            foreach ($k in $pyEnv.Keys) { $envVars[$k] = $pyEnv[$k] }
        } else {
            $exe = Get-PowerShellExe
            $scriptPath = Join-Path $here 'Import-Vcfa.ps1'
            $argList.AddRange(@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $scriptPath), '-Org', (Quote-Arg $vcfaOrg), $(if ($vcfaMethod -eq 'api') { '-ApiToken' } else { '-BrowserToken' }))) | Out-Null
            if ($scope -eq 'groups') { $argList.Add('-GroupsOnly') | Out-Null }
            if ($scope -eq 'users') { $argList.Add('-Users') | Out-Null }
            if ($only.Count -gt 0) { $argList.Add('-Only') | Out-Null; foreach ($n in $only) { $argList.Add((Quote-Arg $n)) | Out-Null } }
            if ($Action -eq 'load-login') { $argList.Add('-LoginOnly') | Out-Null }
            if ($Action -eq 'load-apply') { $argList.Add('-Apply') | Out-Null }
            if ($allowMissing -and $Action -eq 'load-apply') { $argList.Add('-AllowMissingRoles') | Out-Null }
            $argList.AddRange(@('-ImportFile', (Quote-Arg $importFile))) | Out-Null
        }
    }
    else {
        # sync-*: always PowerShell
        if (-not $idmHost) { return (& $bad 'Fill in the IDM host.') }
        if (-not $opsHost) { return (& $bad 'Fill in the VCF Operations host.') }
        $envVars['IDM_HOST'] = $idmHost; $envVars['VCFOPS_HOST'] = $opsHost; $envVars['SYNC_VERIFY_TLS'] = $tlsText
        if ($idmMethod -eq 'token') {
            if (-not $idmToken) { return (& $bad 'Paste the IDM browser token first.') }
            if (-not (Test-TokenText $idmToken)) { return (& $bad 'The IDM token does not look right. Paste only the token, or the whole copied request.') }
            $envVars['IDM_METHOD'] = 'token'; $envVars['IDM_TOKEN'] = $idmToken
        } else {
            if (-not $idmUser -or -not $idmPass) { return (& $bad 'Fill in the IDM username and password.') }
            $envVars['IDM_METHOD'] = 'password'; $envVars['IDM_USERNAME'] = $idmUser; $envVars['IDM_PASSWORD'] = [string]$idmPass
        }
        if ($opsMethod -eq 'token') {
            if (-not $opsToken) { return (& $bad 'Paste the VCF Operations browser token first.') }
            if (-not (Test-TokenText $opsToken)) { return (& $bad 'The VCF Operations token does not look right. Paste only the token, or the whole copied request.') }
            $envVars['VCFOPS_METHOD'] = 'token'; $envVars['VCFOPS_TOKEN'] = $opsToken
        } else {
            if (-not $opsUser -or -not $opsPass) { return (& $bad 'Fill in the VCF Operations username and password.') }
            $envVars['VCFOPS_METHOD'] = 'password'; $envVars['VCFOPS_USERNAME'] = $opsUser; $envVars['VCFOPS_PASSWORD'] = [string]$opsPass
            if ($opsAuth) { $envVars['VCFOPS_AUTHSOURCE'] = $opsAuth }
        }
        $step = $Action.Substring(5)     # login, extract, compare, apply
        if ($step -eq 'apply-console') { $step = 'apply' }
        $exe = Get-PowerShellExe
        $scriptPath = Join-Path $here 'Sync-IdentitySource.ps1'
        $consoleOpen = ($Action -eq 'sync-apply-console')
        if ($consoleOpen) { $argList.Add('-NoExit') | Out-Null }
        $argList.AddRange(@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $scriptPath), '-Step', $step)) | Out-Null
        if ($ssoId) { $argList.AddRange(@('-SsoDomainId', $ssoId)) | Out-Null }
        if ($consoleOpen -and $addDn) { $argList.AddRange(@('-AddBaseDn', (Quote-Arg $addDn))) | Out-Null }
    }

    if (-not (Test-Path -LiteralPath $scriptPath)) { return (& $bad "The script was not found: $scriptPath") }

    $argText = [string]::Join(' ', @($argList))
    $display = (Split-Path -Leaf $exe) + ' ' + $argText
    $onlyText = ''
    if ($Action -like 'load-*') { $onlyText = [string]::Join("`n", [string[]]@($only)) }
    return @{
        Ok = $true; Action = $Action; Title = $script:Titles[$Action]; Engine = $Engine
        Exe = $exe; Args = $argText; Env = $envVars; WorkDir = $Folder; Console = $consoleOpen
        Display = $display; Scope = $scope; Only = $onlyText
        ImportFile = $importFile
    }
}

# ---- Running children -------------------------------------------------------
# Steps run as redirected child processes. Background readers copy their output into the job's line list, and the
# exit code comes from the Process object. (Start-Process does not give a usable ExitCode when output is redirected
# in Windows PowerShell 5.1, so it is not used for these.) The console window for the identity 'apply' step is the
# exception: it needs a real new window, which Start-Process gives.
$script:ReaderText = @'
param($reader, $lines, $stream)
try {
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        if ($lines.Count -lt 20000) { [void]$lines.Add(@{ s = $stream; t = $line }) }
    }
} catch { }
'@

function Add-JobLine($Job, [string]$Stream, [string]$Text) {
    if ($Job.Lines.Count -lt 20000) { [void]$Job.Lines.Add(@{ s = $Stream; t = $Text }) }
}

function Start-RedirectedProcess($Spec) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Spec.Exe
    $psi.Arguments = $Spec.Args
    $psi.WorkingDirectory = $Spec.WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Python is told to write UTF-8 (PYTHONIOENCODING); PowerShell writes the console code page.
    if ($Spec.Engine -eq 'python') { $enc = [Text.Encoding]::UTF8 } else { $enc = Get-OutputEncoding }
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc
    # The child gets its own copy of the environment: passwords and tokens never touch this process's environment.
    foreach ($k in $Spec.Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Spec.Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()      # the scripts see end-of-input at once, so they never wait for a prompt
    return $p
}

function Start-LineReader($Reader, [string]$Stream, $Lines) {
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript($script:ReaderText).AddArgument($Reader).AddArgument($Lines).AddArgument($Stream)
    $handle = $ps.BeginInvoke()
    return @{ Ps = $ps; Handle = $handle }
}

function Invoke-ConsoleWindow($Spec) {
    # The console window reads its settings from the environment, so they are set only while the window starts.
    $saved = @{}
    foreach ($k in $Spec.Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$Spec.Env[$k], 'Process')
    }
    try {
        return Start-Process -FilePath $Spec.Exe -ArgumentList $Spec.Args -WorkingDirectory $Spec.WorkDir -PassThru
    } finally {
        foreach ($k in $Spec.Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

function Update-Job($Job) {
    if ($Job.Status -ne 'running' -or -not $Job.Proc) { return }
    foreach ($r in $Job.Readers) { if (-not $r.Handle.IsCompleted) { return } }   # output still arriving
    $p = $Job.Proc
    try { [void]$p.WaitForExit(500) } catch { }
    if (-not $p.HasExited) { return }
    foreach ($r in $Job.Readers) {
        try { $r.Ps.EndInvoke($r.Handle) } catch { }
        $r.Ps.Dispose()
    }
    $Job.Readers = @()
    $Job.ExitCode = $p.ExitCode
    $Job.Status = if ($Job.CancelRequested) { 'cancelled' } else { 'done' }
    $Job.Ended = (Get-Date).ToUniversalTime().ToString('o')
    Add-JobLine $Job 'sys' ("Finished with exit code $($Job.ExitCode).")
    if ($script:Current -and [object]::ReferenceEquals($script:Current, $Job)) { $script:Current = $null }
}

function Start-Run($Spec) {
    $id = $script:NextId; $script:NextId++
    if (-not (Test-Path -LiteralPath $Spec.WorkDir)) { New-Item -ItemType Directory -Path $Spec.WorkDir -Force | Out-Null }
    $lines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $job = @{
        Id = $id; Action = $Spec.Action; Title = $Spec.Title; Status = 'running'; ExitCode = $null
        Started = (Get-Date).ToUniversalTime().ToString('o'); Ended = $null
        Scope = $Spec.Scope; Only = $Spec.Only; ImportFile = $Spec.ImportFile
        Lines = $lines; Readers = @(); Proc = $null; CancelRequested = $false; WorkDir = $Spec.WorkDir
    }
    [void]$script:Jobs.Insert(0, $job)
    Add-JobLine $job 'sys' ("Working folder: " + $Spec.WorkDir)
    Add-JobLine $job 'sys' ("Command: " + $Spec.Display)
    try {
        if ($Spec.Console) {
            $job.Proc = Invoke-ConsoleWindow $Spec
            $job.Status = 'console'
            $job.Ended = (Get-Date).ToUniversalTime().ToString('o')
            Add-JobLine $job 'sys' 'A PowerShell window opened. Answer its questions there. Nothing is written from this page.'
        } else {
            $p = Start-RedirectedProcess $Spec
            $job.Proc = $p
            $outReader = Start-LineReader $p.StandardOutput 'out' $lines
            $errReader = Start-LineReader $p.StandardError 'err' $lines
            $job.Readers = @($outReader, $errReader)
            $script:Current = $job
        }
    } catch {
        # The child never started: show the reason and finish the job, so the page does not wait forever.
        $job.Status = 'done'; $job.ExitCode = -1
        $job.Ended = (Get-Date).ToUniversalTime().ToString('o')
        Add-JobLine $job 'err' ('The step could not be started: ' + $_.Exception.Message)
    }
    return $job
}

function Get-JobSummary($Job) {
    return @{
        id = $Job.Id; action = $Job.Action; title = $Job.Title; status = $Job.Status; exitCode = $Job.ExitCode
        startedUtc = $Job.Started; endedUtc = $Job.Ended; scope = $Job.Scope; only = $Job.Only; importFile = $Job.ImportFile
    }
}

function Find-Job([int]$Id) {
    foreach ($j in $script:Jobs) { if ($j.Id -eq $Id) { return $j } }
    return $null
}

# ---- Info for the page ------------------------------------------------------
function Get-Info([string]$Folder) {
    $fold = if ($Folder) { $Folder } else { $script:ScriptDir }
    $exists = $false
    try { $exists = Test-Path -LiteralPath $fold -PathType Container } catch { $exists = $false }
    $files = @()
    foreach ($n in $script:KnownFiles) {
        $p = Join-Path $fold $n
        $ex = $false; $size = 0
        try { $ex = Test-Path -LiteralPath $p -PathType Leaf } catch { $ex = $false }
        if ($ex) { $size = (Get-Item -LiteralPath $p).Length }
        $files += @{ name = $n; exists = $ex; size = $size }
    }
    $py = Get-PythonInfoCached
    $defaults = @{}
    foreach ($k in @('VRA_HOST', 'VRA_USERNAME', 'VRA_DOMAIN', 'VCFA_HOST', 'VCFA_ORG', 'IDM_HOST', 'IDM_USERNAME', 'VCFOPS_HOST', 'VCFOPS_USERNAME', 'VCFOPS_AUTHSOURCE')) {
        $val = [Environment]::GetEnvironmentVariable($k, 'Process')
        $defaults[$k] = if ($val) { $val } else { '' }
    }
    return @{
        scriptDir = $script:ScriptDir
        folder = $fold
        folderExists = $exists
        scripts = @{
            export = (Test-Path -LiteralPath (Join-Path $script:ScriptDir 'Export-VraIdentity.ps1'))
            load = (Test-Path -LiteralPath (Join-Path $script:ScriptDir 'Import-Vcfa.ps1'))
            sync = (Test-Path -LiteralPath (Join-Path $script:ScriptDir 'Sync-IdentitySource.ps1'))
            template = (Test-Path -LiteralPath (Join-Path $script:ScriptDir 'report-template.html'))
        }
        engines = @{
            powershell = @{ ok = $true; label = ('PowerShell ' + $PSVersionTable.PSVersion.ToString()) }
            python = @{ ok = $py.ok; label = $py.label }
        }
        files = $files
        defaults = $defaults
        running = [bool]$script:Current
    }
}

# ---- HTTP -------------------------------------------------------------------
function Send-Bytes($Ctx, [int]$Status, [string]$Type, [byte[]]$Bytes) {
    $r = $Ctx.Response
    $r.StatusCode = $Status
    $r.ContentType = $Type
    $r.ContentLength64 = $Bytes.Length
    $r.Headers['Cache-Control'] = 'no-store'
    $r.Headers['X-Content-Type-Options'] = 'nosniff'
    $r.Headers['Referrer-Policy'] = 'no-referrer'
    if ($Type -like 'text/html*') {
        $r.Headers['Content-Security-Policy'] = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'"
    }
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $r.OutputStream.Close()
}

function Send-Json($Ctx, [int]$Status, $Body) {
    $json = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Text($Ctx, [int]$Status, [string]$Text) {
    Send-Bytes $Ctx $Status 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Read-Body($Req) {
    if ($Req.ContentLength64 -gt 262144) { return @{ tooLarge = $true } }
    $sr = New-Object System.IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try { $text = $sr.ReadToEnd() } finally { $sr.Close() }
    if (-not $text.Trim()) { return New-Object PSObject }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Test-TokenEqual([string]$Given, [string]$Expected) {
    if ([string]::IsNullOrEmpty($Given) -or $Given.Length -ne $Expected.Length) { return $false }
    return ($Given -ceq $Expected)
}

function Invoke-Route($Ctx) {
    $req = $Ctx.Request
    $port = $script:ListenPort
    $hostHeader = [string]$req.Headers['Host']
    if (@("127.0.0.1:$port", "localhost:$port") -notcontains $hostHeader) {
        Send-Text $Ctx 403 'Open the page at the address that Start-MigrationUI.ps1 printed.'
        return
    }
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        $pagePath = Join-Path $script:ScriptDir 'migration-ui.html'
        if (-not (Test-Path -LiteralPath $pagePath)) { Send-Text $Ctx 500 'migration-ui.html is missing next to Start-MigrationUI.ps1.'; return }
        $html = [System.IO.File]::ReadAllText($pagePath, [Text.Encoding]::UTF8).Replace('__UI_TOKEN__', $script:Token)
        Send-Bytes $Ctx 200 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($html))
        return
    }
    if ($path -notlike '/api/*') { Send-Text $Ctx 404 'Not found.'; return }

    $origin = [string]$req.Headers['Origin']
    if ($origin -and (@("http://127.0.0.1:$port", "http://localhost:$port") -notcontains $origin)) {
        Send-Json $Ctx 403 @{ error = 'This request came from another site and was refused.' }; return
    }
    if (-not (Test-TokenEqual ([string]$req.Headers['X-UI-Token']) $script:Token)) {
        Send-Json $Ctx 403 @{ error = 'The page token is missing or wrong. Reload the page from the address that Start-MigrationUI.ps1 printed.' }; return
    }

    if ($method -eq 'GET' -and $path -eq '/api/info') {
        Send-Json $Ctx 200 (Get-Info ($req.QueryString['folder'])); return
    }
    if ($method -eq 'GET' -and $path -eq '/api/jobs') {
        $list = @(); foreach ($j in $script:Jobs) { Update-Job $j; $list += (Get-JobSummary $j) }
        Send-Json $Ctx 200 @{ jobs = $list }; return
    }

    $m = [regex]::Match($path, '^/api/jobs/(\d{1,9})(/cancel)?$')
    if ($m.Success) {
        $job = Find-Job ([int]$m.Groups[1].Value)
        if (-not $job) { Send-Json $Ctx 404 @{ error = 'No such step.' }; return }
        if ($method -eq 'GET' -and -not $m.Groups[2].Success) {
            Update-Job $job
            $after = 0
            [void][int]::TryParse([string]$req.QueryString['after'], [ref]$after)
            if ($after -lt 0) { $after = 0 }
            $lines = @()
            for ($i = $after; $i -lt $job.Lines.Count; $i++) { $lines += $job.Lines[$i] }
            Send-Json $Ctx 200 @{ id = $job.Id; status = $job.Status; exitCode = $job.ExitCode; lines = $lines; next = $job.Lines.Count }
            return
        }
        if ($method -eq 'POST' -and $m.Groups[2].Success) {
            if ($job.Status -eq 'running' -and $job.Proc) {
                $job.CancelRequested = $true
                try { Stop-Process -Id $job.Proc.Id -Force -ErrorAction Stop } catch { }
                Update-Job $job
            }
            Send-Json $Ctx 200 (Get-JobSummary $job); return
        }
        Send-Json $Ctx 405 @{ error = 'Method not allowed.' }; return
    }

    if ($method -eq 'POST' -and $path -eq '/api/jobs') {
        $body = Read-Body $req
        if ($null -eq $body) { Send-Json $Ctx 400 @{ error = 'The request was not valid JSON.' }; return }
        if ($body -is [hashtable] -and $body.ContainsKey('tooLarge')) { Send-Json $Ctx 413 @{ error = 'The request is too large.' }; return }
        if ($script:Current) { Send-Json $Ctx 409 @{ error = 'A step is already running. Wait for it, or cancel it in the output drawer.' }; return }
        $spec = New-RunSpec (Get-Text $body 'action') (Get-Text $body 'engine') (Get-Text $body 'folder') (Get-Field $body 'values')
        if (-not $spec.Ok) { Send-Json $Ctx 400 @{ error = $spec.Error }; return }
        try {
            $job = Start-Run $spec
        } catch {
            Send-Json $Ctx 500 @{ error = ('The step could not be started: ' + $_.Exception.Message) }; return
        }
        Send-Json $Ctx 200 @{ id = $job.Id; status = $job.Status }; return
    }

    if ($method -eq 'POST' -and $path -eq '/api/open') {
        $body = Read-Body $req
        if ($null -eq $body) { Send-Json $Ctx 400 @{ error = 'The request was not valid JSON.' }; return }
        $name = Get-Text $body 'name'
        $folder = Get-Text $body 'folder'
        if ($script:ReportNames -notcontains $name) { Send-Json $Ctx 400 @{ error = 'Only the two HTML reports can be opened from here.' }; return }
        if (-not $folder -or -not [System.IO.Path]::IsPathRooted($folder)) { Send-Json $Ctx 400 @{ error = 'The output folder is not set.' }; return }
        $p = Join-Path $folder $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Send-Json $Ctx 404 @{ error = "$name is not in that folder yet. Run the step that writes it first." }; return }
        Start-Process -FilePath $p
        Send-Json $Ctx 200 @{ ok = $true }; return
    }

    if ($method -eq 'POST' -and $path -eq '/api/shutdown') {
        if ($script:Current) { Send-Json $Ctx 409 @{ error = 'A step is still running. Cancel it or wait for it first.' }; return }
        Send-Json $Ctx 200 @{ ok = $true }
        $script:Stop = $true
        return
    }

    Send-Json $Ctx 404 @{ error = 'Not found.' }
}

# ---- Main -------------------------------------------------------------------
function Start-MigrationUIServer {
    $script:Token = New-UiToken
    $listener = $null
    foreach ($candidate in $Port..($Port + 9)) {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$candidate/")
        try { $l.Start(); $listener = $l; $script:ListenPort = $candidate; break }
        catch { try { $l.Close() } catch { } }
    }
    if (-not $listener) { throw "No free port from $Port to $($Port + 9) on 127.0.0.1." }
    $script:PyInfo = Get-PythonInfo

    $url = "http://127.0.0.1:$($script:ListenPort)/"
    Write-Host ''
    Write-Host "  Migration UI is running at $url"
    Write-Host '  Keep this window open while you work. Stop the UI with the button on the page, or Ctrl+C.'
    Write-Host '  Passwords and tokens are kept in memory and passed only to the step that needs them.'
    Write-Host ''
    if (-not $NoBrowser) { Start-Process $url }

    try {
        while (-not $script:Stop) {
            $ctx = $listener.GetContext()
            try { Invoke-Route $ctx }
            catch { try { Send-Json $ctx 500 @{ error = $_.Exception.Message } } catch { } }
        }
    } finally {
        $listener.Stop(); $listener.Close()
        if ($script:Current) { try { Stop-Process -Id $script:Current.Proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
        Write-Host '  Migration UI stopped.'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-MigrationUIServer
}

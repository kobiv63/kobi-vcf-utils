<#
.SYNOPSIS
    Check the logins to IDM (Workspace ONE Access / vIDM) and VCF Operations, and read the directory group DNs from both.
    Read only. PowerShell only, no dependencies.

.DESCRIPTION
    Step 1 of making sure the AD groups you are about to load into VCFA are provisioned in the VCF Operations
    identity source (VCF Identity Broker, "directory group provisioning"):
      - IDM: the directories and the group DNs set in their sync settings.
      - VCF Operations: the SSO domain, its identity provider, LDAP directories and the group DNs already provisioned.
    login, extract and compare are read only. The apply step is the only one that can change anything: it adds base DN(s)
    (named with -AddBaseDn, or all that are missing) to the VCF Operations group provisioning, and it is a DRY RUN unless you pass -Apply and type
    'yes'. It only ever adds: nothing already provisioned is removed or changed (checked before and after), and the current
    profile is saved to a backup file first. The unit that matters is the BASE group DN; nested groups are not handled
    (VCF Operations has its own "Sync Nested Groups" setting).

    Log in with a username and password first. If that does not work, use a browser token instead
    (copy a request from the browser; the script picks the Authorization header out of it).

.PARAMETER Step
    login   - log in to both systems and run one harmless read on each (checks the credentials and the API access)
    extract - log in, then read the group base DNs from both systems and write identity-sources.json
    compare - extract, then compare the base DNs of the two systems (IDM needs / VCF Operations has). Read only.
    apply   - add base DN(s) to VCF Operations: the ones named in -AddBaseDn, all that are missing (-AddAllMissing), or a pick
              from a menu. Dry run unless -Apply is given (or you choose Write in the menu).
    Leave it out to get a menu.
.PARAMETER OutputDir
    Folder for identity-sources.json (default: the current folder).
.PARAMETER AddBaseDn
    apply step: the base DN(s) to add to VCF Operations. Each must be a base DN set up in IDM, and not already in VCF Operations.
.PARAMETER AddAllMissing
    apply step: add every IDM base DN that VCF Operations does not have yet (instead of naming them with -AddBaseDn).
.PARAMETER Apply
    apply step: really write the change (default is a dry run that shows it and writes nothing). You must also type 'yes'.
.PARAMETER SsoDomainId
    The id of the SSO domain in VCF Operations. It is the UUID in the browser address:
    .../sso-domains/domain/<this id>/identity-source . Leave it out to find the domain automatically.

.EXAMPLE
    .\Sync-IdentitySource.ps1 login
.EXAMPLE
    .\Sync-IdentitySource.ps1 extract -SsoDomainId 00000000-0000-0000-0000-000000000000
.EXAMPLE
    .\Sync-IdentitySource.ps1 apply -AddBaseDn 'CN=my-test-group,OU=Test,DC=corp,DC=local'          (dry run)
.EXAMPLE
    .\Sync-IdentitySource.ps1 apply -AddBaseDn 'CN=my-test-group,OU=Test,DC=corp,DC=local' -Apply   (writes, after you type yes)

.NOTES
    Defaults come from the env vars IDM_HOST, IDM_USERNAME, IDM_PASSWORD, IDM_TOKEN, IDM_METHOD (password or token),
    VCFOPS_HOST, VCFOPS_USERNAME, VCFOPS_PASSWORD, VCFOPS_AUTHSOURCE, VCFOPS_TOKEN, VCFOPS_METHOD. When input is redirected nothing is prompted.
    If scripts are blocked:  powershell -ExecutionPolicy Bypass -File .\Sync-IdentitySource.ps1 login
#>
[CmdletBinding()]
param(
    [ValidateSet('login', 'extract', 'compare', 'apply')]
    [string]$Step,
    [string]$OutputDir,
    [string]$SsoDomainId,
    [string[]]$AddBaseDn,
    [switch]$AddAllMissing,
    [switch]$Apply
)

# ---- Config -----------------------------------------------------------------
# Every value below is asked for in the terminal; what you set here (or in an env var) is only the default.
$script:IdmHost = 'idm.example.com'            # e.g. 'ca-idm.corp.local' (https:// is added if missing; env IDM_HOST)
if ($env:IDM_HOST) { $script:IdmHost = $env:IDM_HOST }
$script:OpsHost = 'vcf-ops.example.com'        # e.g. 'vcf-ops01.corp.local' (https:// is added if missing; env VCFOPS_HOST)
if ($env:VCFOPS_HOST) { $script:OpsHost = $env:VCFOPS_HOST }
$script:VerifyTls = $false   # asked at the prompt; $false accepts a self-signed certificate (lab). e.g. $true for a CA-signed cert
$script:TimeoutSec = 30      # seconds per request (not asked); e.g. 120 for a slow appliance
$script:OutputPath = (Get-Location).Path   # asked at the prompt for the extract step; e.g. 'C:\exports\customer1'
$script:OpsApiBase = '/suite-api'          # VCF Operations API prefix (not asked); the IAM API is OpsApiBase + /api/fleet-management/iam
$script:IamPath = '/api/fleet-management/iam'
$script:OutputFile = 'identity-sources.json'

$script:Steps = @(
    @{ Value = 'login'; Text = 'Test the logins only (one harmless read on each system)' },
    @{ Value = 'extract'; Text = 'Log in and read the group base DNs from IDM and VCF Operations' },
    @{ Value = 'compare'; Text = 'Extract, then compare the base DNs of the two systems (read only)' },
    @{ Value = 'apply'; Text = 'Add a base DN to VCF Operations (dry run unless -Apply)' }
)
$script:LoginMethods = @(
    @{ Value = 'password'; Text = 'Username and password' },
    @{ Value = 'token'; Text = 'Browser token (if the password does not work)' }
)

# ---- Prompts ----------------------------------------------------------------
function Die([string]$Message) { throw "ERROR: $Message" }

function Test-Interactive {
    if ($null -ne $script:ForceInteractive) { return [bool]$script:ForceInteractive }
    return (-not [Console]::IsInputRedirected)
}

function Read-Line([string]$Prompt) { return (Read-Host -Prompt $Prompt) }

function Read-Secret([string]$Prompt) {
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-Value([string]$Label, [string]$Default = '', [switch]$Secret, [string]$Example = '') {
    # Prompt with a default (Enter accepts it) or an example when there is no default.
    # Returns the default when there is no terminal.
    if (-not (Test-Interactive)) { return $Default }
    if ($Secret) {
        $v = Read-Secret $Label
        if ($v) { return $v } else { return $Default }
    }
    $hint = ''
    if ($Default) { $hint = " [$Default]" } elseif ($Example) { $hint = " (e.g. $Example)" }
    $v = Read-Line "$Label$hint"
    if ($null -ne $v) { $v = $v.Trim() }
    if ($v) { return $v } else { return $Default }
}

function Confirm-Yes([string]$Label, [bool]$Default = $false) {
    if (-not (Test-Interactive)) { return $Default }
    $suffix = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $raw = (Read-Line "$Label [$suffix]")
        if ($null -eq $raw) { $raw = '' }
        $raw = $raw.Trim().ToLower()
        if (-not $raw) { return $Default }
        if ($raw -in @('y', 'yes')) { return $true }
        if ($raw -in @('n', 'no')) { return $false }
        Write-Host '  Answer y or n.'
    }
}

function Select-Option([string]$Label, $Options, [int]$Default = 1) {
    # Numbered menu; Options is an array of @{Value=..; Text=..}. Returns the chosen Value.
    $Options = @($Options)
    if (-not (Test-Interactive)) { return $Options[$Default - 1].Value }
    Write-Host $Label
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $Options[$i].Text) }
    while ($true) {
        $raw = (Read-Line "Choice [$Default]")
        if ($null -eq $raw) { $raw = '' }
        $raw = $raw.Trim()
        if (-not $raw) { $raw = "$Default" }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $Options[$n - 1].Value }
        Write-Host '  Enter one of the numbers above.'
    }
}

function ConvertTo-HostUrl([string]$Value) {
    # 'dev.vra.local' -> 'https://dev.vra.local'. No scheme means https; an explicit http:// or https:// is kept.
    # Path, query and trailing slashes are dropped, the host is lower-cased, a port is kept. Throws if not a host.
    $v = ("$Value").Trim()
    if (-not $v) { throw 'enter a host name, e.g. dev.vra.local' }
    if ($v.Contains(' ')) { throw "'$v' contains a space" }
    if (-not $v.Contains('://')) { $v = "https://$v" }
    $m = [regex]::Match($v, '^(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*)://(?<auth>[^/?#]*)')
    if (-not $m.Success) { throw "'$($Value.Trim())' is not a valid host name" }
    $scheme = $m.Groups['scheme'].Value.ToLower()
    if ($scheme -notin @('http', 'https')) { throw "only http:// or https:// is supported, not '${scheme}://'" }
    $auth = $m.Groups['auth'].Value
    if ($auth.Contains('@')) { throw 'do not put a user name or password in the host' }
    $hostName = $auth
    $port = ''
    $pm = [regex]::Match($auth, '^(?<h>\[[^\]]*\]|[^:]*):(?<p>.*)$')
    if ($pm.Success) { $hostName = $pm.Groups['h'].Value; $port = $pm.Groups['p'].Value }
    if ($port) {
        $n = 0
        if (-not ($port -match '^\d+$') -or -not [int]::TryParse($port, [ref]$n) -or $n -gt 65535) {
            throw "'$($Value.Trim())' has an invalid port"
        }
    }
    if (-not $hostName) { throw "'$($Value.Trim())' is not a valid host name" }
    $result = "${scheme}://$($hostName.ToLower())"
    if ($port) { $result += ":$port" }
    return $result
}

function Read-HostUrl([string]$Label, [string]$Default = '', [string]$Example = '') {
    # Prompt for a host and return it as a clean base URL; asks again on invalid input.
    while ($true) {
        $raw = Read-Value $Label $Default -Example $Example
        try { return (ConvertTo-HostUrl $raw) }
        catch {
            if (-not (Test-Interactive)) { Die "${Label}: $($_.Exception.Message)" }
            Write-Host "  $($_.Exception.Message)"
        }
    }
}

# ---- HTTP -------------------------------------------------------------------
function Set-TlsPolicy([bool]$Verify) {
    $script:VerifyTls = $Verify
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not ('TrustAllCerts' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustAllCerts {
    public static bool Callback(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
    public static void Enable() { ServicePointManager.ServerCertificateValidationCallback = Callback; }
    public static void Disable() { ServicePointManager.ServerCertificateValidationCallback = null; }
}
"@
        }
        if ($Verify) { [TrustAllCerts]::Disable() } else { [TrustAllCerts]::Enable() }
    }
}

function ConvertTo-Plain($o) {
    # JavaScriptSerializer output (dictionaries/lists) -> hashtables and object[]
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $o.Keys) { $h[[string]$k] = ConvertTo-Plain $o[$k] }
        return $h
    }
    if (($o -is [System.Collections.IList]) -and ($o -isnot [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($x in $o) { [void]$list.Add((ConvertTo-Plain $x)) }
        return , $list.ToArray()
    }
    return $o
}

function ConvertFrom-JsonText([string]$Text) {
    # JSON text -> hashtables / object[] / scalars (works on Windows PowerShell 5.1 and 7, no size limit)
    if (-not $Text -or -not $Text.Trim()) { return $null }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $r = $Text | ConvertFrom-Json -AsHashtable
    }
    else {
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 1000
        $r = ConvertTo-Plain ($ser.DeserializeObject($Text))
    }
    if ($r -is [array]) { return , $r }
    return $r
}

function ConvertTo-JsonText($Data) { return (ConvertTo-Json -InputObject $Data -Depth 50) }

function Save-Json([string]$Path, $Data) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (ConvertTo-JsonText $Data), $utf8)
}

function Get-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Get-Location).Path $Path)
}

function Short([string]$Text, [int]$Length = 300) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Length) { return $Text }
    return $Text.Substring(0, $Length)
}

function Sort-Ordinal($Items) {
    $arr = [string[]]@($Items)
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return , $arr
}

function Sort-ByKey($Items, [scriptblock]$Key) {
    # Ordinal sort by a computed key. Returns the array object itself (assign it; do not wrap the call in @()).
    $arr = @($Items)
    if ($arr.Count -lt 2) { return , $arr }
    $keys = [string[]]@($arr | ForEach-Object { & $Key $_ })
    $items = [object[]]$arr.Clone()
    # The explicit casts matter: without them PowerShell picks an overload that sorts the keys but not the items.
    [Array]::Sort([Array]$keys, [Array]$items, [System.Collections.IComparer][System.StringComparer]::Ordinal)
    return , $items
}

function Write-HtmlReport([string]$Path, $Data) {
    # Fills report-template.html (next to the script) with the data and writes a single self-contained HTML file.
    $template = Join-Path $PSScriptRoot 'report-template.html'
    if (-not (Test-Path -LiteralPath $template)) {
        Write-Host '  Report skipped: report-template.html was not found next to this script.'
        return $false
    }
    $json = (ConvertTo-Json -InputObject $Data -Depth 30 -Compress).Replace('</', '<\/')
    $html = [System.IO.File]::ReadAllText($template, [System.Text.Encoding]::UTF8).Replace('/*REPORT_DATA*/null', $json)
    [System.IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Report: $Path"
    return $true
}

function Invoke-Api {
    # One HTTP call that never throws on 4xx/5xx. Returns @{ Status; Text; Headers; Body } (Body = parsed JSON or $null).
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null, [string]$ContentType = '')
    $p = @{ Uri = $Url; Method = $Method; Headers = $Headers; TimeoutSec = $script:TimeoutSec; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        if ($Body -is [string]) {
            # Windows PowerShell 5.1 would encode a string body as ISO-8859-1 and mangle non-ASCII names and passwords.
            $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
            if ($ContentType -and $ContentType -notlike '*charset*') { $ContentType += '; charset=utf-8' }
        }
        $p.Body = $Body
        if ($ContentType) { $p.ContentType = $ContentType }
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if (-not $script:VerifyTls) { $p.SkipCertificateCheck = $true }
        $p.SkipHttpErrorCheck = $true
    }
    $utf8 = [System.Text.Encoding]::UTF8
    try {
        $r = Invoke-WebRequest @p
        $text = ''
        if ($r.RawContentStream) { $text = $utf8.GetString($r.RawContentStream.ToArray()) } elseif ($r.Content) { $text = [string]$r.Content }
        $status = [int]$r.StatusCode
        $hdrs = $r.Headers
    }
    catch {
        $err = $_
        $resp = $err.Exception.Response
        if ($null -eq $resp) { throw "request to $Url failed: $($err.Exception.Message)" }
        $status = [int]$resp.StatusCode
        $hdrs = $resp.Headers
        $text = ''
        try {
            $stream = $resp.GetResponseStream()
            if ($stream.CanSeek) { [void]$stream.Seek(0, [System.IO.SeekOrigin]::Begin) }
            $reader = New-Object System.IO.StreamReader($stream, $utf8)
            $text = $reader.ReadToEnd()
            $reader.Close()
        }
        catch { $text = '' }
        # Windows PowerShell 5.1 has often read the error body already; it keeps a copy on the error record.
        if (-not $text -and $err.ErrorDetails -and $err.ErrorDetails.Message) { $text = $err.ErrorDetails.Message }
    }
    $parsed = $null
    if ($text) { try { $parsed = ConvertFrom-JsonText $text } catch { $parsed = $null } }
    return @{ Status = $status; Text = $text; Headers = $hdrs; Body = $parsed }
}

function ConvertTo-Query($Params) {
    if (-not $Params) { return '' }
    $parts = foreach ($k in $Params.Keys) { '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Params[$k]) }
    return '?' + ($parts -join '&')
}

# ---- Helpers specific to this script ----------------------------------------
function First-Set { foreach ($a in $args) { if ($a) { return $a } }; return '' }

function Read-TokenInput([string]$Label, [string]$Default = '') {
    # A whole copied request is many lines and cannot be pasted into a prompt, so Enter on an empty line reads the clipboard.
    if (-not (Test-Interactive)) { return $Default }
    $v = Read-Secret "$Label (paste ONLY the token, or just press Enter to read the copied request from the clipboard)"
    if ($v) { return $v }
    if ($Default) { return $Default }
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { $clip = '' }
    if ($clip.Trim()) { Write-Host '  Read the copied request from the clipboard.'; return $clip }
    Write-Host '  The clipboard is empty. In the browser: dev tools, Network, right-click a request, Copy, Copy as fetch.'
    return ''
}

function Get-AuthHeaderValue([string]$Text, [string[]]$Schemes) {
    # Returns the full Authorization header value(s) to try, e.g. 'HZN abc...' or 'OpsToken abc...'.
    # Accepts a whole copied request (fetch, cURL, PowerShell), 'Scheme token', or a bare token (tried with each scheme).
    $out = New-Object System.Collections.ArrayList
    $m = [regex]::Match($Text, '(?i)authorization["'']?\s*[:=]\s*["'']?([A-Za-z][A-Za-z0-9\-]*)\s+([A-Za-z0-9._~+/=\-]+)')
    if ($m.Success) { [void]$out.Add("$($m.Groups[1].Value) $($m.Groups[2].Value)"); return , $out.ToArray() }
    $t = $Text.Trim().Trim('"', "'").Trim()
    $m = [regex]::Match($t, '^([A-Za-z][A-Za-z0-9\-]*)\s+([A-Za-z0-9._~+/=\-]+)$')
    if ($m.Success) { [void]$out.Add("$($m.Groups[1].Value) $($m.Groups[2].Value)"); return , $out.ToArray() }
    if ($t -match '\s') { Die 'the text has spaces or line breaks and no "authorization: ..." header, so it is not a token. Copy only the token, or the whole copied request' }
    if ($t.Length -lt 20) { Die 'that does not look like a token (too short)' }
    foreach ($s in $Schemes) { [void]$out.Add("$s $t") }
    return , $out.ToArray()
}

function Get-ListItems($Body) {
    # List responses name their array differently; return the items flat (wrap the call in @()).
    if ($Body -is [array]) { return $Body }
    if ($Body -is [System.Collections.IDictionary]) {
        foreach ($key in 'items', 'content', 'results', 'values', 'ssoRealms', 'realms', 'ldapDirectories', 'directories', 'identityProviders') {
            if ($Body.Contains($key) -and ($Body[$key] -is [array])) { return $Body[$key] }
        }
        foreach ($k in $Body.Keys) { if ($Body[$k] -is [array]) { return $Body[$k] } }
    }
    return
}

function Remove-Secrets($Obj) {
    # Copy of the data with anything that looks like a secret blanked, so raw responses are safe to save and share.
    if ($Obj -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $Obj.Keys) {
            if ("$k" -match '(?i)pass(word)?$|secret|token|credential|private|apikey|api_key|bindpw') { $h["$k"] = '<removed>' }
            else { $h["$k"] = Remove-Secrets $Obj[$k] }
        }
        return $h
    }
    if (($Obj -is [System.Collections.IList]) -and ($Obj -isnot [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($x in $Obj) { [void]$list.Add((Remove-Secrets $x)) }
        return , $list.ToArray()
    }
    return $Obj
}

function Test-LooksLikeDn([string]$Text) { return ($Text -match '^(?i)\s*(CN|OU|DC|UID)=[^,=]+(,\s*[A-Za-z]+=[^,]+)*\s*$') }

function Find-Dns($Obj, [string]$Path = '') {
    # Finds distinguished names anywhere in a response, whether they are values or JSON keys.
    # Emits @{ Path; Dn; IsGroup } flat (wrap the call in @()). IsGroup = the path mentions 'group'.
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) {
            $p = "$Path/$k"
            if (Test-LooksLikeDn "$k") { @{ Path = $Path; Dn = "$k".Trim(); IsGroup = ($Path -match '(?i)group') } }
            Find-Dns $Obj[$k] $p
        }
    }
    elseif (($Obj -is [System.Collections.IList]) -and ($Obj -isnot [string])) {
        $i = 0
        foreach ($x in $Obj) { Find-Dns $x "$Path[$i]"; $i++ }
    }
    elseif ($Obj -is [string]) {
        if (Test-LooksLikeDn $Obj) { @{ Path = $Path; Dn = $Obj.Trim(); IsGroup = ($Path -match '(?i)group') } }
    }
}

function Get-GroupDns($Obj) {
    # The unique group DNs found in a response (if no path mentions 'group', all DNs are returned). Array object: assign it.
    $found = @(Find-Dns $Obj)
    $groups = @($found | Where-Object { $_.IsGroup })
    if ($groups.Count -eq 0) { $groups = $found }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object System.Collections.ArrayList
    foreach ($g in $groups) { if ($seen.Add($g.Dn.ToLower())) { [void]$out.Add($g.Dn) } }
    return , (Sort-Ordinal $out)
}

$script:Calls = New-Object System.Collections.ArrayList
function Invoke-Logged([string]$System, [string]$Method, [string]$Url, [hashtable]$Headers, $Body = $null, [string]$ContentType = '') {
    # Every request is recorded (system, method, path, status) so a failed run can be understood afterwards.
    $r = Invoke-Api $Method $Url $Headers $Body $ContentType
    $path = ([uri]$Url).PathAndQuery
    [void]$script:Calls.Add([ordered]@{ system = $System; method = $Method; path = $path; status = $r.Status })
    return $r
}

# ---- IDM (Workspace ONE Access / vIDM) --------------------------------------
$script:IdmDirectoryAccept = 'application/vnd.vmware.horizon.manager.connector.management.directory.list+json'

function Connect-IdmPassword([string]$User, [string]$Password) {
    # The documented admin login: returns a session token that is sent as "Authorization: HZN <token>".
    $body = ConvertTo-Json -InputObject ([ordered]@{ username = $User; password = $Password; issueToken = $true })
    $r = Invoke-Logged 'idm' POST "$($script:IdmHost)/SAAS/API/1.0/REST/auth/system/login" @{ Accept = 'application/json' } $body 'application/json'
    if ($r.Status -ne 200) { Die "IDM login failed ($($r.Status)): $(Short $r.Text 200)" }
    $token = $r.Body['sessionToken']
    if (-not $token) { Die "IDM login returned no sessionToken: $(Short $r.Text 200)" }
    return "HZN $token"
}

function Get-IdmDirectories([string]$Auth) {
    $r = Invoke-Logged 'idm' GET "$($script:IdmHost)/SAAS/jersey/manager/api/connectormanagement/directoryconfigs?includeJitDirectories=true" @{ Authorization = $Auth; Accept = $script:IdmDirectoryAccept }
    if ($r.Status -eq 406) {   # the vendor type was not accepted; plain JSON is worth a try
        $r = Invoke-Logged 'idm' GET "$($script:IdmHost)/SAAS/jersey/manager/api/connectormanagement/directoryconfigs?includeJitDirectories=true" @{ Authorization = $Auth; Accept = 'application/json' }
    }
    return $r
}

function Connect-Idm([string]$Method, [string]$User, [string]$Password, [string]$TokenText) {
    # Returns @{ Auth; Directories (response) }. Throws with a clear message when the login or the read does not work.
    if ($Method -eq 'password') {
        $auth = Connect-IdmPassword $User $Password
        $r = Get-IdmDirectories $auth
        if ($r.Status -ne 200) { Die "IDM: the login worked but reading the directories failed ($($r.Status)): $(Short $r.Text 200)" }
        return @{ Auth = $auth; Directories = $r; Detail = "user '$User' (password)" }
    }
    $last = $null
    foreach ($auth in (Get-AuthHeaderValue $TokenText @('HZN', 'Bearer'))) {
        $r = Get-IdmDirectories $auth
        if ($r.Status -eq 200) { return @{ Auth = $auth; Directories = $r; Detail = "browser token ($($auth.Split(' ')[0]))" } }
        $last = $r
    }
    Die "IDM: the browser token was rejected ($($last.Status)). It probably expired; copy a fresh request. $(Short $last.Text 160)"
}

function Get-IdmSyncProfile([string]$Auth, [string]$DirectoryId) {
    # Where the sync settings (including the group DNs) are exposed is not documented; try the likely forms.
    $base = "$($script:IdmHost)/SAAS/jersey/manager/api/connectormanagement/directoryconfigs/$DirectoryId"
    $tried = New-Object System.Collections.ArrayList
    foreach ($suffix in '/syncprofile', '') {
        foreach ($accept in '*/*', 'application/json') {
            $r = Invoke-Logged 'idm' GET "$base$suffix" @{ Authorization = $Auth; Accept = $accept }
            if ($r.Status -eq 200 -and $null -ne $r.Body) { return @{ Response = $r; Source = $(if ($suffix) { 'syncprofile' } else { 'directory' }) } }
            [void]$tried.Add("$suffix [$accept] -> $($r.Status)")
        }
    }
    return @{ Response = $null; Source = 'none'; Tried = @($tried) }
}

function Test-SyncableDirectory([string]$Type) {
    # Local and just-in-time directories hold no AD groups to provision; only AD/LDAP directories are read.
    return -not ($Type -match '(?i)local|jit')
}

function Get-SelectedGroups($Body) {
    # What is set up for group sync. IDM keeps it in identityInfo.identityGroupInfo, keyed by BASE DN, each with
    # mappedGroupData[] = { selected, mappedGroup.dn }. The base DN is the unit that gets provisioned: only bases with at
    # least one selected group count (BaseDns); the others are listed apart (IgnoredBaseDns). GroupDns are the selected
    # groups under them. Nested groups are not treated specially: there is no per-group nesting flag, and VCF Operations
    # has its own "Sync Nested Groups" setting.
    $info = $null
    if ($Body -is [System.Collections.IDictionary]) {
        $ii = $Body['identityInfo']
        if ($ii -is [System.Collections.IDictionary]) { $info = $ii['identityGroupInfo'] }
    }
    if ($info -is [System.Collections.IDictionary]) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $dns = New-Object System.Collections.ArrayList
        $bases = New-Object System.Collections.ArrayList
        $ignored = New-Object System.Collections.ArrayList
        foreach ($base in $info.Keys) {
            $e = $info[$base]
            $selected = 0; $total = 0; $lastGroup = $null
            foreach ($m in @($e['mappedGroupData'])) {
                if (-not $m) { continue }
                $total++
                if ($m['selected'] -eq $true -and $m['mappedGroup'] -and $m['mappedGroup']['dn']) {
                    $selected++; $lastGroup = $m['mappedGroup']
                    $dn = [string]$m['mappedGroup']['dn']
                    if ($seen.Add($dn.ToLower())) { [void]$dns.Add($dn) }
                }
            }
            $row = [ordered]@{ baseDn = "$base"; selectedGroups = $selected; totalGroups = $total }
            if ($selected -eq 1 -and $total -eq 1 -and "$base" -match '^CN=' -and $lastGroup -and $lastGroup['objectGuid']) {
                $gn = $lastGroup['horizonName']; if (-not $gn) { $gn = [regex]::Match("$base", '^CN=((?:\\.|[^,])+)').Groups[1].Value }
                $row['groupName'] = [string]$gn
                $row['objectGuid'] = [string]$lastGroup['objectGuid']
            }
            if ($selected -gt 0) { [void]$bases.Add($row) } else { [void]$ignored.Add($row) }
        }
        return @{ GroupDns = (Sort-Ordinal $dns); BaseDns = $bases; IgnoredBaseDns = $ignored; Structure = 'identityInfo' }
    }
    if ($Body -is [System.Collections.IDictionary] -and $Body['ldapGroups'] -is [array]) {
        # VCF Operations / identity broker: ldapGroups[] holds one chosen group { dn, name, baseDn, selectAll = false } or a
        # whole base DN { baseDn, selectAll = true }. Its "Base group DN" list in the UI is the distinct baseDn values.
        $dns = New-Object System.Collections.ArrayList
        $byBase = [ordered]@{}
        foreach ($g in $Body['ldapGroups']) {
            if (-not $g -or -not $g['baseDn']) { continue }
            $k = ([string]$g['baseDn']).ToLower()
            if (-not $byBase.Contains($k)) { $byBase[$k] = [ordered]@{ baseDn = [string]$g['baseDn']; groupsChosen = 0; selectAll = $false } }
            if ($g['selectAll'] -eq $true) { $byBase[$k]['selectAll'] = $true }
            elseif ($g['dn']) { $byBase[$k]['groupsChosen']++; [void]$dns.Add([string]$g['dn']) }
        }
        $bases = Sort-ByKey @($byBase.Values) { param($x) $x['baseDn'].ToLower() }
        return @{ GroupDns = (Sort-Ordinal $dns); BaseDns = $bases; IgnoredBaseDns = @(); Structure = 'ldapGroups' }
    }
    return @{ GroupDns = (Get-GroupDns $Body); BaseDns = @(); IgnoredBaseDns = @(); Structure = 'generic scan' }
}

function Format-Bases($Bases) {
    return ((@($Bases) | ForEach-Object {
                if ($_.Contains('selectAll')) { "$($_['baseDn']) [$(if ($_['selectAll']) { 'all groups' } else { "$($_['groupsChosen']) group(s) chosen" })]" }
                else { "$($_['baseDn']) [$($_['selectedGroups']) of $($_['totalGroups']) groups selected]" }
            }) -join '; ')
}

function ConvertFrom-EpochMs($Ms) {
    if ($null -eq $Ms -or $Ms -isnot [ValueType]) { return $null }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms).UtcDateTime.ToString('o') } catch { return $null }
}

# ---- VCF Operations ----------------------------------------------------------
function Get-OpsUrl([string]$Path) { return "$($script:OpsHost)$($script:OpsApiBase)$Path" }

function Connect-OpsPassword([string]$User, [string]$Password, [string]$AuthSource) {
    # The documented token call. authSource is the name of the login source, e.g. 'VCF SSO'; leave it out for a local user.
    $b = [ordered]@{ username = $User; password = $Password }
    if ($AuthSource) { $b['authSource'] = $AuthSource }
    $r = Invoke-Logged 'ops' POST (Get-OpsUrl '/api/auth/token/acquire') @{ Accept = 'application/json' } (ConvertTo-Json -InputObject $b) 'application/json'
    if ($r.Status -ne 200) { Die "VCF Operations login failed ($($r.Status)): $(Short $r.Text 200)" }
    $token = $r.Body['token']
    if (-not $token) { Die "VCF Operations login returned no token: $(Short $r.Text 200)" }
    return [string]$token
}

function Test-OpsAuth([string]$Auth) {
    return (Invoke-Logged 'ops' GET (Get-OpsUrl '/api/auth/currentuser') @{ Authorization = $Auth; Accept = 'application/json' })
}

function Get-OpsRealms([string]$Auth) {
    return (Invoke-Logged 'ops' GET (Get-OpsUrl "$($script:IamPath)/ssorealms") @{ Authorization = $Auth; Accept = 'application/json' })
}

function Connect-Ops([string]$Method, [string]$User, [string]$Password, [string]$AuthSource, [string]$TokenText) {
    # Returns @{ Auth; Realms (response); Detail }. The scheme in front of the token is not documented, so try the known ones.
    if ($Method -eq 'password') {
        $token = Connect-OpsPassword $User $Password $AuthSource
        $candidates = @("OpsToken $token", "vRealizeOpsToken $token", "Bearer $token")
        $detail = "user '$User' (password" + $(if ($AuthSource) { ", source '$AuthSource')" } else { ')' })
    }
    else {
        $candidates = Get-AuthHeaderValue $TokenText @('OpsToken', 'vRealizeOpsToken', 'Bearer')
        $detail = 'browser token'
    }
    $last = $null
    foreach ($auth in $candidates) {
        $who = Test-OpsAuth $auth
        if ($who.Status -ne 200) { $last = $who; continue }
        $realms = Get-OpsRealms $auth
        if ($realms.Status -ne 200) { Die "VCF Operations: the login worked but reading the SSO domains failed ($($realms.Status)): $(Short $realms.Text 200)" }
        return @{ Auth = $auth; Realms = $realms; Detail = "$detail, header scheme $($auth.Split(' ')[0])" }
    }
    $hint = if ($Method -eq 'password') { 'Check the user name, password and auth source.' } else { 'The token probably expired; copy a fresh request.' }
    Die "VCF Operations: the credentials were not accepted ($($last.Status)). $hint $(Short $last.Text 160)"
}

function Find-Ids($Obj, [string]$KeyPattern) {
    # UUID-looking values under keys that match the pattern (flat; wrap in @()).
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) {
            $v = $Obj[$k]
            if ("$k" -match $KeyPattern -and $v -is [string] -and $v -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { $v }
            Find-Ids $v $KeyPattern
        }
    }
    elseif (($Obj -is [System.Collections.IList]) -and ($Obj -isnot [string])) { foreach ($x in $Obj) { Find-Ids $x $KeyPattern } }
}

# ---- Comparing base DNs (read only) -----------------------------------------
function ConvertTo-NormalDn([string]$Dn) { return (($Dn -replace '\s*,\s*', ',').Trim().ToLower()) }

function Test-DnUnder([string]$Child, [string]$Parent) {
    $c = ConvertTo-NormalDn $Child; $p = ConvertTo-NormalDn $Parent
    return ($c -eq $p) -or $c.EndsWith(",$p")
}

function Compare-BaseDns($IdmBases, $OpsBases) {
    # Exact (case and spacing insensitive) comparison of the base DNs, plus where each one sits relative to the other side.
    $idm = @($IdmBases | Where-Object { $_ }); $ops = @($OpsBases | Where-Object { $_ })
    $idmRows = New-Object System.Collections.ArrayList
    foreach ($b in $idm) {
        $dn = [string]$b['baseDn']
        $exact = @($ops | Where-Object { (ConvertTo-NormalDn $_['baseDn']) -eq (ConvertTo-NormalDn $dn) }).Count -gt 0
        $under = @($ops | Where-Object { (Test-DnUnder $dn $_['baseDn']) -and -not ((ConvertTo-NormalDn $_['baseDn']) -eq (ConvertTo-NormalDn $dn)) } | ForEach-Object { [string]$_['baseDn'] })
        $above = @($ops | Where-Object { (Test-DnUnder $_['baseDn'] $dn) -and -not ((ConvertTo-NormalDn $_['baseDn']) -eq (ConvertTo-NormalDn $dn)) } | ForEach-Object { [string]$_['baseDn'] })
        [void]$idmRows.Add([ordered]@{ baseDn = $dn; inVcfOperations = $exact; sitsUnderVcfOperationsBaseDns = $under; vcfOperationsBaseDnsBelowIt = $above })
    }
    $opsRows = New-Object System.Collections.ArrayList
    foreach ($b in $ops) {
        $dn = [string]$b['baseDn']
        $exact = @($idm | Where-Object { (ConvertTo-NormalDn $_['baseDn']) -eq (ConvertTo-NormalDn $dn) }).Count -gt 0
        [void]$opsRows.Add([ordered]@{ baseDn = $dn; inIdm = $exact })
    }
    return [ordered]@{ idm = $idmRows; vcfOperations = $opsRows }
}

function Write-Comparison($Cmp) {
    Write-Host "Comparing base DNs (exact match, nothing is written): IDM has $(@($Cmp['idm']).Count), VCF Operations has $(@($Cmp['vcfOperations']).Count)."
    foreach ($r in @($Cmp['idm'])) {
        Write-Host "  IDM base DN: $($r['baseDn'])"
        Write-Host "      in VCF Operations: $(if ($r['inVcfOperations']) { 'YES' } else { 'NO' })"
        if (@($r['sitsUnderVcfOperationsBaseDns']).Count -gt 0) { Write-Host "      sits under VCF Operations base DN: $(@($r['sitsUnderVcfOperationsBaseDns']) -join '; ')" }
        if (@($r['vcfOperationsBaseDnsBelowIt']).Count -gt 0) { Write-Host "      VCF Operations base DNs below it: $(@($r['vcfOperationsBaseDnsBelowIt']).Count)" }
    }
    $onlyOps = @(@($Cmp['vcfOperations']) | Where-Object { -not $_['inIdm'] })
    Write-Host "  VCF Operations base DNs that are not an IDM base DN: $($onlyOps.Count)"
    foreach ($r in $onlyOps) { Write-Host "      $($r['baseDn'])" }
}

# ---- Adding a base DN to VCF Operations (the only write; dry run unless -Apply) ----------------
function ConvertTo-CanonicalJson($Obj) {
    # JSON with sorted keys, so two copies of the same data compare equal whatever their key order.
    if ($Obj -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in (Sort-Ordinal @($Obj.Keys))) { (ConvertTo-Json -InputObject "$k" -Compress) + ':' + (ConvertTo-CanonicalJson $Obj[$k]) }
        return '{' + ($parts -join ',') + '}'
    }
    if (($Obj -is [System.Collections.IList]) -and ($Obj -isnot [string])) { return '[' + ((@($Obj) | ForEach-Object { ConvertTo-CanonicalJson $_ }) -join ',') + ']' }
    return (ConvertTo-Json -InputObject $Obj -Compress)
}

function Get-EntryKey($Entry) { return ((ConvertTo-NormalDn ([string]$Entry['baseDn'])) + '|' + [string]([bool]$Entry['selectAll']) + '|' + (ConvertTo-NormalDn ([string]$Entry['dn']))) }

function New-ProfileEntry($Row) {
    # The entry the VCF Operations UI itself creates. A single group (its objectGuid comes from IDM) is a chosen group whose
    # base DN is its own DN; anything else (an OU or the domain) is a select-all base DN.
    $dn = [string]$Row['baseDn']
    if ($Row['objectGuid'] -and $dn -match '^CN=') {
        $name = [string]$Row['groupName']
        if (-not $name) { $name = [regex]::Match($dn, '^CN=((?:\\.|[^,])+)').Groups[1].Value }
        return [ordered]@{ name = $name; dn = $dn; baseDn = $dn; objectGuid = [string]$Row['objectGuid']; selectAll = $false }
    }
    return [ordered]@{ baseDn = $dn; selectAll = $true }
}

function New-PlannedSyncProfile($Profile, $AddRows) {
    # A copy of the profile with one entry added per IDM base DN row (shaped as the UI shapes it).
    $new = [ordered]@{}
    foreach ($k in $Profile.Keys) { $new[$k] = $Profile[$k] }
    $entries = New-Object System.Collections.ArrayList
    foreach ($g in @($Profile['ldapGroups'])) { if ($g) { [void]$entries.Add($g) } }
    foreach ($row in @($AddRows)) { [void]$entries.Add((New-ProfileEntry $row)) }
    $new['ldapGroups'] = $entries.ToArray()
    return $new
}

function Copy-Deep($Obj) { return (ConvertFrom-JsonText (ConvertTo-Json -InputObject $Obj -Depth 30)) }

function Remove-AtPath($Root, [string]$Path) {
    # 'userAttributeMappings[4].required' removes that one field; 'userAttributeMappings[4]' removes that array element.
    # Returns $true when something was removed.
    $tokens = @([regex]::Matches($Path, '[^.\[\]]+') | ForEach-Object { $_.Value })
    if ($tokens.Count -eq 0) { return $false }
    $parent = $null; $parentKey = $null
    $cur = $Root
    for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
        $tk = $tokens[$i]
        if ($cur -is [System.Collections.IDictionary]) { if (-not $cur.Contains($tk)) { return $false }; $parent = $cur; $parentKey = $tk; $cur = $cur[$tk] }
        elseif ($cur -is [array] -and $tk -match '^\d+$' -and [int]$tk -lt $cur.Count) { $parent = $null; $cur = $cur[[int]$tk] }
        else { return $false }
    }
    $last = $tokens[$tokens.Count - 1]
    if ($cur -is [System.Collections.IDictionary] -and $cur.Contains($last)) { $cur.Remove($last); return $true }
    if ($cur -is [array] -and $parent -and $last -match '^\d+$' -and [int]$last -lt $cur.Count) {
        $keep = New-Object System.Collections.ArrayList
        for ($k = 0; $k -lt $cur.Count; $k++) { if ($k -ne [int]$last) { [void]$keep.Add($cur[$k]) } }
        $parent[$parentKey] = $keep.ToArray()
        return $true
    }
    return $false
}

function Get-ValidationFailures($Resp) {
    if ($Resp.Body -is [System.Collections.IDictionary] -and $Resp.Body['validationFailures'] -is [array]) { return $Resp.Body['validationFailures'] }
    return
}

function Test-OnlyAdditions($Old, $New, $AddRows, $IgnorePaths = @()) {
    # $null when New is Old plus exactly the entries for AddRows and nothing else changed (fields in IgnorePaths are left out
    # of both before comparing); otherwise says what differs.
    $o = Copy-Deep $Old; $n = Copy-Deep $New
    foreach ($p in @($IgnorePaths)) { [void](Remove-AtPath $o $p); [void](Remove-AtPath $n $p) }
    foreach ($k in $o.Keys) {
        if ($k -eq 'ldapGroups') { continue }
        if (-not $n.Contains($k)) { return "'$k' is missing from the new profile" }
        if ((ConvertTo-CanonicalJson $o[$k]) -cne (ConvertTo-CanonicalJson $n[$k])) { return "'$k' differs" }
    }
    foreach ($k in $n.Keys) { if (-not $o.Contains($k)) { return "'$k' was added to the profile" } }
    $oldKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($g in @($o['ldapGroups'])) { if ($g) { [void]$oldKeys.Add((Get-EntryKey $g)) } }
    $newKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($g in @($n['ldapGroups'])) { if ($g) { [void]$newKeys.Add((Get-EntryKey $g)) } }
    foreach ($k in $oldKeys) { if (-not $newKeys.Contains($k)) { return "an entry that was provisioned before is missing: $k" } }
    $expected = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in @($AddRows)) { [void]$expected.Add((Get-EntryKey (New-ProfileEntry $row))) }
    $extra = @($newKeys | Where-Object { -not $oldKeys.Contains($_) })
    foreach ($k in $extra) { if (-not $expected.Contains($k)) { return "an unexpected entry appeared: $k" } }
    foreach ($k in $expected) { if (-not $newKeys.Contains($k)) { return "the entry to add is missing: $k" } }
    return $null
}

function Invoke-AddBaseDns($Out, $Ops, [string[]]$Wanted, [bool]$Write) {
    $idmBases = @(@($Out['idm']['directories']) | ForEach-Object { @($_['baseDns']) })
    $opsBases = @(@($Out['vcfOperations']['ssoRealms']) | ForEach-Object { @($_['identityProviders']) } | ForEach-Object { @($_['ldapDirectories']) } | ForEach-Object { @($_['baseDns']) })
    $toAdd = New-Object System.Collections.ArrayList
    foreach ($w in $Wanted) {
        $match = @($idmBases | Where-Object { (ConvertTo-NormalDn $_['baseDn']) -eq (ConvertTo-NormalDn $w) }) | Select-Object -First 1
        if (-not $match) { Die "'$w' is not a base DN in the IDM sync settings, so it is not added. IDM's base DNs: $(@($idmBases | ForEach-Object { $_['baseDn'] }) -join '; ')" }
        if (@($opsBases | Where-Object { (ConvertTo-NormalDn $_['baseDn']) -eq (ConvertTo-NormalDn $w) }).Count -gt 0) { Write-Host "  Already in VCF Operations, nothing to add: $($match['baseDn'])"; continue }
        [void]$toAdd.Add($match)
    }
    if ($toAdd.Count -eq 0) { Write-Host 'Nothing to add.'; return }

    $targets = New-Object System.Collections.ArrayList
    foreach ($realm in @($Out['vcfOperations']['ssoRealms'])) {
        foreach ($idp in @($realm['identityProviders'])) {
            foreach ($dir in @($idp['ldapDirectories'])) { if ($dir['syncProfileId']) { [void]$targets.Add(@{ IdpId = $idp['id']; Dir = $dir }) } }
        }
    }
    if ($targets.Count -ne 1) { Die "expected exactly one VCF Operations directory with a readable sync profile, found $($targets.Count); not changing anything" }
    $target = $targets[0]
    $url = Get-OpsUrl "$($script:IamPath)/identity-providers/$($target.IdpId)/ldap-directories/$($target.Dir['syncProfileId'])/sync-profile"
    $hdr = @{ Authorization = $Ops.Auth; Accept = 'application/json' }

    $cur = Invoke-Logged 'ops' GET $url $hdr
    if ($cur.Status -ne 200 -or $null -eq $cur.Body) { Die "could not read the current sync profile ($($cur.Status)); not changing anything" }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Get-FullPath $script:OutputPath
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $backup = Join-Path $dir "sync-profile-backup-$stamp.json"
    [System.IO.File]::WriteAllText($backup, $cur.Text, (New-Object System.Text.UTF8Encoding($false)))

    $rows = $toAdd.ToArray()
    $planned = New-PlannedSyncProfile $cur.Body $rows
    $problem = Test-OnlyAdditions $cur.Body $planned $rows
    if ($problem) { Die "the planned profile is not a pure addition ($problem); nothing was sent" }
    $plannedPath = Join-Path $dir "sync-profile-planned-$stamp.json"
    Save-Json $plannedPath $planned

    $before = @($cur.Body['ldapGroups']).Count
    Write-Host "VCF Operations directory '$($target.Dir['name'])': $before entries in the group provisioning today."
    foreach ($row in $rows) {
        $e = New-ProfileEntry $row
        if ($e['selectAll']) {
            Write-Host "  + add base group DN, all groups under it: $($e['baseDn'])"
            if ($e['baseDn'] -notmatch '^CN=') { Write-Host '    NOTE: this is a container, not a single group. EVERY group under it will be provisioned.' }
        }
        else { Write-Host "  + add group '$($e['name'])' as the UI does (base DN = its own DN, objectGuid from IDM): $($e['dn'])" }
    }
    Write-Host "  $($rows.Count) base DN(s) to add; $before entries become $($before + $rows.Count)."
    Write-Host '  Nothing already provisioned is removed or changed (checked). Nested groups: not touched.'
    Write-Host "  Current profile saved to: $backup"
    Write-Host "  Planned profile saved to: $plannedPath"
    if (-not $Write) { Write-Host 'DRY RUN - nothing was written to VCF Operations. Add -Apply to write it (you will be asked to type yes).'; return }

    if ((Read-Value "Type 'yes' to write this change to VCF Operations") -ne 'yes') { Die 'not confirmed; nothing was written' }
    $body = $planned
    $ignore = @()
    $attempt = 0
    while ($true) {
        $attempt++
        $put = Invoke-Logged 'ops' PUT $url $hdr (ConvertTo-Json -InputObject $body -Depth 30) 'application/json'
        if ($put.Status -in @(200, 201, 202, 204)) { break }
        $fails = @(Get-ValidationFailures $put)
        $mustBeNull = @($fails | Where-Object { $_['failureMessage'] -eq 'must be null' })
        # An attribute mapping with an empty directory attribute maps nothing (the UI sends it too); the public API refuses it.
        $blank = @($fails | Where-Object { $_['failureMessage'] -eq 'must not be blank' -and [string]$_['violationPath'] -match '^userAttributeMappings\[\d+\]\.directoryAttributeName$' })
        if ($put.Status -eq 400 -and $attempt -eq 1 -and $fails.Count -gt 0 -and ($mustBeNull.Count + $blank.Count) -eq $fails.Count) {
            # Leave out exactly what the server names, once: the read-only fields first, then the empty mappings (highest index first).
            $body = Copy-Deep $body
            $names = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($f in $mustBeNull) { $p = [string]$f['violationPath']; [void](Remove-AtPath $body $p); $ignore += $p; [void]$names.Add(($p -replace '\[\d+\]', '[]')) }
            $idx = @($blank | ForEach-Object { [int]([regex]::Match([string]$_['violationPath'], '\[(\d+)\]').Groups[1].Value) } | Sort-Object -Descending)
            $emptied = @()
            foreach ($n in $idx) {
                $emptied += [string]$body['userAttributeMappings'][$n]['attributeName']
                $p = "userAttributeMappings[$n]"; [void](Remove-AtPath $body $p); $ignore += $p
            }
            $again = Test-OnlyAdditions $cur.Body $planned $rows $ignore
            if ($again) { Die "after leaving out what the server refused the profile is not a pure addition ($again); nothing was sent again. Backup: $backup" }
            if ($mustBeNull.Count -gt 0) { Write-Host "  VCF Operations refused $($mustBeNull.Count) read-only field(s) ($(@($names) -join ', ')). Sending again without them." }
            if ($emptied.Count -gt 0) { Write-Host "  Also leaving out $($emptied.Count) attribute mapping(s) that map nothing (empty directory attribute): $($emptied -join ', ')." }
            continue
        }
        $lines = @($fails | ForEach-Object { "    - $($_['violationPath']): $($_['failureMessage'])" })
        $why = if ($put.Body -is [System.Collections.IDictionary] -and $put.Body['message']) { [string]$put.Body['message'] } else { Short $put.Text 300 }
        Die ("VCF Operations did not accept the change ($($put.Status)): $why`n" + ($lines -join "`n") + "`n  Nothing is known to have changed; the backup is $backup")
    }
    Write-Host "Written (HTTP $($put.Status))."
    $after = Invoke-Logged 'ops' GET $url $hdr
    if ($after.Status -ne 200 -or $null -eq $after.Body) { Write-Host "  WARNING: could not read the profile back ($($after.Status)). Check it in the VCF Operations UI; backup: $backup"; return }
    $skipMaps = @(); if ($ignore.Count -gt 0) { $skipMaps = @('userAttributeMappings') }
    $bad = Test-OnlyAdditions $cur.Body $after.Body $rows $skipMaps
    if ($bad) { Write-Host "  WARNING: the profile read back is not what was planned ($bad). Check it in the UI; backup: $backup" }
    else { Write-Host "  VERIFIED: $(@($after.Body['ldapGroups']).Count) entries now ($before before); everything that was there is still there, and the new base DN(s) are in." }
    Write-Host '  The groups appear after the next sync of the directory (it runs on the schedule shown in VCF Operations; hourly in the lab).'
}

# ---- Main -------------------------------------------------------------------
function Write-Result([string]$System, $Outcome) {
    if ($Outcome.Ok) { Write-Host "  [PASS] $System : $($Outcome.Detail)$($Outcome.Extra)" }
    else { Write-Host "  [FAIL] $System : $($Outcome.Error)" }
}

function Read-Credentials([string]$System, [string]$Prefix, [bool]$AskAuthSource) {
    # Asks how to log in to one system and returns what is needed for it.
    $defaultMethod = 1
    if ((Get-Item "env:${Prefix}_METHOD" -ErrorAction SilentlyContinue).Value -eq 'token') { $defaultMethod = 2 }
    $method = Select-Option "How do you want to log in to ${System}?" $script:LoginMethods $defaultMethod
    $c = @{ Method = $method; User = ''; Password = ''; AuthSource = ''; Token = '' }
    if ($method -eq 'password') {
        $c.User = Read-Value "$System username" (First-Set (Get-Item "env:${Prefix}_USERNAME" -ErrorAction SilentlyContinue).Value) -Example 'admin'
        $pw = (Get-Item "env:${Prefix}_PASSWORD" -ErrorAction SilentlyContinue).Value
        if (-not $pw) { $pw = Read-Value "$System password" -Secret }
        $c.Password = $pw
        if ($AskAuthSource) {
            $c.AuthSource = Read-Value "$System auth source (blank for a local user; SSO users use the source name)" (Get-Item "env:${Prefix}_AUTHSOURCE" -ErrorAction SilentlyContinue).Value -Example 'VCF SSO'
        }
        if (-not ($c.User -and $c.Password)) { Die "$System username and password are required" }
    }
    else {
        $tok = (Get-Item "env:${Prefix}_TOKEN" -ErrorAction SilentlyContinue).Value
        $c.Token = Read-TokenInput "$System token" $tok
        if (-not $c.Token) { Die "$System token: nothing given" }
    }
    return $c
}

function Main {
    $step = $Step
    if (-not $step) { $step = Select-Option 'What do you want to do?' $script:Steps 1 }

    $script:IdmHost = Read-HostUrl 'IDM host (Workspace ONE Access / vIDM FQDN; https:// is added for you)' $script:IdmHost 'ca-idm.corp.local'
    $script:OpsHost = Read-HostUrl 'VCF Operations host (FQDN; https:// is added for you)' $script:OpsHost 'vcf-ops01.corp.local'
    Set-TlsPolicy (Confirm-Yes 'Verify the TLS certificates? (answer n for self-signed certificates)' $script:VerifyTls)
    $idmCred = Read-Credentials 'IDM' 'IDM' $false
    $opsCred = Read-Credentials 'VCF Operations' 'VCFOPS' $true
    if ($step -in @('extract', 'compare', 'apply')) {
        $script:OutputPath = if ($OutputDir) { $OutputDir } else { Read-Value 'Folder for the output file' $script:OutputPath -Example 'C:\exports\customer1' }
    }

    Write-Host 'Logging in ...'
    $results = [ordered]@{}
    $idm = $null; $ops = $null
    try {
        $idm = Connect-Idm $idmCred.Method $idmCred.User $idmCred.Password $idmCred.Token
        $all = @(Get-ListItems $idm.Directories.Body)
        $readable = @($all | Where-Object { Test-SyncableDirectory $_['type'] }).Count
        $results['IDM'] = @{ Ok = $true; Detail = $idm.Detail; Extra = "; $($all.Count) director$(if ($all.Count -eq 1) { 'y' } else { 'ies' }) visible, $readable to read (local ones are skipped)" }
    }
    catch { $results['IDM'] = @{ Ok = $false; Error = ($_.Exception.Message -replace '^ERROR:\s*', '') } }
    try {
        $ops = Connect-Ops $opsCred.Method $opsCred.User $opsCred.Password $opsCred.AuthSource $opsCred.Token
        $count = @(Get-ListItems $ops.Realms.Body).Count
        $results['VCF Operations'] = @{ Ok = $true; Detail = $ops.Detail; Extra = "; $count SSO domain$(if ($count -ne 1) { 's' }) visible" }
    }
    catch { $results['VCF Operations'] = @{ Ok = $false; Error = ($_.Exception.Message -replace '^ERROR:\s*', '') } }
    foreach ($k in $results.Keys) { Write-Result $k $results[$k] }
    $failed = @($results.Keys | Where-Object { -not $results[$_].Ok })
    if ($failed.Count -gt 0 -and ($idmCred.Method -eq 'password' -or $opsCred.Method -eq 'password')) {
        Write-Host '  Tip: if a password login fails, run again and choose "Browser token" for that system.'
    }
    if ($step -eq 'login') {
        if ($failed.Count -gt 0) { Die "$($failed.Count) login(s) failed" }
        Write-Host 'Both logins work. Nothing was changed in either system.'
        return
    }
    if (-not $idm -and -not $ops) { Die 'neither login worked, nothing to read' }

    Write-Host 'Reading ...'
    $out = [ordered]@{ generatedAt = (Get-Date).ToUniversalTime().ToString('o'); idm = $null; vcfOperations = $null; calls = $null }
    if ($idm) { $out['idm'] = Read-IdmGroups $idm }
    if ($ops) { $out['vcfOperations'] = Read-OpsGroups $ops }
    if ($step -eq 'compare') {
        if (-not ($idm -and $ops)) { Die 'compare needs both systems; one of the logins failed' }
        $idmBases = @(@($out['idm']['directories']) | ForEach-Object { @($_['baseDns']) })
        $opsBases = @(@($out['vcfOperations']['ssoRealms']) | ForEach-Object { @($_['identityProviders']) } | ForEach-Object { @($_['ldapDirectories']) } | ForEach-Object { @($_['baseDns']) })
        $cmp = Compare-BaseDns $idmBases $opsBases
        Write-Comparison $cmp
        $out['comparison'] = $cmp
    }
    if ($step -eq 'apply') {
        if (-not ($idm -and $ops)) { Die 'apply needs both systems; one of the logins failed. Nothing was changed.' }
        $wanted = @($AddBaseDn | Where-Object { $_ })
        $write = [bool]$Apply
        if ($wanted.Count -eq 0) {
            # Nothing named: work out which IDM base DNs VCF Operations does not have yet.
            $idmBases = @(@($out['idm']['directories']) | ForEach-Object { @($_['baseDns']) })
            $opsBases = @(@($out['vcfOperations']['ssoRealms']) | ForEach-Object { @($_['identityProviders']) } | ForEach-Object { @($_['ldapDirectories']) } | ForEach-Object { @($_['baseDns']) })
            $missingList = New-Object System.Collections.ArrayList
            foreach ($b in $idmBases) {
                $have = $false
                foreach ($o in $opsBases) { if ((ConvertTo-NormalDn $o['baseDn']) -eq (ConvertTo-NormalDn $b['baseDn'])) { $have = $true } }
                if (-not $have) { [void]$missingList.Add($b) }
            }
            if ($missingList.Count -eq 0) { Write-Host 'Every IDM base DN is already in VCF Operations. Nothing to add.'; return }
            $missing = Sort-ByKey @($missingList) { param($x) $x['baseDn'].ToLower() }
            $allDns = @($missing | ForEach-Object { [string]$_['baseDn'] })
            if ($AddAllMissing) { $wanted = $allDns }
            else {
                $options = New-Object System.Collections.ArrayList
                if ($missing.Count -gt 1) { [void]$options.Add(@{ Value = '*ALL*'; Text = "All $($missing.Count) of the base DNs below (recommended)" }) }
                foreach ($b in $missing) {
                    $kind = if ([string]$b['baseDn'] -match '^CN=') { 'a single group' } else { 'a CONTAINER: every group under it' }
                    [void]$options.Add(@{ Value = [string]$b['baseDn']; Text = "$($b['baseDn'])  ($kind; $($b['selectedGroups']) of $($b['totalGroups']) selected in IDM)" })
                }
                [void]$options.Add(@{ Value = ''; Text = 'Cancel, add nothing' })
                $pick = Select-Option 'IDM base DNs that VCF Operations does not have. What do you want to add? (Enter = choice 1; nothing is written until you also choose Write and type yes)' @($options) 1
                if (-not $pick) { Write-Host 'Nothing was added.'; return }
                $wanted = if ($pick -eq '*ALL*') { $allDns } else { @($pick) }
            }
            if (-not $Apply) {
                $act = Select-Option 'What do you want to do?' @(
                    @{ Value = 'dry'; Text = 'Dry run: show what would change and write nothing' },
                    @{ Value = 'write'; Text = 'Write it to VCF Operations (you will be asked to type yes)' }) 1
                $write = ($act -eq 'write')
            }
        }
        Invoke-AddBaseDns $out $ops $wanted $write
        return
    }
    $out['calls'] = $script:Calls

    $dir = Get-FullPath $script:OutputPath
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $path = Join-Path $dir $script:OutputFile
    Save-Json $path $out
    Write-Host "Wrote $path (secrets removed; the raw responses are included so the real field names can be checked)"
    if ($failed.Count -gt 0) { Write-Host "  Note: $($failed -join ' and ') could not be read, so the file is incomplete." }
}

function Read-IdmGroups($Idm) {
    $dirs = @(Get-ListItems $Idm.Directories.Body)
    $result = New-Object System.Collections.ArrayList
    foreach ($d in $dirs) {
        $id = $d['directoryId']; if (-not $id) { $id = $d['id'] }
        $name = $d['name']; if (-not $name) { $name = $d['displayName'] }
        $type = [string]$d['type']
        $entry = [ordered]@{ id = $id; name = $name; type = $type; skipped = $null; syncSource = 'none'; baseDns = @(); ignoredBaseDns = @(); nestedGroupMembersSynced = $null; syncSchedule = $null }
        if (-not (Test-SyncableDirectory $type)) {
            $entry['skipped'] = 'local directory'
            Write-Host ("  IDM directory '{0}' ({1}): skipped (local directory, no AD groups to provision)" -f $name, $type)
        }
        elseif ($id) {
            $p = Get-IdmSyncProfile $Idm.Auth ([string]$id)
            if ($p.Response) {
                $body = $p.Response.Body
                $sel = Get-SelectedGroups $body
                $entry['syncSource'] = $p.Source
                $entry['baseDns'] = $sel.BaseDns
                $entry['ignoredBaseDns'] = $sel.IgnoredBaseDns
                $entry['structure'] = $sel.Structure
                if ($sel.Structure -ne 'identityInfo') { $entry['groupDns'] = $sel.GroupDns }
                $ii = $body['identityInfo']
                if ($ii -is [System.Collections.IDictionary] -and $ii.Contains('excludeNestedGroupMembers')) { $entry['nestedGroupMembersSynced'] = -not [bool]$ii['excludeNestedGroupMembers'] }
                $entry['syncSchedule'] = $body['syncSchedule']
                if ($sel.Structure -ne 'identityInfo') { $entry['raw'] = Remove-Secrets $body }   # unfamiliar shape: keep it so it can be inspected
                if ($sel.Structure -eq 'identityInfo') {
                    Write-Host ("  IDM directory '{0}' ({1}): {2} base DN(s) to provision: {3}" -f $name, $type, @($sel.BaseDns).Count, (Format-Bases $sel.BaseDns))
                    if (@($sel.IgnoredBaseDns).Count -gt 0) { Write-Host ("    not used (no group selected): {0}" -f (Format-Bases $sel.IgnoredBaseDns)) }
                }
                else { Write-Host ("  IDM directory '{0}' ({1}): {2} group DN(s) found (unfamiliar sync profile shape, see 'raw')" -f $name, $type, @($entry['groupDns']).Count) }
            }
            else {
                $entry['tried'] = $p.Tried
                Write-Host ("  IDM directory '{0}' ({1}): the sync settings could not be read ({2})" -f $name, $type, ($p.Tried -join '; '))
            }
        }
        [void]$result.Add($entry)
    }
    if ($dirs.Count -eq 0) { Write-Host '  IDM: no directories were returned.' }
    return [ordered]@{ host = $script:IdmHost; directories = $result }
}

function Read-OpsGroups($Ops) {
    $auth = $Ops.Auth
    $realmList = @(Get-ListItems $Ops.Realms.Body)
    if ($SsoDomainId) {
        $one = Invoke-Logged 'ops' GET (Get-OpsUrl "$($script:IamPath)/ssorealms/$SsoDomainId") @{ Authorization = $auth; Accept = 'application/json' }
        if ($one.Status -eq 200 -and $one.Body) { $realmList = @($one.Body) }
        else { Write-Host "  VCF Operations: SSO domain $SsoDomainId was not found as an SSO realm ($($one.Status)); showing all realms instead." }
    }
    $realms = New-Object System.Collections.ArrayList
    foreach ($realm in $realmList) {
        $rid = $realm['id']; if (-not $rid) { $rid = $realm['ssoRealmId'] }
        $rname = $realm['name']; if (-not $rname) { $rname = $realm['displayName'] }
        $re = [ordered]@{ id = $rid; name = $rname; realm = (Remove-Secrets $realm); identityProviders = New-Object System.Collections.ArrayList }
        $idpIds = @(Find-Ids $realm '(?i)idp|identityprovider|provider') | Select-Object -Unique
        if ($idpIds.Count -eq 0) { Write-Host "  VCF Operations: no identity provider id was found in the record of SSO domain '$rname'; see 'realm' in the output file." }
        foreach ($idp in $idpIds) {
            $ie = [ordered]@{ id = $idp; config = $null; ldapDirectories = New-Object System.Collections.ArrayList }
            $cfg = Invoke-Logged 'ops' GET (Get-OpsUrl "$($script:IamPath)/identity-providers/$idp") @{ Authorization = $auth; Accept = 'application/json' }
            if ($cfg.Status -eq 200) { $ie['config'] = Remove-Secrets $cfg.Body }
            $ld = Invoke-Logged 'ops' GET (Get-OpsUrl "$($script:IamPath)/identity-providers/$idp/ldap-directories") @{ Authorization = $auth; Accept = 'application/json' }
            foreach ($dir in @(Get-ListItems $ld.Body)) {
                $did = $dir['ldapConfigurationId']; if (-not $did) { $did = $dir['id'] }; if (-not $did) { $did = $dir['ldapDirectoryId'] }
                $dname = $dir['name']; if (-not $dname) { $dname = $dir['displayName'] }
                $de = [ordered]@{ id = $did; name = $dname; vidbDirectoryId = $dir['vidbDirectoryId']; domains = @($dir['domains']); baseDn = $null
                    numberOfGroups = $dir['numberOfGroups']; numberOfUsers = $dir['numberOfUsers']; lastSyncStatus = $dir['lastSyncStatus']
                    lastSyncAt = (ConvertFrom-EpochMs $dir['lastSyncDateTime']); baseDns = @(); ignoredBaseDns = @(); syncProfileId = $null }
                foreach ($lc in @($ie['config']['provisioningConfig']['ldapConfigurations'])) {   # the base DN is in the provisioning configuration
                    if ($lc -and $lc['ldapConfigurationId'] -eq $did) { $de['baseDn'] = $lc['ldapBindConfiguration']['baseDn'] }
                }
                $tryIds = @($did, $dir['vidbDirectoryId'], $dir['id']) | Where-Object { $_ } | Select-Object -Unique
                foreach ($tid in $tryIds) {
                    $sp = Invoke-Logged 'ops' GET (Get-OpsUrl "$($script:IamPath)/identity-providers/$idp/ldap-directories/$tid/sync-profile") @{ Authorization = $auth; Accept = 'application/json' }
                    $de['syncProfileStatus'] = $sp.Status
                    if ($sp.Status -eq 200 -and $null -ne $sp.Body) {
                        $sel = Get-SelectedGroups $sp.Body
                        $de['baseDns'] = $sel.BaseDns
                        $de['ignoredBaseDns'] = $sel.IgnoredBaseDns
                        $de['structure'] = $sel.Structure
                        if ($sel.Structure -ne 'ldapGroups') { $de['groupDns'] = $sel.GroupDns }
                        $de['syncProfileId'] = $tid
                        if ($sel.Structure -eq 'ldapGroups') {
                            $de['includeNestedGroupsAndMembers'] = $sp.Body['includeNestedGroupsAndMembers']
                            $de['usersChosenIndividually'] = @(@($sp.Body['ldapUsers']) | Where-Object { $_ }).Count
                            $de['syncSchedule'] = $sp.Body['syncSchedule']
                        }
                        else { $de['syncProfile'] = Remove-Secrets $sp.Body }   # unfamiliar shape: keep it so it can be inspected
                        break
                    }
                }
                $found = if ($de['syncProfileStatus'] -ne 200) { "sync profile: HTTP $($de['syncProfileStatus'])" }
                elseif ($de['structure'] -eq 'ldapGroups') {
                    $nested = if ($de['includeNestedGroupsAndMembers'] -eq $true) { 'on' } else { 'off' }
                    "$(@($de['baseDns']).Count) base group DN(s): $(Format-Bases $de['baseDns']); nested groups: $nested"
                }
                elseif ($de['structure'] -eq 'identityInfo') { "$(@($de['baseDns']).Count) base DN(s) provisioned: $(Format-Bases $de['baseDns'])" }
                else { "$(@($de['groupDns']).Count) group DN(s) found (unfamiliar sync profile shape, see 'syncProfile')" }
                Write-Host ("  VCF Operations: domain '{0}' > directory '{1}' ({2} groups, {3} users in the directory): {4}" -f $rname, $dname, $dir['numberOfGroups'], $dir['numberOfUsers'], $found)
                [void]$ie['ldapDirectories'].Add($de)
            }
            [void]$re['identityProviders'].Add($ie)
        }
        [void]$realms.Add($re)
    }
    if ($realmList.Count -eq 0) { Write-Host '  VCF Operations: no SSO domains were returned.' }
    return [ordered]@{ host = $script:OpsHost; ssoRealms = $realms }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Main }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}

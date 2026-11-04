<#
.SYNOPSIS
    Export users, groups and roles from vRA 8.x to JSON (raw + VCFA-shaped). No dependencies.

.DESCRIPTION
    Same logic and output files as export_vra_identity.py, but pure PowerShell (Windows PowerShell 5.1 or 7).
    Run it and answer the prompts; each one shows a default you can accept with Enter.
    The export is read only on the vRA side. Files are written to the folder you choose (default: current folder)
    and overwrite files with the same names.

.PARAMETER Step
    login  - test the login only
    users  - list users (raw output, to check the API works)
    groups - list groups (raw output, to check the API works)
    all    - full export (default from the menu)
    Leave it out to get a menu.

.EXAMPLE
    .\Export-VraIdentity.ps1
.EXAMPLE
    .\Export-VraIdentity.ps1 login
.EXAMPLE
    .\Export-VraIdentity.ps1 all

.NOTES
    Defaults come from the env vars VRA_HOST, VRA_USERNAME, VRA_PASSWORD, VRA_DOMAIN, VRA_PROJECT_USER_DOMAIN
    or the settings below. When input is redirected (no terminal) nothing is prompted and the defaults are used.
    If scripts are blocked:  powershell -ExecutionPolicy Bypass -File .\Export-VraIdentity.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('login', 'users', 'groups', 'all')]
    [string]$Step
)

# ---- Config -----------------------------------------------------------------
# Every value below is asked for in the terminal; what you set here (or in an env var) is only the default.
$script:VraHost = 'https://vra.example.com'   # e.g. 'dev.vra.local' (https:// is added if missing; env VRA_HOST)
if ($env:VRA_HOST) { $script:VraHost = $env:VRA_HOST }
$script:Username = ''      # e.g. 'configurationadmin' (env VRA_USERNAME)
$script:Password = ''      # leave empty to be prompted; never commit it (env VRA_PASSWORD)
$script:Domain = ''        # vIDM domain the login account belongs to, e.g. 'System Domain' or 'corp.example.com' (env VRA_DOMAIN)
# Domains to include in the export (case-insensitive), e.g. @('System Domain','corp.example.com'). Empty = everything.
# One admin login returns principals from all vIDM domains assigned to the org.
$script:IncludeDomains = @('System Domain', 'corp.example.com')   # TODO: set your custom domain
$script:VerifyTls = $false   # asked at the prompt; $false accepts a self-signed certificate (lab). e.g. $true for a CA-signed cert
$script:TimeoutSec = 30      # seconds per request (not asked); e.g. 120 for a slow appliance
$script:OutputDir = (Get-Location).Path   # asked at the prompt; default is the folder you run the script from, e.g. 'C:\exports\customer1'

# vRA role -> VCFA role. Unmapped roles end up in "warnings" of the import file.
# TODO: confirm target role names against your VCFA organization.
$script:RoleMap = [ordered]@{
    # Org roles (VM Apps org in VCFA)
    'org_owner'                     = 'Organization Owner'
    'org_member'                    = 'Organization Member'
    # Service roles
    'automationservice:cloud_admin' = 'Assembler Administrator'
    'automationservice:user'        = 'Assembler User'
    'automationservice:viewer'      = 'Assembler Viewer'
    'catalog:admin'                 = 'Service Broker Administrator'
    'catalog:user'                  = 'Service Broker User'
    'catalog:viewer'                = 'Service Broker Viewer'
    'orchestration:admin'           = 'Orchestrator Administrator'
    'orchestration:designer'        = 'Orchestrator Workflow Designer'
    'orchestration:viewer'          = 'Orchestrator Viewer'
    # Project roles (recorded only; the loader never loads project membership)
    'project:administrators'        = 'Project Administrator'
    'project:members'               = 'Project User'
    'project:viewers'               = 'Project Viewer'
    'project:supervisors'           = 'Project Supervisor'
    # migration:admin has no VCFA equivalent: left unmapped so it shows up as a warning.
}
$script:DirectoryProviderType = 'OAUTH'   # providerType for non-System-Domain users/groups in VCFA; asked at the prompt: OAUTH, LDAP or SAML
# Roles from these services are intentionally not migrated (no warning raised).
$script:IgnoreRolePrefixes = @('saltstack:', 'codestream:')

# Candidate CSP endpoints (first one returning 200 wins). Verify against the appliance Swagger if the export comes back empty.
$script:UserPaths = @('/csp/gateway/am/api/v2/orgs/{org}/users', '/csp/gateway/am/api/orgs/{org}/users')
$script:GroupPaths = @('/csp/gateway/am/api/v2/orgs/{org}/groups', '/csp/gateway/am/api/orgs/{org}/groups', '/csp/gateway/am/api/v3/orgs/{org}/groups')

$script:Steps = @(
    @{ Value = 'login'; Text = 'Test login only (checks host, username, password and domain)' },
    @{ Value = 'users'; Text = 'List users (shows raw output to check the API works)' },
    @{ Value = 'groups'; Text = 'List groups (shows raw output to check the API works)' },
    @{ Value = 'all'; Text = 'Full export (writes vcfa-import.json and backups)' }
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

# ---- vRA API ----------------------------------------------------------------
function Connect-Vra([string]$Username, [string]$Password, [string]$Domain) {
    $login = @{ username = $Username; password = $Password; domain = $Domain } | ConvertTo-Json
    $r = Invoke-Api POST "$($script:VraHost)/csp/gateway/am/api/login?access_token" @{} $login 'application/json'
    if ($r.Status -ne 200) { Die "login failed ($($r.Status)): $(Short $r.Text)" }
    $refresh = $r.Body['refresh_token']

    $r = Invoke-Api POST "$($script:VraHost)/csp/gateway/am/api/auth/api-tokens/authorize" @{} @{ refresh_token = $refresh }
    if ($r.Status -ne 200) { Die "token authorize failed ($($r.Status)): $(Short $r.Text)" }
    $csp = $r.Body['access_token']

    $iaasBody = @{ refreshToken = $refresh } | ConvertTo-Json
    $r = Invoke-Api POST "$($script:VraHost)/iaas/api/login" @{} $iaasBody 'application/json'
    if ($r.Status -ne 200) { Die "iaas login failed ($($r.Status)): $(Short $r.Text)" }
    return @{ Csp = $csp; Iaas = $r.Body['token'] }
}

function Get-VraJson([string]$Path, [string]$Token, $Params = $null) {
    return (Invoke-Api GET ("$($script:VraHost)$Path" + (ConvertTo-Query $Params)) @{ Authorization = "Bearer $Token"; Accept = 'application/json' })
}

function Get-ItemsOf($Body) {
    # CSP/IaaS list responses use different keys; normalise to a list (emitted flat; wrap the call in @()).
    if ($Body -is [array]) { return $Body }
    if ($Body -is [System.Collections.IDictionary]) {
        foreach ($key in 'results', 'content', 'items', 'values') {
            if ($Body.Contains($key) -and ($Body[$key] -is [array])) { return $Body[$key] }
        }
    }
    return
}

function Get-AllVra([string]$Path, [string]$Token, [int]$PageSize = 100, [int]$MaxPages = 50) {
    # Fetch all pages, de-duplicated. Stops when a page adds nothing new (API may ignore paging).
    $out = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $page = 0
    while ($page -lt $MaxPages) {
        $r = Get-VraJson $Path $Token @{ page = $page; size = $PageSize }
        if ($r.Status -ne 200) { return @{ Items = $out.ToArray(); Status = $r.Status } }
        $body = $r.Body
        $batch = @(Get-ItemsOf $body)
        $new = @()
        foreach ($x in $batch) {
            $key = ConvertTo-Json -InputObject $x -Compress -Depth 20
            if (-not $seen.Contains($key)) { $new += , @($x, $key) }
        }
        if ($new.Count -eq 0) { break }
        foreach ($pair in $new) { [void]$seen.Add($pair[1]); [void]$out.Add($pair[0]) }
        $totalPages = $null
        if ($body -is [System.Collections.IDictionary]) { $totalPages = $body['totalPages'] }
        $page++
        if ($batch.Count -lt $PageSize -or ($null -ne $totalPages -and $page -ge $totalPages)) { break }
    }
    return @{ Items = $out.ToArray(); Status = 200 }
}

function Find-FirstWorking($Paths, [string]$Org, [string]$Token) {
    foreach ($p in $Paths) {
        $path = $p.Replace('{org}', $Org)
        $r = Get-AllVra $path $Token
        if ($r.Status -eq 200) { return @{ Path = $path; Items = $r.Items } }
        Write-Host "  $path -> $($r.Status)"
    }
    return @{ Path = $null; Items = @() }
}

function Get-OrgId([string]$Token) {
    $r = Get-VraJson '/csp/gateway/am/api/loggedin/user/orgs' $Token
    if ($r.Status -ne 200) { Die "could not list orgs ($($r.Status)): $(Short $r.Text)" }
    $body = $r.Body
    if ($body -is [System.Collections.IDictionary] -and $body['refLinks']) {
        return (@($body['refLinks'])[0].TrimEnd('/').Split('/')[-1])
    }
    $orgs = @(Get-ItemsOf $body)
    if ($orgs.Count -eq 0 -and $body -is [System.Collections.IDictionary]) {
        if ($body['id'] -or $body['orgId']) { $orgs = @($body) }
        else {
            foreach ($v in $body.Values) {
                if ($v -is [array] -and $v.Count -gt 0 -and $v[0] -is [System.Collections.IDictionary]) { $orgs = @($v); break }
            }
        }
    }
    if ($orgs.Count -gt 0) {
        if ($orgs[0]['id']) { return $orgs[0]['id'] } else { return $orgs[0]['orgId'] }
    }
    # Fallback: the CSP access token carries the org id as 'context_name'
    try {
        $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload + ('=' * ((4 - $payload.Length % 4) % 4))
        $claims = ConvertFrom-JsonText ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)))
        if ($claims['context_name']) { return $claims['context_name'] }
    }
    catch { }
    Die "no orgs found; raw response: $(Short (ConvertTo-Json -InputObject $body -Compress -Depth 10) 500)"
}

# ---- Shaping ----------------------------------------------------------------
function Get-RoleNames($Obj) {
    # Collect role names from the various role fields a CSP object may carry (emitted flat; wrap the call in @()).
    foreach ($key in 'organizationRoles', 'serviceRoles', 'roles') {
        foreach ($role in @($Obj[$key])) {
            if ($null -eq $role) { continue }
            if ($role -is [string]) { $role }
            elseif ($role -is [System.Collections.IDictionary]) {
                if ($role['name']) { $role['name'] }
                foreach ($n in @($role['serviceRoleNames'])) { if ($null -ne $n) { $n } }
                foreach ($sub in @($role['serviceRoles'])) {
                    if ($sub -is [System.Collections.IDictionary] -and $sub['name']) { $sub['name'] }
                }
            }
        }
    }
}

function Get-PrincipalDomain($P) {
    $q = $P['user']; if (-not $q) { $q = $P }
    $d = $q['domain']; if (-not $d) { $d = $q['identityProviderDomain'] }
    if ($d) { return $d }
    foreach ($key in 'username', 'email', 'name') {
        $v = $q[$key]; if (-not $v) { $v = '' }
        if ($v.Contains('@')) { return $v.Split('@', 2)[1] }
    }
    return 'System Domain'
}

function Test-InScope($P) {
    if (-not $script:IncludeDomains -or @($script:IncludeDomains).Count -eq 0) { return $true }
    $dom = (Get-PrincipalDomain $P).ToLower()
    foreach ($d in $script:IncludeDomains) { if ($d.ToLower() -eq $dom) { return $true } }
    return $false
}

function Get-PrincipalName($P) {
    $q = $P['user']; if (-not $q) { $q = $P }
    foreach ($k in 'email', 'username', 'displayName', 'name', 'userId', 'id') { if ($q[$k]) { return $q[$k] } }
    return $null
}

function Test-IgnoredRole([string]$Role) {
    $l = $Role.ToLower()
    foreach ($pre in $script:IgnorePrefixesLower) { if ($l.StartsWith($pre)) { return $true } }
    return $false
}
$script:IgnorePrefixesLower = @($script:IgnoreRolePrefixes | ForEach-Object { $_.ToLower() })

function Get-Upn($U) {
    # VCFA usernames for federated users are the full UPN, e.g. olga@corp.example.com.
    $q = $U['user']; if (-not $q) { $q = $U }
    $name = $q['username']; if (-not $name) { $name = '' }
    $dom = Get-PrincipalDomain $U
    if ($name.Contains('@') -or $dom.ToLower() -eq 'system domain') { return $name }
    return "$name@$dom"
}

function Join-Name($First, $Last) { return ((@($First, $Last) | Where-Object { $_ }) -join ' ') }

function Remove-Empty($Dict) {
    # Keep only keys whose value is truthy (like {k: v for k, v in d.items() if v})
    $out = [ordered]@{}
    foreach ($k in $Dict.Keys) { if ($Dict[$k]) { $out[$k] = $Dict[$k] } }
    return $out
}

function Get-Summary($P) {
    # Flat view of a user or group with its org and service role names (ignored services removed).
    $isUser = $P.Contains('user')
    $u = $P['user']; if (-not $u) { $u = $P }
    $out = [ordered]@{}
    if ($isUser) {
        $out['id'] = $u['userId']
        $out['username'] = $u['username']; $out['domain'] = Get-PrincipalDomain $P; $out['email'] = $u['email']
        $out['firstName'] = $u['firstName']; $out['lastName'] = $u['lastName']
    }
    else {
        $out['id'] = $P['id']
        $out['name'] = Get-PrincipalName $P; $out['domain'] = Get-PrincipalDomain $P; $out['groupType'] = $P['groupType']
        $out['members'] = @(foreach ($x in @($P['members'])) { if ($x -and $x['username']) { Get-Upn $x } })
    }
    $out['organizationRoles'] = @(foreach ($r in @($P['organizationRoles'])) { if ($r -is [System.Collections.IDictionary]) { $r['name'] } })
    $out['serviceRoles'] = @(Get-RoleNames @{ serviceRoles = $P['serviceRoles'] } | Where-Object { -not (Test-IgnoredRole $_) })
    $res = [ordered]@{}
    foreach ($k in $out.Keys) {
        $v = $out[$k]
        if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { continue }
        $res[$k] = $v
    }
    return $res
}

function Get-TrimmedUser($P) {
    # Raw user minus empty/duplicate fields (acct, idpId, accessible, userProfile, per-user orgId)
    $u = $P['user']; if (-not $u) { $u = @{} }
    $user = [ordered]@{}
    foreach ($k in 'username', 'firstName', 'lastName', 'domain', 'email', 'userId') { if ($u[$k]) { $user[$k] = $u[$k] } }
    return [ordered]@{ user = $user; organizationRoles = @($P['organizationRoles']); serviceRoles = @($P['serviceRoles']) }
}

function Get-TrimmedProject($Pr) {
    $out = [ordered]@{}
    foreach ($k in 'id', 'name', 'description', 'administrators', 'members', 'viewers', 'supervisors') { if ($Pr[$k]) { $out[$k] = $Pr[$k] } }
    return $out
}

function Get-Provider([string]$Domain) {
    # vRA System Domain accounts are local; directory accounts are federated into VCFA via OIDC.
    # VCFA reports OIDC identities as providerType OAUTH (use LDAP or SAML for those org types).
    if ($Domain.ToLower() -eq 'system domain') { return 'LOCAL' }
    return $script:DirectoryProviderType
}

function New-VcfaImport {
    # Build the VCFA import. Project members arrive from the IaaS API as bare usernames (no domain), so they are
    # matched against all known users ($AllUsers, in-scope users, group members). Project-only users that match are
    # added to the users with an org_member binding so they can exist in VCFA. Names that match nothing get
    # $DefaultDomain appended if given, else they are listed in unresolvedProjectUsers and the warnings.
    param($Users, $Groups, $Projects, $AllUsers = @(), [string]$DefaultDomain = '')
    $Users = @($Users); $Groups = @($Groups); $Projects = @($Projects); $AllUsers = @($AllUsers)
    $warnings = New-Object System.Collections.ArrayList
    $bindings = New-Object System.Collections.ArrayList

    $bind = {
        param($kind, $name, $scope, $vraRole)
        if (Test-IgnoredRole $vraRole) { return }
        $vcfaRole = $script:RoleMap[$vraRole]
        if (-not $vcfaRole) {
            [void]$warnings.Add("unmapped role '$vraRole' for $kind '$name' ($scope)")
            return
        }
        [void]$bindings.Add([ordered]@{ principalType = $kind; principal = $name; scope = $scope; role = $vcfaRole; vraRole = $vraRole })
    }

    foreach ($u in $Users) { foreach ($role in @(Get-RoleNames $u)) { & $bind 'user' (Get-Upn $u) 'organization' $role } }
    foreach ($g in $Groups) { foreach ($role in @(Get-RoleNames $g)) { & $bind 'group' (Get-PrincipalName $g) 'organization' $role } }

    $impUsers = New-Object System.Collections.ArrayList
    $have = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($u in $Users) {
        $q = $u['user']; if (-not $q) { $q = $u }
        $dom = Get-PrincipalDomain $u
        $rec = Remove-Empty ([ordered]@{ username = (Get-Upn $u); fullName = (Join-Name $q['firstName'] $q['lastName']); email = $q['email']; domain = $dom; providerType = (Get-Provider $dom) })
        [void]$impUsers.Add($rec)
        [void]$have.Add($rec['username'].ToLower())
    }
    $impGroups = New-Object System.Collections.ArrayList
    foreach ($g in $Groups) {
        $dom = Get-PrincipalDomain $g
        $members = @{}
        foreach ($x in @($g['members'])) { if ($x -and $x['username']) { $members[(Get-Upn $x)] = $true } }
        [void]$impGroups.Add([ordered]@{ name = (Get-PrincipalName $g); domain = $dom; providerType = (Get-Provider $dom); members = (Sort-Ordinal $members.Keys) })
    }
    $imp = [ordered]@{ users = $impUsers; groups = $impGroups; roleBindings = $bindings }

    foreach ($g in $Groups) {   # members that are not org users themselves still need to exist in VCFA
        foreach ($x in @($g['members'])) {
            if ($x -and $x['username'] -and -not $have.Contains((Get-Upn $x).ToLower())) {
                [void]$have.Add((Get-Upn $x).ToLower())
                $dom = Get-PrincipalDomain $x
                [void]$impUsers.Add((Remove-Empty ([ordered]@{ username = (Get-Upn $x); email = $x['email']; domain = $dom; fullName = (Join-Name $x['firstName'] $x['lastName']); providerType = (Get-Provider $dom) })))
            }
        }
    }

    # Project roles. Groups keep their name; users are resolved to a UPN and added to the import if missing.
    $directory = @{}
    $memberRecs = @(foreach ($g in $Groups) { foreach ($mm in @($g['members'])) { if ($mm) { $mm } } })
    foreach ($x in (@($Users) + @($AllUsers) + @($memberRecs))) {
        $base = $x['user']; if (-not $base) { $base = $x }
        $keys = @($base['username'], $base['email'])
        if ($base['username']) { $keys += (Get-Upn $x) }
        foreach ($key in $keys) { if ($key -and -not $directory.ContainsKey($key.ToLower())) { $directory[$key.ToLower()] = $x } }
    }
    $orgBound = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($b in $bindings) { if ($b['scope'] -eq 'organization' -and $b['principalType'] -eq 'user') { [void]$orgBound.Add($b['principal'].ToLower()) } }
    $unresolved = New-Object 'System.Collections.Generic.HashSet[string]'
    $projectOnly = New-Object System.Collections.ArrayList

    $projectUser = {
        param($name)
        $found = $directory[$name.ToLower()]
        if ($found) {
            $principal = Get-Upn $found; $domain = Get-PrincipalDomain $found; $rec = $found
        }
        elseif ($DefaultDomain) {
            if ($name.Contains('@')) { $principal = $name } else { $principal = "$name@$DefaultDomain" }
            $domain = $DefaultDomain; $rec = @{ username = $principal }
        }
        else {
            [void]$unresolved.Add($name)
            return $null
        }
        if (-not $have.Contains($principal.ToLower())) {
            [void]$have.Add($principal.ToLower())
            [void]$projectOnly.Add($principal)
            $r = $rec['user']; if (-not $r) { $r = $rec }
            [void]$impUsers.Add((Remove-Empty ([ordered]@{ username = $principal; email = $r['email']; domain = $domain; fullName = (Join-Name $r['firstName'] $r['lastName']); providerType = (Get-Provider $domain) })))
        }
        return $principal
    }

    foreach ($proj in $Projects) {
        foreach ($field in 'administrators', 'members', 'viewers', 'supervisors') {
            foreach ($p in @($proj[$field])) {
                if (-not $p) { continue }
                $name = $p['email']; if (-not $name) { $name = $p['name'] }
                if (-not $name) { continue }
                $scope = "project:$($proj['name'])"
                if ($p['type'] -eq 'group') { & $bind 'group' $name $scope "project:$field" }
                else {
                    $principal = & $projectUser $name
                    if ($principal) { & $bind 'user' $principal $scope "project:$field" }
                }
            }
        }
    }
    foreach ($principal in $projectOnly) {   # a user needs an org role to exist in VCFA; project access implies org membership
        if (-not $orgBound.Contains($principal.ToLower())) { & $bind 'user' $principal 'organization' 'org_member' }
    }
    # Which groups each user belongs to (informational; the loader uses it to tell direct roles from inherited ones).
    $memberOf = @{}
    foreach ($g in $Groups) {
        foreach ($x in @($g['members'])) {
            if ($x -and $x['username']) {
                $uk = (Get-Upn $x).ToLower()
                if (-not $memberOf.ContainsKey($uk)) { $memberOf[$uk] = @{} }
                $memberOf[$uk][(Get-PrincipalName $g)] = $true
            }
        }
    }
    foreach ($u in $impUsers) {
        $uk = $u['username'].ToLower()
        if ($memberOf.ContainsKey($uk)) { $u['memberOf'] = (Sort-Ordinal $memberOf[$uk].Keys) }
    }
    $unresolvedSorted = Sort-Ordinal $unresolved
    foreach ($name in $unresolvedSorted) { [void]$warnings.Add("project member '$name' not found among vRA users (domain unknown): not imported") }
    if ($unresolved.Count -gt 0) { $imp['unresolvedProjectUsers'] = $unresolvedSorted }
    if ($projectOnly.Count -gt 0) { $imp['projectOnlyUsers'] = (Sort-Ordinal $projectOnly) }
    if ($warnings.Count -gt 0) { $imp['warnings'] = $warnings }
    return $imp
}

function New-ExportReportData {
    # The data behind vra-export-report.html (the same shape the Python export builds).
    param($Imp, $Users, $Groups, $Projects, [int]$UsersAll, [int]$GroupsAll, [string]$Org, $DomainsSeen, $Files, $FailedMembers, [string]$OutputDir, $Endpoints)
    $Users = @($Users); $Groups = @($Groups); $Projects = @($Projects)
    $orgRoles = @{}
    foreach ($b in @($Imp['roleBindings'])) {
        if ($b['scope'] -ne 'organization') { continue }
        $k = "$($b['principalType'])|$($b['principal'].ToLower())"
        if (-not $orgRoles.ContainsKey($k)) { $orgRoles[$k] = @{} }
        $orgRoles[$k][$b['role']] = $true
    }
    $rolesOf = {
        param($type, $name)
        $set = $orgRoles["$type|$($name.ToLower())"]
        if ($set) { return (Sort-Ordinal $set.Keys) }
    }
    $projectOnly = @{}; foreach ($n in @($Imp['projectOnlyUsers'])) { if ($n) { $projectOnly[$n.ToLower()] = $true } }

    $map = @{}
    foreach ($b in @($Imp['roleBindings'])) {
        $scope = 'project'; if ($b['scope'] -eq 'organization') { $scope = 'organization' }
        $k = "$($b['vraRole'])|$scope"
        if (-not $map.ContainsKey($k)) { $map[$k] = [ordered]@{ vraRole = $b['vraRole']; role = $b['role']; scope = $scope; bindings = 0 } }
        $map[$k]['bindings']++
    }
    $unmapped = [ordered]@{}
    foreach ($w in @($Imp['warnings'])) {
        $m = [regex]::Match([string]$w, "^unmapped role '(.*?)' for .*\((.*)\)$")
        if (-not $m.Success) { continue }
        $scope = 'project'; if ($m.Groups[2].Value -eq 'organization') { $scope = 'organization' }
        $k = "$($m.Groups[1].Value)|$scope"
        if (-not $map.ContainsKey($k)) { $map[$k] = [ordered]@{ vraRole = $m.Groups[1].Value; role = $null; scope = $scope; bindings = 0 } }
        $map[$k]['bindings']++
        $unmapped[$m.Groups[1].Value] = 1 + [int]$unmapped[$m.Groups[1].Value]
    }
    $roleMapping = Sort-ByKey @($map.Values) { param($x) "$($x['vraRole'])|$($x['scope'])" }

    $groupRows = @(foreach ($g in $Groups) {
            $name = Get-PrincipalName $g
            [ordered]@{ name = $name; domain = (Get-PrincipalDomain $g); type = $g['groupType']; members = @(@($g['members']) | Where-Object { $_ }).Count; roles = @(& $rolesOf 'group' $name) }
        })
    $userRows = @(foreach ($u in @($Imp['users'])) {
            [ordered]@{ name = $u['username']; domain = $u['domain']; memberOf = @(if ($u.Contains('memberOf')) { $u['memberOf'] }); roles = @(& $rolesOf 'user' $u['username']); projectOnly = [bool]$projectOnly.ContainsKey($u['username'].ToLower()) }
        })
    $projectRows = @(foreach ($p in $Projects) {
            [ordered]@{ name = $p['name']; administrators = @(@($p['administrators']) | Where-Object { $_ }).Count; members = @(@($p['members']) | Where-Object { $_ }).Count
                viewers = @(@($p['viewers']) | Where-Object { $_ }).Count; supervisors = @(@($p['supervisors']) | Where-Object { $_ }).Count }
        })

    $attention = New-Object System.Collections.ArrayList
    $failed = @($FailedMembers | Where-Object { $_ })
    if ($failed.Count -gt 0) {
        [void]$attention.Add([ordered]@{ tone = 'warn'; title = 'Group member lists that could not be read. Users in these groups may later look "not inherited from a group" and be loaded directly.'; items = @($failed | ForEach-Object { "$($_['name']) (HTTP $($_['status']))" }) })
    }
    if ($unmapped.Count -gt 0) {
        [void]$attention.Add([ordered]@{ tone = 'warn'; title = 'vRA roles with no VCFA equivalent. They are not migrated.'; items = @((Sort-Ordinal $unmapped.Keys) | ForEach-Object { "$_ ($($unmapped[$_]) use(s))" }) })
    }
    if ($Imp.Contains('unresolvedProjectUsers')) {
        [void]$attention.Add([ordered]@{ tone = 'warn'; title = 'Project members that were not found among the vRA users (domain unknown). They are not imported.'; items = @($Imp['unresolvedProjectUsers']) })
    }
    if ($Imp.Contains('projectOnlyUsers')) {
        [void]$attention.Add([ordered]@{ tone = 'info'; title = 'Users added because they only have project access. They get the Organization Member role so they can exist in VCFA.'; items = @($Imp['projectOnlyUsers']) })
    }

    $selected = @($script:IncludeDomains)
    return [ordered]@{
        kind = 'export'; generatedAt = (Get-Date).ToUniversalTime().ToString('o'); tool = 'PowerShell'
        host = $script:VraHost; org = $Org; outputDir = $OutputDir
        counts = [ordered]@{ users = $Users.Count; usersAll = $UsersAll; usersInImport = @($Imp['users']).Count; groups = $Groups.Count; groupsAll = $GroupsAll; projects = $Projects.Count; bindings = @($Imp['roleBindings']).Count; warnings = @($Imp['warnings']).Count }
        domainsSeen = @($DomainsSeen); domainsSelected = $selected; providerType = $script:DirectoryProviderType
        endpoints = [ordered]@{ users = $Endpoints['users']; groups = $Endpoints['groups'] }
        attention = $attention; roleMapping = $roleMapping; groups = $groupRows; users = $userRows; projects = $projectRows; files = @($Files)
    }
}

function Write-Dump([string]$Name, $Data) {
    if (-not (Test-Path -LiteralPath $script:OutputDir)) { [void](New-Item -ItemType Directory -Path $script:OutputDir -Force) }
    $path = Join-Path (Get-FullPath $script:OutputDir) $Name
    Save-Json $path $Data
    Write-Host "Wrote $path"
    return $path
}

function First-Set { foreach ($a in $args) { if ($a) { return $a } }; return '' }

# ---- Main -------------------------------------------------------------------
function Main {
    # Usage: .\Export-VraIdentity.ps1 [login|users|groups|all]   (no argument = menu)
    $step = $Step
    if (-not $step) { $step = Select-Option 'What do you want to do?' $script:Steps 4 }

    $script:VraHost = Read-HostUrl 'vRA host (FQDN; https:// is added for you)' $script:VraHost 'dev.vra.local'
    Set-TlsPolicy (Confirm-Yes 'Verify the TLS certificate? (answer n for a self-signed certificate)' $script:VerifyTls)
    $username = Read-Value 'vRA username' (First-Set $script:Username $env:VRA_USERNAME) -Example 'configurationadmin'
    $password = First-Set $script:Password $env:VRA_PASSWORD
    if (-not $password) { $password = Read-Value 'vRA password' -Secret }
    $domain = Read-Value 'vIDM domain of the login account' (First-Set $env:VRA_DOMAIN $script:Domain) -Example 'System Domain or corp.example.com'
    if ($step -ne 'login') {
        $script:OutputDir = Read-Value 'Folder for the output files' $script:OutputDir -Example 'C:\exports\customer1'
    }
    if ($step -eq 'all') {
        $shown = (@($script:IncludeDomains) -join ', '); if (-not $shown) { $shown = 'all' }
        $answer = Read-Value "Domains to export (comma-separated, or 'all')" $shown -Example 'corp.example.com, System Domain'
        if ($answer.ToLower() -eq 'all') { $script:IncludeDomains = @() }
        else { $script:IncludeDomains = @($answer.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $script:DirectoryProviderType = (Read-Value 'How VCFA authenticates directory users/groups (OAUTH, LDAP or SAML)' $script:DirectoryProviderType).ToUpper()
        if ($script:DirectoryProviderType -notin @('OAUTH', 'LDAP', 'SAML')) {
            Die "provider type must be OAUTH, LDAP or SAML, not '$($script:DirectoryProviderType)'"
        }
    }
    if (-not ($username -and $password)) { Die 'username and password are required' }

    Write-Host "Logging in to $($script:VraHost) ..."
    $tokens = Connect-Vra $username $password $domain
    $cspToken = $tokens.Csp; $iaasToken = $tokens.Iaas
    $org = Get-OrgId $cspToken
    Write-Host "LOGIN OK. Org: $org"
    if ($step -eq 'login') { return }

    if ($step -in @('users', 'groups')) {
        $paths = if ($step -eq 'users') { $script:UserPaths } else { $script:GroupPaths }
        $r = Find-FirstWorking $paths $org $cspToken
        $items = @($r.Items)
        Write-Host "  $($items.Count) $step via $($r.Path)"
        $counts = [ordered]@{}
        foreach ($x in $items) { $d = Get-PrincipalDomain $x; if ($counts.Contains($d)) { $counts[$d]++ } else { $counts[$d] = 1 } }
        Write-Host ("  by domain: " + ((@($counts.Keys) | ForEach-Object { "$_=$($counts[$_])" }) -join ', '))
        if ($items.Count -gt 0) {
            Write-Host ('  first item keys: ' + ((Sort-Ordinal $items[0].Keys) -join ', '))
            Write-Host ('  first item: ' + (Short (ConvertTo-Json -InputObject $items[0] -Compress -Depth 20) 800))
        }
        [void](Write-Dump "step-$step.json" ([ordered]@{ endpoint = $r.Path; items = $items }))
        return
    }

    Write-Host 'Fetching users ...'
    $ur = Find-FirstWorking $script:UserPaths $org $cspToken
    $allUsers = @($ur.Items)
    $users = @($allUsers | Where-Object { Test-InScope $_ })
    Write-Host "  $($users.Count)/$($allUsers.Count) users in selected domains via $($ur.Path)"

    Write-Host 'Fetching groups ...'
    $gr = Find-FirstWorking $script:GroupPaths $org $cspToken
    $allGroups = @($gr.Items)
    $groups = @($allGroups | Where-Object { Test-InScope $_ })
    $failedMembers = New-Object System.Collections.ArrayList
    foreach ($g in $groups) {
        $m = Get-AllVra "$($gr.Path)/$($g['id'])/users" $cspToken
        $members = @()
        if ($m.Status -ne 200) { [void]$failedMembers.Add([ordered]@{ name = (Get-PrincipalName $g); status = $m.Status }) }
        if ($m.Status -eq 200) {
            $members = @(foreach ($x in $m.Items) {
                    $mm = [ordered]@{}
                    foreach ($k in 'userId', 'username', 'domain', 'email', 'firstName', 'lastName') { if ($x[$k]) { $mm[$k] = $x[$k] } }
                    $mm
                })
        }
        $g['members'] = $members
    }
    Write-Host "  $($groups.Count)/$($allGroups.Count) groups in selected domains via $($gr.Path)"
    if ($failedMembers.Count -gt 0) {
        Write-Host "  WARNING: the member list of $($failedMembers.Count) group(s) could not be read: $((@($failedMembers | ForEach-Object { $_['name'] })) -join ', '). Users in them may later be loaded as 'not inherited from a group'."
    }
    $seenDomains = Sort-Ordinal (@(($allUsers + $allGroups) | ForEach-Object { Get-PrincipalDomain $_ }) | Select-Object -Unique)
    Write-Host ('  domains seen: ' + ($seenDomains -join ', '))

    Write-Host 'Fetching projects ...'
    $pr = Get-AllVra '/iaas/api/projects' $iaasToken
    if ($pr.Status -ne 200) { Write-Host "  projects returned $($pr.Status); skipping project roles" }
    $projects = @($pr.Items)
    Write-Host "  $($projects.Count) projects"

    $raw = [ordered]@{
        meta     = [ordered]@{
            host          = $script:VraHost
            orgId         = $org
            exportedAt    = (Get-Date).ToUniversalTime().ToString('o')
            userEndpoint  = $ur.Path
            groupEndpoint = $gr.Path
        }
        users    = @($users | ForEach-Object { Get-TrimmedUser $_ })
        groups   = $groups
        projects = @($projects | ForEach-Object { Get-TrimmedProject $_ })
    }
    $imp = New-VcfaImport $users $groups $projects $allUsers
    if ($imp.Contains('unresolvedProjectUsers')) {
        Write-Host "  $(@($imp['unresolvedProjectUsers']).Count) project users not found among vRA users: $(@($imp['unresolvedProjectUsers']) -join ', ')"
        $dom = Read-Value 'Domain to use for these users (blank = skip them)' $env:VRA_PROJECT_USER_DOMAIN -Example 'corp.example.com'
        if ($dom) { $imp = New-VcfaImport $users $groups $projects $allUsers $dom }
    }
    if ($imp.Contains('projectOnlyUsers')) {
        Write-Host "  $(@($imp['projectOnlyUsers']).Count) users have project access but no org role or group; added to the import"
    }

    $written = New-Object System.Collections.ArrayList
    [void]$written.Add((Write-Dump 'vra-export.json' $raw))
    [void]$written.Add((Write-Dump 'vcfa-import.json' $imp))
    [void]$written.Add((Write-Dump 'users.json' @($users | ForEach-Object { Get-Summary $_ })))
    [void]$written.Add((Write-Dump 'groups.json' @($groups | ForEach-Object { Get-Summary $_ })))
    if ($imp.Contains('warnings')) {
        Write-Host "$(@($imp['warnings']).Count) warnings (unmapped roles) - see vcfa-import.json"
    }
    $reportPath = Join-Path (Get-FullPath $script:OutputDir) 'vra-export-report.html'
    $files = @($written) + @($reportPath)
    $report = New-ExportReportData -Imp $imp -Users $users -Groups $groups -Projects $projects -UsersAll $allUsers.Count -GroupsAll $allGroups.Count `
        -Org $org -DomainsSeen $seenDomains -Files $files -FailedMembers @($failedMembers) -OutputDir (Get-FullPath $script:OutputDir) `
        -Endpoints @{ users = $ur.Path; groups = $gr.Path }
    [void](Write-HtmlReport $reportPath $report)
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Main }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}

<#
.SYNOPSIS
    Load an import file (vcfa-import.json) into VCF Automation (VCFA). DRY RUN unless you choose Apply. No dependencies.

.DESCRIPTION
    Same logic as load_vcfa.py, but pure PowerShell (Windows PowerShell 5.1 or 7).
    Run it with no arguments for the full wizard (host, org, login method, what to import, name filter, action).
    With any parameter, only the missing values are asked and the action is a dry run unless -Apply (or -LoginOnly).
    By default it loads the groups plus the users whose roles are NOT inherited from a group they are in
    (users with no roles, or whose roles all come from their groups, are left to the IdP group claim).
    -GroupsOnly loads no users; -Users loads every user; naming a user in -Only loads that user.
    Project roles are never loaded. Apply stops if a role the plan needs does not exist in VCFA
    (unless -AllowMissingRoles) and re-reads VCFA afterwards to check the roles.

.PARAMETER Apply
    Really create objects (default is a dry run).
.PARAMETER LoginOnly
    Only test the login and stop.
.PARAMETER Org
    VCFA org (tenant) name. Asked if missing.
.PARAMETER BrowserToken
    Log in with a browser session token (asked, hidden, if not set in VCFA_BROWSER_TOKEN).
.PARAMETER BearerFile
    Log in with a browser token saved in a file (raw token or a 'Copy as fetch' capture).
.PARAMETER Provider
    The API token is a System-org (provider) token; act inside -Org via tenant context.
.PARAMETER Users
    Load ALL users from the import file (default: groups plus only the users whose roles are not inherited from groups).
.PARAMETER GroupsOnly
    Load groups only, no users at all (users are then created at their first SSO login, without direct roles).
.PARAMETER Only
    Load just these groups or users, e.g. -Only 'Infra-Admins@corp.example.com'. Naming a user includes users.
.PARAMETER ImportFile
    Import file to read (default vcfa-import.json).
.PARAMETER AllowMissingRoles
    Apply even if some roles do not exist in VCFA (those users get fewer roles).

.EXAMPLE
    .\Import-Vcfa.ps1
.EXAMPLE
    .\Import-Vcfa.ps1 -BrowserToken -LoginOnly
.EXAMPLE
    .\Import-Vcfa.ps1 -BrowserToken -ImportFile example-vcfa-import.json
.EXAMPLE
    .\Import-Vcfa.ps1 -BrowserToken -Only 'Infra-Admins@corp.example.com' -Apply

.NOTES
    Defaults come from the env vars VCFA_HOST, VCFA_ORG, VCFA_USERNAME, VCFA_PASSWORD, VCFA_API_TOKEN,
    VCFA_BROWSER_TOKEN, VCFA_API_VERSION or the settings below. When input is redirected nothing is prompted.
    If scripts are blocked:  powershell -ExecutionPolicy Bypass -File .\Import-Vcfa.ps1
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$AllowMissingRoles,
    [string]$ImportFile,
    [switch]$LoginOnly,
    [string]$Org,
    [switch]$Provider,
    [string]$BearerFile,
    [switch]$BrowserToken,
    [switch]$Users,
    [switch]$GroupsOnly,
    [string[]]$Only = @()
)

# Computed here, not inside a function: inside Main, $PSBoundParameters would be Main's own (always empty).
$script:NoFlags = ($PSBoundParameters.Count -eq 0)   # plain run with no parameters = full wizard

# ---- Config -----------------------------------------------------------------
# Every value below is asked for in the terminal; what you set here (or in an env var) is only the default.
$script:VcfaHost = 'https://vcfa.example.com'   # e.g. 'dev.vcfa.local' (https:// is added if missing; env VCFA_HOST)
if ($env:VCFA_HOST) { $script:VcfaHost = $env:VCFA_HOST }
$script:OrgName = 'my-org'                       # tenant/org name, e.g. 'finance-org' (env VCFA_ORG)
if ($env:VCFA_ORG) { $script:OrgName = $env:VCFA_ORG }
$script:VerifyTls = $false   # asked at the prompt; $false accepts a self-signed certificate (lab). e.g. $true for a CA-signed cert
$script:TimeoutSec = 30      # seconds per request (not asked); e.g. 120 for a slow appliance
$script:ApiVersion = '40.0'  # cloudapi version (not asked); e.g. '40.0' (env VCFA_API_VERSION)
if ($env:VCFA_API_VERSION) { $script:ApiVersion = $env:VCFA_API_VERSION }
$script:ImportPath = 'vcfa-import.json'   # asked at the prompt (or -ImportFile); e.g. 'example-vcfa-import.json'
$script:PlanFile = 'vcfa-plan.json'       # dry-run/apply plan is written here
$script:ReportFile = 'vcfa-load-report.html'   # the readable summary of the run is written here
$script:ApiToken = ''       # for OIDC/SSO orgs: API token created in the VCFA UI (env VCFA_API_TOKEN); prompted if you pick that login method
$script:BrowserTokenValue = ''   # browser session token, raw or a 'Copy as fetch' capture (env VCFA_BROWSER_TOKEN); prompted for the browser method
$script:VcfaUsername = ''   # e.g. 'configurationadmin' (env VCFA_USERNAME)
$script:VcfaPassword = ''   # leave empty to be prompted; never commit it (env VCFA_PASSWORD)

$script:AuthMethods = @(
    @{ Value = 'browser'; Text = 'Browser session token (needed to create users/groups on SSO orgs)' },
    @{ Value = 'file'; Text = "Browser token saved in a file (raw token or 'Copy as fetch' capture)" },
    @{ Value = 'api'; Text = 'Tenant API token' },
    @{ Value = 'provider'; Text = 'System-org (provider) API token' },
    @{ Value = 'password'; Text = 'Username and password' }
)
$script:Actions = @(
    @{ Value = 'login'; Text = 'Test login only (checks host, org and credentials; changes nothing)' },
    @{ Value = 'dry'; Text = 'Dry run (shows the plan, writes vcfa-plan.json; changes nothing)' },
    @{ Value = 'apply'; Text = 'Apply (really creates groups/users in VCFA)' }
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

# ---- VCFA API ---------------------------------------------------------------
function Get-HeaderValue($Headers, [string]$Name) {
    if ($null -eq $Headers) { return $null }
    foreach ($k in $Headers.Keys) {
        if ("$k".ToLower() -eq $Name.ToLower()) {
            $v = $Headers[$k]
            if ($v -is [array]) { $v = $v[0] }
            return $v
        }
    }
    return $null
}

function New-VcfaHeaders([string]$Token) {
    return @{ Authorization = "Bearer $Token"; Accept = "application/json;version=$($script:ApiVersion)" }
}

function Read-BrowserToken([string]$Default = '') {
    # Pasting a whole multi-line 'Copy as fetch' into a prompt breaks: only the first line is read and the rest would
    # answer the next questions. So Enter on an empty line reads the clipboard instead, which can hold any amount of text.
    if (-not (Test-Interactive)) { return $Default }
    $v = Read-Secret 'Browser token (paste ONLY the token, or just press Enter to read it from the clipboard)'
    if ($v) { return $v }
    if ($Default) { return $Default }
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { $clip = '' }
    if ($clip.Trim()) { Write-Host '  Read the token from the clipboard.'; return $clip }
    Write-Host '  The clipboard is empty. Copy the request in the browser first, or save it to a file and use -BearerFile.'
    return ''
}

function Get-Credentials {
    $user = Read-Value 'VCFA username' (First-Set $env:VCFA_USERNAME $script:VcfaUsername) -Example 'configurationadmin'
    $pw = First-Set $env:VCFA_PASSWORD $script:VcfaPassword
    if (-not $pw) { $pw = Read-Value 'VCFA password' -Secret }
    if (-not ($user -and $pw)) { Die 'username and password are required' }
    return @{ User = $user; Password = $pw }
}

function Connect-VcfaPassword([string]$User, [string]$Password) {
    # Tenant login (cloudapi sessions). The user name is used as given; the org is not appended.
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${User}:$Password"))
    $r = Invoke-Api POST "$($script:VcfaHost)/cloudapi/1.0.0/sessions" @{ Authorization = "Basic $basic"; Accept = "application/json;version=$($script:ApiVersion)" }
    if ($r.Status -notin @(200, 201)) { Die "login failed ($($r.Status)): $(Short $r.Text)" }
    $token = Get-HeaderValue $r.Headers 'X-VMWARE-VCLOUD-ACCESS-TOKEN'
    if (-not $token) { Die 'login returned no X-VMWARE-VCLOUD-ACCESS-TOKEN header' }
    return @{ Headers = (New-VcfaHeaders $token); Session = $r.Body }
}

function Connect-VcfaApiToken([string]$ApiToken, [string]$OrgName) {
    # For OIDC/SSO orgs: exchange an API token (created in the UI) for an access token.
    $r = Invoke-Api POST "$($script:VcfaHost)/oauth/tenant/$OrgName/token" @{} @{ grant_type = 'refresh_token'; refresh_token = $ApiToken }
    if ($r.Status -ne 200) { Die "API token exchange failed ($($r.Status)): $(Short $r.Text)" }
    $headers = New-VcfaHeaders $r.Body['access_token']
    $r = Invoke-Api GET "$($script:VcfaHost)/cloudapi/1.0.0/sessions/current" $headers
    if ($r.Status -ne 200) { Die "could not read current session ($($r.Status)): $(Short $r.Text)" }
    return @{ Headers = $headers; Session = $r.Body }
}

function Get-BearerToken([string]$Text) {
    # Pull the token out of whatever was given: a raw token, 'Bearer <token>', a quoted token, or a copied request
    # ('Copy as fetch', 'Copy as cURL' or 'Copy as PowerShell').
    $m = [regex]::Match($Text, '(?i)authorization["'']?\s*[:=]\s*["'']?Bearer\s+([A-Za-z0-9._~+/=\-]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    $t = $Text.Trim().Trim('"', "'").Trim()
    return ($t -replace '(?i)^bearer\s+', '').Trim()
}

function Connect-VcfaBearer([string]$Text, [string]$Source) {
    # A browser session token, raw or inside a copied request (the token is extracted, never printed).
    $token = Get-BearerToken $Text
    if (-not $token -or $token.Length -lt 20) { Die "no bearer token found in $Source" }
    if ($token -match '\s') {
        Die "the text from $Source has spaces or line breaks and no 'authorization: Bearer ...' header, so it is not a token. Copy only the token, or copy the whole request and press Enter at the token prompt (reads the clipboard), or save it to a file and use -BearerFile"
    }
    $headers = New-VcfaHeaders $token
    $r = Invoke-Api GET "$($script:VcfaHost)/cloudapi/1.0.0/sessions/current" $headers
    if ($r.Status -ne 200) { Die "browser token rejected ($($r.Status)) - it probably expired; capture a fresh one: $(Short $r.Text 200)" }
    return @{ Headers = $headers; Session = $r.Body }
}

function Connect-VcfaProvider([string]$ApiToken, [string]$OrgName) {
    # System-org (provider) API token: exchange at /oauth/provider/token, then act inside the org via tenant context.
    $r = Invoke-Api POST "$($script:VcfaHost)/oauth/provider/token" @{} @{ grant_type = 'refresh_token'; refresh_token = $ApiToken }
    if ($r.Status -ne 200) { Die "provider API token exchange failed ($($r.Status)): $(Short $r.Text)" }
    $headers = New-VcfaHeaders $r.Body['access_token']
    $filter = [uri]::EscapeDataString("name==$OrgName")
    $r = Invoke-Api GET "$($script:VcfaHost)/cloudapi/1.0.0/orgs?filter=$filter" $headers
    if ($r.Status -ne 200 -or -not $r.Body['values']) { Die "could not find org '$OrgName' as provider ($($r.Status)): $(Short $r.Text)" }
    $o = @($r.Body['values'])[0]
    return @{ Headers = $headers; Session = @{ org = @{ name = $o['name']; id = $o['id'] }; roles = @('(provider)') } }
}

function Get-AllVcfa([string]$Path, [hashtable]$Headers, [int]$PageSize = 128, [int]$MaxPages = 200) {
    $out = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le $MaxPages; $page++) {
        $r = Invoke-Api GET "$($script:VcfaHost)${Path}?page=$page&pageSize=$PageSize" $Headers
        if ($r.Status -ne 200) { Die "GET $Path failed ($($r.Status)): $(Short $r.Text)" }
        foreach ($v in @($r.Body['values'])) { if ($null -ne $v) { [void]$out.Add($v) } }
        $pageCount = 1
        if ($r.Body['pageCount']) { $pageCount = [int]$r.Body['pageCount'] }
        if ($page -ge $pageCount) { break }
    }
    return $out.ToArray()
}

function Send-Vcfa([string]$Method, [string]$Path, [hashtable]$Headers, $Body) {
    $json = ConvertTo-Json -InputObject $Body -Depth 30
    return (Invoke-Api $Method "$($script:VcfaHost)$Path" $Headers $json 'application/json')
}

# ---- Plan -------------------------------------------------------------------
function Get-NormRole([string]$Name) {
    # Compare role names ignoring case, spaces/punctuation and Admin/Administrator.
    $s = $Name.ToLower().Replace('administrator', 'admin')
    return (-join ($s.ToCharArray() | Where-Object { [char]::IsLetterOrDigit($_) }))
}

function Get-PlanRefs($Ctx, [string]$Kind, [string]$Key) {
    # Roles to set on one principal, in VCFA's own spelling (emitted flat; wrap the call in @()).
    $names = $Ctx.OrgRoles["$Kind|$Key"]
    if (-not $names) { return }
    $unique = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($n in $names) { [void]$unique.Add($n) }
    foreach ($name in (Sort-Ordinal $unique)) {
        $r = $Ctx.VcfaRoles[(Get-NormRole $name)]
        if ($r) { [ordered]@{ name = $r['name']; id = $r['id'] } }
        else {
            if ($Ctx.MissingRoles.Contains($name)) { $Ctx.MissingRoles[$name]++ } else { $Ctx.MissingRoles[$name] = 1 }
            $k = $Key.ToLower()
            if (-not $Ctx.MissingBy.ContainsKey($k)) { $Ctx.MissingBy[$k] = New-Object 'System.Collections.Generic.HashSet[string]' }
            [void]$Ctx.MissingBy[$k].Add($name)
        }
    }
}

function Add-PlanSync($Ctx, [string]$Kind, [string]$Name, [string]$Key, $Existing) {
    # Existing object: add the vRA roles it lacks (never removes roles it already has).
    $have = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in @($Existing['roleEntityRefs'])) { if ($r) { [void]$have.Add([string]$r['id']) } }
    $add = @(Get-PlanRefs $Ctx $Kind $Key | Where-Object { -not $have.Contains([string]$_['id']) })
    if ($add.Count -gt 0) {
        $body = [ordered]@{}
        foreach ($k in $Existing.Keys) { $body[$k] = $Existing[$k] }
        $body['roleEntityRefs'] = @(@($Existing['roleEntityRefs']) | Where-Object { $_ }) + $add
        [void]$Ctx.Updates.Add([ordered]@{ type = $Kind; name = $Name; path = "/cloudapi/1.0.0/${Kind}s/$($Existing['id'])"; adding = @($add | ForEach-Object { $_['name'] }); body = $body })
    }
}

function Get-DirectUsers($Imp) {
    # Users that need loading because some of their roles are NOT inherited from a group they are in.
    # Returns username (lower) -> the role names their groups do not give them. Users with no roles, and users whose
    # roles all come from their groups, are left out: the IdP group claim covers them at their first login.
    $own = @{}; $groupRoles = @{}
    foreach ($b in @($Imp['roleBindings'])) {
        if ($b['scope'] -ne 'organization') { continue }
        $table = $own
        if ($b['principalType'] -eq 'group') { $table = $groupRoles }
        $k = $b['principal'].ToLower()
        if (-not $table.ContainsKey($k)) { $table[$k] = @{} }
        $table[$k][(Get-NormRole $b['role'])] = $b['role']
    }
    $viaGroup = @{}
    foreach ($g in @($Imp['groups'])) {
        $gr = $groupRoles[$g['name'].ToLower()]
        foreach ($m in @($g['members'])) {
            if (-not $m) { continue }
            $mk = $m.ToLower()
            if (-not $viaGroup.ContainsKey($mk)) { $viaGroup[$mk] = New-Object 'System.Collections.Generic.HashSet[string]' }
            if ($gr) { foreach ($rk in $gr.Keys) { [void]$viaGroup[$mk].Add($rk) } }
        }
    }
    $out = [ordered]@{}
    foreach ($u in @($Imp['users'])) {
        $k = $u['username'].ToLower()
        $mine = $own[$k]
        if (-not $mine) { continue }
        $inherited = $viaGroup[$k]
        $extra = @(foreach ($rk in (Sort-Ordinal $mine.Keys)) { if (-not ($inherited -and $inherited.Contains($rk))) { $mine[$rk] } })
        if ($extra.Count -gt 0) { $out[$k] = $extra }
    }
    return $out
}

function New-Plan($Imp, $Roles, $ExistingUsers, $ExistingGroups) {
    $ctx = @{
        VcfaRoles    = @{}
        OrgRoles     = @{}
        MissingRoles = [ordered]@{}
        MissingBy    = @{}
        Updates      = New-Object System.Collections.ArrayList
    }
    foreach ($r in @($Roles)) { $ctx.VcfaRoles[(Get-NormRole $r['name'])] = $r }   # tolerant match: 'Assembler Admin' == 'Assembler Administrator'
    $haveUsers = @{}; foreach ($u in @($ExistingUsers)) { $n = $u['username']; if (-not $n) { $n = '' }; $haveUsers[$n.ToLower()] = $u }
    $haveGroups = @{}; foreach ($g in @($ExistingGroups)) { $n = $g['name']; if (-not $n) { $n = '' }; $haveGroups[$n.ToLower()] = $g }

    $skippedProject = 0
    $projectBindings = [ordered]@{}   # project scope -> bindings; VCFA project membership is not loaded here
    foreach ($b in @($Imp['roleBindings'])) {
        if ($b['scope'] -ne 'organization') {
            $skippedProject++
            if (-not $projectBindings.Contains($b['scope'])) { $projectBindings[$b['scope']] = New-Object System.Collections.ArrayList }
            [void]$projectBindings[$b['scope']].Add([ordered]@{ type = $b['principalType']; principal = $b['principal']; role = $b['role'] })
            continue
        }
        $k = "$($b['principalType'])|$($b['principal'])"
        if (-not $ctx.OrgRoles.ContainsKey($k)) { $ctx.OrgRoles[$k] = New-Object System.Collections.ArrayList }
        [void]$ctx.OrgRoles[$k].Add($b['role'])
    }

    $creates = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    foreach ($u in @($Imp['users'])) {
        $key = $u['username']
        if ($haveUsers.ContainsKey($key.ToLower())) {
            [void]$skipped.Add([ordered]@{ type = 'user'; name = $key; reason = 'already exists' })
            Add-PlanSync $ctx 'user' $key $key $haveUsers[$key.ToLower()]
            continue
        }
        if ($u['providerType'] -eq 'LOCAL') {
            [void]$skipped.Add([ordered]@{ type = 'user'; name = $key; reason = 'local user: needs a password, create manually' })
            continue
        }
        # Same body the VCFA UI sends for "add user" (org comes from the tenant-context header).
        $body = [ordered]@{ username = $key; enabled = $true; providerType = $u['providerType']; roleEntityRefs = @(Get-PlanRefs $ctx 'user' $key); inheritGroupRoles = $true }
        [void]$creates.Add([ordered]@{ type = 'user'; path = '/cloudapi/1.0.0/users'; body = $body })
    }
    foreach ($g in @($Imp['groups'])) {
        $name = $g['name']
        if ($haveGroups.ContainsKey($name.ToLower())) {
            [void]$skipped.Add([ordered]@{ type = 'group'; name = $name; reason = 'already exists' })
            Add-PlanSync $ctx 'group' $name $name $haveGroups[$name.ToLower()]
            continue
        }
        # Same body the VCFA UI sends for "add group" (org comes from the tenant-context header).
        $body = [ordered]@{ name = $name; providerType = $g['providerType']; roleEntityRefs = @(Get-PlanRefs $ctx 'group' $name); description = '' }
        [void]$creates.Add([ordered]@{ type = 'group'; path = '/cloudapi/1.0.0/groups'; body = $body })
    }

    $mapping = [ordered]@{}   # role name in the import file -> VCFA role name it resolves to ($null = not found)
    foreach ($b in @($Imp['roleBindings'])) {
        if ($b['scope'] -eq 'organization') {
            $r = $ctx.VcfaRoles[(Get-NormRole $b['role'])]
            $mapping[$b['role']] = if ($r) { $r['name'] } else { $null }
        }
    }
    $missingBy = [ordered]@{}
    foreach ($k in $ctx.MissingBy.Keys) { $missingBy[$k] = Sort-Ordinal $ctx.MissingBy[$k] }
    $localWithRoles = @(foreach ($u in @($Imp['users'])) {
            if ($u['providerType'] -eq 'LOCAL' -and $ctx.OrgRoles.ContainsKey("user|$($u['username'])")) {
                $uniq = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($n in $ctx.OrgRoles["user|$($u['username'])"]) { [void]$uniq.Add($n) }
                [ordered]@{ name = $u['username']; roles = (Sort-Ordinal $uniq) }
            }
        })
    return [ordered]@{
        creates                   = $creates
        updates                   = $ctx.Updates
        skipped                   = $skipped
        missingRoles              = $ctx.MissingRoles
        directUsers               = (Get-DirectUsers $Imp)
        localUsersWithRoles       = $localWithRoles
        roleMapping               = $mapping
        missingByPrincipal        = $missingBy
        projectBindingsNotHandled = $skippedProject
        projectBindings           = $projectBindings
    }
}

function Get-ObjName($Create) {
    $n = $Create['body']['username']; if (-not $n) { $n = $Create['body']['name'] }
    return $n
}

function Get-ExpectedRoles($Plan) {
    # One entry per planned object: the VCFA role names the plan sets (new objects: all; existing: the roles being added).
    $out = New-Object System.Collections.ArrayList
    foreach ($c in @($Plan['creates'])) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in @($c['body']['roleEntityRefs'])) { if ($r) { [void]$set.Add($r['name'].ToLower()) } }
        [void]$out.Add(@{ Type = $c['type']; Name = (Get-ObjName $c).ToLower(); Roles = $set })
    }
    foreach ($c in @($Plan['updates'])) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in @($c['body']['roleEntityRefs'])) { if ($r) { [void]$set.Add($r['name'].ToLower()) } }
        [void]$out.Add(@{ Type = $c['type']; Name = $c['name'].ToLower(); Roles = $set })
    }
    return $out.ToArray()
}

function Get-BlockedByMissingRoles($Plan) {
    # Planned objects whose vRA roles do not all exist in VCFA, so they would end up with fewer roles.
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in @(Get-ExpectedRoles $Plan)) { [void]$wanted.Add($e.Name) }
    $out = [ordered]@{}
    foreach ($k in $Plan['missingByPrincipal'].Keys) { if ($wanted.Contains($k)) { $out[$k] = $Plan['missingByPrincipal'][$k] } }
    return $out
}

function Test-VcfaRoles($Plan, [hashtable]$Headers) {
    # Re-read VCFA after apply and compare each planned object's roles with what vRA had. Returns the mismatches.
    $actual = @{}
    foreach ($pair in @(@('user', '/cloudapi/1.0.0/users'), @('group', '/cloudapi/1.0.0/groups'))) {
        foreach ($o in @(Get-AllVcfa $pair[1] $Headers)) {
            $n = $o['username']; if (-not $n) { $n = $o['name'] }; if (-not $n) { $n = '' }
            $set = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($r in @($o['roleEntityRefs'])) { if ($r) { [void]$set.Add($r['name'].ToLower()) } }
            $actual["$($pair[0])|$($n.ToLower())"] = $set
        }
    }
    $bad = New-Object System.Collections.ArrayList
    foreach ($e in @(Get-ExpectedRoles $Plan)) {
        $have = $actual["$($e.Type)|$($e.Name)"]
        if ($null -eq $have) { [void]$bad.Add([ordered]@{ type = $e.Type; name = $e.Name; problem = 'not found in VCFA' }) }
        else {
            $lacking = @($e.Roles | Where-Object { -not $have.Contains($_) })
            if ($lacking.Count -gt 0) { [void]$bad.Add([ordered]@{ type = $e.Type; name = $e.Name; problem = 'missing roles: ' + ((Sort-Ordinal $lacking) -join ', ') }) }
        }
    }
    return $bad.ToArray()
}

function Read-ImportFile([string]$Path) {
    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full)) { Die "import file not found: $full" }
    return (ConvertFrom-JsonText ([System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)))
}

function Get-ImportNames([int]$Limit = 15) {
    # Short list of names in the import file, to help pick a single group/user for a test.
    try { $imp = Read-ImportFile $script:ImportPath } catch { return '' }
    $some = {
        param($label, $items)
        $items = @($items)
        if ($items.Count -eq 0) { return '' }
        $more = ''
        if ($items.Count -gt $Limit) { $more = " (+$($items.Count - $Limit) more)" }
        return "$($items.Count) ${label}: " + (($items | Select-Object -First $Limit) -join ', ') + $more
    }
    $parts = @((& $some 'groups' @($imp['groups'] | ForEach-Object { $_['name'] })), (& $some 'users' @($imp['users'] | ForEach-Object { $_['username'] }))) | Where-Object { $_ }
    return ($parts -join '; ')
}

function Get-ObjRoles($Create) { return @(@($Create['body']['roleEntityRefs']) | ForEach-Object { $_['name'] }) }

function New-LoadReportData($Run) {
    # The data behind vcfa-load-report.html (the same shape the Python loader builds).
    $plan = $Run.Plan; $imp = $Run.Imp
    $direct = $plan['directUsers']
    $pending = 'planned'; if ($Run.Mode -ne 'dry-run') { $pending = 'not applied' }
    $resultOf = { param($type, $name) $r = $Run.Results["$type|$name"]; if ($r) { $r } else { $pending } }
    $groupRows = New-Object System.Collections.ArrayList
    $userRows = New-Object System.Collections.ArrayList
    $loaded = New-Object 'System.Collections.Generic.HashSet[string]'
    $nCreateGroups = 0; $nCreateUsers = 0
    foreach ($c in @(@($plan['creates']) + @($plan['updates']))) {
        $isCreate = $c.Contains('path') -and -not $c.Contains('adding')
        if ($isCreate) { $name = Get-ObjName $c; $roles = Get-ObjRoles $c; $action = 'create' } else { $name = $c['name']; $roles = @($c['adding']); $action = 'add roles' }
        $roles = Sort-Ordinal $roles
        $row = [ordered]@{ name = $name; action = $action; roles = $roles }
        if ($c['type'] -eq 'group') {
            if ($isCreate) { $nCreateGroups++ }
            $row['result'] = & $resultOf 'group' $name
            [void]$groupRows.Add($row)
        }
        else {
            if ($isCreate) { $nCreateUsers++ }
            $extra = @(); if ($direct.Contains($name.ToLower())) { $extra = @($direct[$name.ToLower()]) }
            $row['notInherited'] = $extra
            $row['result'] = & $resultOf 'user' $name
            [void]$userRows.Add($row)
            [void]$loaded.Add($name.ToLower())
        }
    }
    $groupRowsSorted = Sort-ByKey @($groupRows) { param($x) $x['name'].ToLower() }
    $userRowsSorted = Sort-ByKey @($userRows) { param($x) $x['name'].ToLower() }

    $skippedUsers = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in @($plan['skipped'])) { if ($s['type'] -eq 'user') { [void]$skippedUsers.Add($s['name'].ToLower()) } }
    $own = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($b in @($imp['roleBindings'])) { if ($b['scope'] -eq 'organization' -and $b['principalType'] -eq 'user') { [void]$own.Add($b['principal'].ToLower()) } }
    $notLoaded = New-Object System.Collections.ArrayList
    foreach ($u in @($imp['users'])) {
        $k = $u['username'].ToLower()
        if ($loaded.Contains($k) -or $skippedUsers.Contains($k)) { continue }
        $why = 'all of their roles come from their groups'
        if (@($Run.Only).Count -gt 0) { $why = 'not selected with -Only' }
        elseif ($Run.UserMode -eq 'none') { $why = 'groups-only mode' }
        elseif (-not $own.Contains($k)) { $why = 'no roles of their own' }
        [void]$notLoaded.Add([ordered]@{ name = $u['username']; reason = $why })
    }

    $mapping = New-Object System.Collections.ArrayList
    foreach ($src in (Sort-Ordinal $plan['roleMapping'].Keys)) { [void]$mapping.Add([ordered]@{ source = $src; target = $plan['roleMapping'][$src] }) }
    $missing = New-Object System.Collections.ArrayList
    foreach ($r in (Sort-Ordinal $plan['missingRoles'].Keys)) { [void]$missing.Add([ordered]@{ role = $r; count = $plan['missingRoles'][$r] }) }
    $blockedList = New-Object System.Collections.ArrayList
    $blockedMap = Get-BlockedByMissingRoles $plan
    foreach ($n in (Sort-Ordinal $blockedMap.Keys)) { [void]$blockedList.Add([ordered]@{ name = $n; roles = @($blockedMap[$n]) }) }
    $projects = New-Object System.Collections.ArrayList
    foreach ($scope in (Sort-Ordinal $plan['projectBindings'].Keys)) { [void]$projects.Add([ordered]@{ project = ($scope -replace '^project:', ''); bindings = @($plan['projectBindings'][$scope]).Count }) }
    $skipped = @(foreach ($s in @($plan['skipped'])) { [ordered]@{ type = $s['type']; name = $s['name']; reason = $s['reason'] } })

    return [ordered]@{
        kind = 'load'; generatedAt = (Get-Date).ToUniversalTime().ToString('o'); tool = 'PowerShell'
        host = $Run.Host; org = $Run.Org; importFile = $Run.ImportFile; mode = $Run.Mode; userMode = $Run.UserMode; only = @($Run.Only)
        vcfa = [ordered]@{ roles = $Run.Vcfa.roles; users = $Run.Vcfa.users; groups = $Run.Vcfa.groups }
        counts = [ordered]@{ groups = $nCreateGroups; users = $nCreateUsers; updates = @($plan['updates']).Count; skipped = $skipped.Count; notLoaded = $notLoaded.Count
            created = $Run.Created; failed = $Run.Failed; updated = $Run.Updated; updateFailed = $Run.UpdateFailed }
        roleMapping = $mapping; missingRoles = $missing; blocked = $blockedList
        groups = $groupRowsSorted; users = $userRowsSorted; notLoaded = $notLoaded; skipped = $skipped
        localUsers = @($plan['localUsersWithRoles']); projects = $projects
        roleCheck = $Run.RoleCheck; failures = @($Run.Failures)
    }
}

function Save-LoadReport($Run) {
    [void](Write-HtmlReport (Get-FullPath $script:ReportFile) (New-LoadReportData $Run))
}

function First-Set { foreach ($a in $args) { if ($a) { return $a } }; return '' }

# ---- Main -------------------------------------------------------------------
function Main {
    $noFlags = $script:NoFlags
    if ($Users -and $GroupsOnly) { Die 'choose either -Users (all users) or -GroupsOnly, not both' }
    $groupsOnly = [bool]$GroupsOnly
    $org = $Org; $withUsers = [bool]$Users; $only = @($Only | Where-Object { $_ })
    $useBrowser = [bool]$BrowserToken; $bearerFile = $BearerFile; $useProvider = [bool]$Provider
    $loginOnly = [bool]$LoginOnly; $apply = [bool]$Apply
    if ($ImportFile) { $script:ImportPath = $ImportFile }

    $script:VcfaHost = Read-HostUrl 'VCFA host (FQDN; https:// is added for you)' $script:VcfaHost 'dev.vcfa.local'
    if (-not $org) { $org = Read-Value 'VCFA org (tenant) name' $script:OrgName -Example 'finance-org' }
    Set-TlsPolicy (Confirm-Yes 'Verify the TLS certificate? (answer n for a self-signed certificate)' $script:VerifyTls)
    if (-not $ImportFile) { $script:ImportPath = Read-Value 'Import file to load' $script:ImportPath -Example 'vcfa-import.json' }
    if (-not $org) { Die 'set the tenant with -Org <name> or VCFA_ORG' }

    $apiToken = First-Set $env:VCFA_API_TOKEN $script:ApiToken
    $tokenText = First-Set $env:VCFA_BROWSER_TOKEN $script:BrowserTokenValue
    $explicit = $useBrowser -or $bearerFile -or $useProvider
    if ($noFlags) {
        $method = Select-Option 'How do you want to log in?' $script:AuthMethods
        if ($method -eq 'browser') {
            $useBrowser = $true
            $tokenText = Read-BrowserToken $tokenText
        }
        elseif ($method -eq 'file') { $bearerFile = Read-Value 'Path to the token file' -Example 'C:\temp\token.txt' }
        elseif ($method -in @('api', 'provider')) {
            $useProvider = ($method -eq 'provider')
            $apiToken = Read-Value 'Paste the API token (hidden)' $apiToken -Secret
        }
        else { $apiToken = ''; $tokenText = '' }   # password: ignore stored tokens so the username/password path is used
        $what = Select-Option 'What to import?' @(
            @{ Value = 'free'; Text = 'Groups, plus users whose roles are not inherited from a group (recommended)' },
            @{ Value = 'none'; Text = 'Groups only (users are then created at first SSO login)' },
            @{ Value = 'all'; Text = 'Groups and ALL users' })
        $withUsers = ($what -eq 'all'); $groupsOnly = ($what -eq 'none')
        $names = Get-ImportNames
        if ($names) { Write-Host ("In $($script:ImportPath): " + $names) }
        $wantedText = Read-Value 'Only this group or user (blank = everything, comma-separated for several)' -Example 'Infra-Admins@corp.example.com'
        $only = @($wantedText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $action = Select-Option 'What do you want to do?' $script:Actions 2
        $loginOnly = ($action -eq 'login'); $apply = ($action -eq 'apply')
        if ($apply -and (Read-Value "Type 'yes' to really create objects in VCFA") -ne 'yes') { Die 'not confirmed; nothing was changed' }
    }

    if ($useBrowser -or ($tokenText -and -not $apiToken -and -not $explicit)) {
        if (-not $tokenText) { $tokenText = Read-BrowserToken }
        if (-not $tokenText) { Die '-BrowserToken: no token given (paste it at the prompt, or set VCFA_BROWSER_TOKEN)' }
        Write-Host "Logging in to $($script:VcfaHost) with the browser session token ..."
        $login = Connect-VcfaBearer $tokenText 'VCFA_BROWSER_TOKEN'
    }
    elseif ($bearerFile) {
        Write-Host "Logging in to $($script:VcfaHost) with the browser session token from $bearerFile ..."
        $full = Get-FullPath $bearerFile
        if (-not (Test-Path -LiteralPath $full)) { Die "token file not found: $full" }
        $login = Connect-VcfaBearer ([System.IO.File]::ReadAllText($full)) $bearerFile
    }
    elseif ($apiToken -or $useProvider) {
        if (-not $apiToken) { $apiToken = Read-Value 'Paste the API token (hidden)' -Secret }
        if (-not $apiToken) { Die '-Provider: no API token given (paste it at the prompt, or set VCFA_API_TOKEN)' }
        Write-Host "Logging in to $($script:VcfaHost) org '$org' with an API token ..."
        if ($useProvider) { $login = Connect-VcfaProvider $apiToken $org } else { $login = Connect-VcfaApiToken $apiToken $org }
    }
    else {
        $cred = Get-Credentials
        Write-Host "Logging in to $($script:VcfaHost) as $($cred.User) ..."
        $login = Connect-VcfaPassword $cred.User $cred.Password
    }
    $headers = $login.Headers
    $session = $login.Session
    $orgInfo = $session['org']; if (-not $orgInfo) { $orgInfo = @{} }
    $orgName = $orgInfo['name']; if (-not $orgName) { $orgName = $org }
    $orgId = $orgInfo['id']
    # The UI sends these two context headers on every call; the API rejects writes without them (403).
    $headers['x-vmware-vcloud-auth-context'] = if ($useProvider) { 'system' } else { $org }
    $idText = if ($orgId) { [string]$orgId } else { '' }
    $headers['x-vmware-vcloud-tenant-context'] = $idText.Split(':')[-1]
    Write-Host "LOGIN OK. Org: name=$orgName id=$orgId  roles on session: $(@($session['roles']) -join ', ')"
    if ($loginOnly) { return }
    $imp = Read-ImportFile $script:ImportPath

    $roles = @(Get-AllVcfa '/cloudapi/1.0.0/roles' $headers)
    $vusers = @(Get-AllVcfa '/cloudapi/1.0.0/users' $headers)
    $vgroups = @(Get-AllVcfa '/cloudapi/1.0.0/groups' $headers)
    Write-Host "VCFA has $($roles.Count) roles, $($vusers.Count) users, $($vgroups.Count) groups"

    $plan = New-Plan $imp $roles $vusers $vgroups
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($n in $only) { [void]$wanted.Add($n.ToLower()) }
    foreach ($u in @($imp['users'])) { if ($wanted.Contains($u['username'].ToLower())) { $withUsers = $true; $groupsOnly = $false } }   # naming a user means "load that user"
    $mode = 'free'
    if ($withUsers) { $mode = 'all' } elseif ($groupsOnly) { $mode = 'none' }
    $direct = $plan['directUsers']
    if ($mode -eq 'none') {
        $plan['creates'] = @(@($plan['creates']) | Where-Object { $_['type'] -eq 'group' })
        $plan['updates'] = @(@($plan['updates']) | Where-Object { $_['type'] -eq 'group' })
    }
    elseif ($mode -eq 'free') {   # groups, plus users with roles their groups do not already give them
        $plan['creates'] = @(@($plan['creates']) | Where-Object { $_['type'] -eq 'group' -or $direct.Contains((Get-ObjName $_).ToLower()) })
        $plan['updates'] = @(@($plan['updates']) | Where-Object { $_['type'] -eq 'group' -or $direct.Contains($_['name'].ToLower()) })
    }
    if ($only.Count -gt 0) {
        if ($withUsers) {
            foreach ($g in @($imp['groups'])) {   # a group is only usable with its member users, so pull them in too
                if ($wanted.Contains($g['name'].ToLower())) { foreach ($m in @($g['members'])) { if ($m) { [void]$wanted.Add($m.ToLower()) } } }
            }
        }
        $plan['creates'] = @(@($plan['creates']) | Where-Object { $wanted.Contains((Get-ObjName $_).ToLower()) })
        $plan['updates'] = @(@($plan['updates']) | Where-Object { $wanted.Contains($_['name'].ToLower()) })
        if (@($plan['creates']).Count -eq 0 -and @($plan['updates']).Count -eq 0) {
            Die "-Only $($only -join ', '): nothing to create or update (name not in the import file, or already up to date)"
        }
    }
    $nU = @(@($plan['creates']) | Where-Object { $_['type'] -eq 'user' }).Count
    $nG = @(@($plan['creates']) | Where-Object { $_['type'] -eq 'group' }).Count
    Write-Host "Plan: create $nU users, $nG groups; skip $(@($plan['skipped']).Count); add roles to $(@($plan['updates']).Count) existing"
    $loadedUsers = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in @($plan['creates'])) { if ($c['type'] -eq 'user') { [void]$loadedUsers.Add((Get-ObjName $c).ToLower()) } }
    foreach ($c in @($plan['updates'])) { if ($c['type'] -eq 'user') { [void]$loadedUsers.Add($c['name'].ToLower()) } }
    $loadedSorted = Sort-Ordinal $loadedUsers
    if ($mode -eq 'free') {
        $detail = ''
        if ($loadedSorted.Count -gt 0) {
            $shown = @($loadedSorted | Select-Object -First 15 | ForEach-Object { "${_}: $(@($direct[$_]) -join ', ')" })
            $more = ''
            if ($loadedSorted.Count -gt 15) { $more = "; +$($loadedSorted.Count - 15) more" }
            $detail = ' (' + ($shown -join '; ') + $more + ')'
        }
        Write-Host "Users loaded because their roles are not inherited from a group: $($loadedSorted.Count)$detail"
    }
    elseif ($mode -eq 'none') { Write-Host 'Users: none (-GroupsOnly). They are created at their first SSO login, without direct roles.' }
    if (@($plan['localUsersWithRoles']).Count -gt 0 -and $mode -ne 'none') {
        Write-Host ('Local users with roles are NOT created (they need passwords); create them by hand in VCFA: ' + ((@($plan['localUsersWithRoles']) | ForEach-Object { "$($_['name']) ($(@($_['roles']) -join ', '))" }) -join '; '))
    }
    Write-Host 'Role mapping (role in the import file -> VCFA role):'
    foreach ($src in (Sort-Ordinal $plan['roleMapping'].Keys)) {
        $dst = $plan['roleMapping'][$src]; if (-not $dst) { $dst = 'NOT FOUND in VCFA' }
        Write-Host "  $src -> $dst"
    }
    if ($plan['projectBindingsNotHandled'] -gt 0) {
        Write-Host "Project roles ($($plan['projectBindingsNotHandled']) in $($plan['projectBindings'].Count) projects) are only recorded in the export, never loaded; listed under projectBindings in $($script:PlanFile)"
    }
    if ($plan['missingRoles'].Count -gt 0) {
        Write-Host 'Roles not found in VCFA (fix RoleMap in Export-VraIdentity.ps1):'
        foreach ($name in (Sort-Ordinal $plan['missingRoles'].Keys)) { Write-Host "  ${name}: $($plan['missingRoles'][$name])" }
    }
    Write-Host ('VCFA role names available: ' + ((Sort-Ordinal @($roles | ForEach-Object { $_['name'] })) -join ', '))
    foreach ($c in @($plan['updates'])) { Write-Host "  update $($c['type']) $($c['name']): add $(@($c['adding']) -join ', ')" }

    $blocked = Get-BlockedByMissingRoles $plan
    if ($blocked.Count -gt 0) {
        Write-Host "$($blocked.Count) planned objects would get FEWER roles than in vRA because the role does not exist in VCFA:"
        foreach ($name in (Sort-Ordinal $blocked.Keys)) { Write-Host "  ${name}: $(@($blocked[$name]) -join ', ')" }
    }
    Save-Json (Get-FullPath $script:PlanFile) $plan
    $run = @{ Host = $script:VcfaHost; Org = $orgName; ImportFile = $script:ImportPath; Mode = 'dry-run'; UserMode = $mode; Only = $only
        Vcfa = @{ roles = $roles.Count; users = $vusers.Count; groups = $vgroups.Count }; Plan = $plan; Imp = $imp
        Results = @{}; Failures = (New-Object System.Collections.ArrayList); RoleCheck = $null; Created = 0; Failed = 0; Updated = 0; UpdateFailed = 0 }
    if (-not $apply) {
        Write-Host "DRY RUN - nothing created. Wrote $($script:PlanFile). Re-run with -Apply to create."
        Save-LoadReport $run
        return
    }
    if ($blocked.Count -gt 0 -and -not $AllowMissingRoles) {
        $run.Mode = 'blocked'
        Save-LoadReport $run
        Die 'not applying: fix RoleMap (or create the roles in VCFA), or pass -AllowMissingRoles to accept fewer roles'
    }
    $run.Mode = 'applied'

    foreach ($c in @($plan['creates'])) {
        $r = Send-Vcfa POST $c['path'] $headers $c['body']
        $name = Get-ObjName $c
        if ($r.Status -in @(200, 201)) { $run.Created++; $run.Results["$($c['type'])|$name"] = 'created' }
        else {
            $run.Failed++; $run.Results["$($c['type'])|$name"] = "failed (HTTP $($r.Status))"
            [void]$run.Failures.Add([ordered]@{ type = $c['type']; name = $name; detail = "HTTP $($r.Status) $(Short $r.Text 200)" })
            Write-Host "  FAILED $($c['type']) ${name}: $($r.Status) $(Short $r.Text 200)"
        }
    }
    Write-Host "Done: $($run.Created) created, $($run.Failed) failed"
    foreach ($c in @($plan['updates'])) {
        $r = Send-Vcfa PUT $c['path'] $headers $c['body']
        if ($r.Status -in @(200, 201)) { $run.Updated++; $run.Results["$($c['type'])|$($c['name'])"] = 'updated' }
        else {
            $run.UpdateFailed++; $run.Results["$($c['type'])|$($c['name'])"] = "failed (HTTP $($r.Status))"
            [void]$run.Failures.Add([ordered]@{ type = $c['type']; name = $c['name']; detail = "update HTTP $($r.Status) $(Short $r.Text 200)" })
            Write-Host "  FAILED update $($c['type']) $($c['name']): $($r.Status) $(Short $r.Text 200)"
        }
    }
    if (@($plan['updates']).Count -gt 0) { Write-Host "Roles added on existing objects: $($run.Updated) updated, $($run.UpdateFailed) failed" }
    $bad = @(Test-VcfaRoles $plan $headers)
    $total = @(Get-ExpectedRoles $plan).Count
    Write-Host "Role check: $($total - $bad.Count)/$total objects have the same org/service roles as in vRA"
    foreach ($b in $bad) { Write-Host "  MISMATCH $($b['type']) $($b['name']): $($b['problem'])" }
    $run.RoleCheck = [ordered]@{ total = $total; matched = ($total - $bad.Count); mismatches = @($bad) }
    Save-LoadReport $run
    if ($plan['projectBindingsNotHandled'] -gt 0) {
        Write-Host "Note: $($plan['projectBindingsNotHandled']) project role bindings are recorded only; this script does not load projects."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Main }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}

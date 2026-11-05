<#
.SYNOPSIS
    Tests for Start-MigrationUI.ps1: the command builder (offline), and the local server (HTTP guards, runs against
    closed ports, refusals, busy and cancel). No Pester, no internet, nothing written to the output folders.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Ui.ps1
#>
$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Say([string]$Text) { [Console]::Out.WriteLine($Text) }
function Assert-True($Cond, [string]$Name) {
    if ($Cond) { $script:Pass++ } else { $script:Fail++; Say "FAIL: $Name" }
}
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ([string]$Actual -ceq [string]$Expected) { $script:Pass++ }
    else { $script:Fail++; Say "FAIL: $Name`n   expected: $Expected`n   actual:   $Actual" }
}

$here = $PSScriptRoot
$uiScript = Join-Path $here 'Start-MigrationUI.ps1'
. $uiScript      # dot-sourced: defines the functions and does not start the server

# Fixed Python answer so the offline tests do not depend on this machine's Python.
$script:PyInfo = @{ ok = $true; exe = 'C:\Python\python.exe'; label = 'test' }
$folder = Join-Path $here 'examples'
# Made-up values for the tests only (not real credentials).
$tok = 'eyJhbGciOiJSUzI1NiJ9.TESTFAKE1234567890abcdefghijk' # pragma: allowlist secret

function Get-Spec([string]$Action, [string]$Engine, $Values) {
    return New-RunSpec $Action $Engine $folder ([pscustomobject]$Values)
}

# ---- 1. Command builder (offline) -------------------------------------------
$vra = @{ vraHost = 'dev.vra.local'; vraUsername = 'configurationadmin'; vraPassword = 'Pw-Secret-XYZ'; vraDomain = 'System Domain' } # pragma: allowlist secret
$s = Get-Spec 'export-login' 'powershell' $vra
Assert-True $s.Ok 'export-login builds'
Assert-True ($s.Args -match '-File "?.*Export-VraIdentity\.ps1"? -Step login$') 'export-login PowerShell command'
Assert-Equal $s.Env['VRA_PASSWORD'] 'Pw-Secret-XYZ' 'password goes to the environment' # pragma: allowlist secret
Assert-True (-not ($s.Args -match 'Pw-Secret')) 'password is not on the command line'
Assert-True (-not ($s.Display -match 'Pw-Secret')) 'password is not in the display line'
Assert-Equal $s.Env['VRA_HOST'] 'dev.vra.local' 'vRA host goes to VRA_HOST'
Assert-True (-not $s.Console) 'export is not a console step'

$s = Get-Spec 'export-all' 'python' $vra
Assert-True $s.Ok 'export-all python builds'
Assert-True ($s.Args -match 'export_vra_identity\.py"? all$') 'python export is "all"'
Assert-Equal $s.Env['PYTHONIOENCODING'] 'utf-8' 'python gets UTF-8 output'
Assert-Equal $s.Exe 'C:\Python\python.exe' 'python exe comes from the probe'

$s = Get-Spec 'export-all' 'powershell' @{ vraHost = 'dev.vra.local'; vraUsername = 'u'; vraPassword = 'p'; vraProjectDomain = 'corp.example.com' } # pragma: allowlist secret
Assert-Equal $s.Env['VRA_PROJECT_USER_DOMAIN'] 'corp.example.com' 'project user domain is passed'
Assert-True (-not $s.Env.ContainsKey('VRA_DOMAIN')) 'empty domain is not passed'

$s = Get-Spec 'export-all' 'powershell' @{ vraHost = 'dev.vra.local'; vraUsername = 'u' }
Assert-True (-not $s.Ok) 'export without password is refused'

# Domains and TLS: the page sends them, the scripts read them from the environment
$s = Get-Spec 'export-domains' 'powershell' $vra
Assert-True ($s.Ok -and $s.Args -match '-Step domains$') 'export-domains lists the domains (PowerShell)'
Assert-Equal $s.Env['VRA_DOMAINS'] 'all' 'export-domains: no filter (the listing ignores it)'
$s = Get-Spec 'export-domains' 'python' $vra
Assert-True ($s.Ok -and $s.Args -match 'export_vra_identity\.py"? domains$') 'export-domains lists the domains (Python)'
$s = Get-Spec 'export-login' 'powershell' $vra
Assert-Equal $s.Env['VRA_VERIFY_TLS'] 'false' 'TLS: off by default (self-signed lab)'
$s = Get-Spec 'export-login' 'python' ($vra + @{ verifyTls = $true })
Assert-Equal $s.Env['VRA_VERIFY_TLS'] 'true' 'TLS: on is passed to the Python export'
$s = Get-Spec 'export-login' 'powershell' ($vra + @{ verifyTls = 'false' })
Assert-Equal $s.Env['VRA_VERIFY_TLS'] 'false' 'TLS: the text "false" counts as off'
$s = Get-Spec 'export-all' 'powershell' ($vra + @{ vraDomains = 'corp.example.com, System Domain' })
Assert-Equal $s.Env['VRA_DOMAINS'] 'corp.example.com,System Domain' 'domains: the chosen names are passed as a list'
$s = Get-Spec 'export-all' 'python' ($vra + @{ vraDomains = 'all' })
Assert-Equal $s.Env['VRA_DOMAINS'] 'all' 'domains: all is passed as all (Python)'
$s = Get-Spec 'export-all' 'powershell' $vra
Assert-Equal $s.Env['VRA_DOMAINS'] 'all' 'domains: no choice means all'
$s = Get-Spec 'export-all' 'powershell' ($vra + @{ vraDomains = ' , ' })
Assert-True (-not $s.Ok) 'domains: a list with no names is refused'
$s = Get-Spec 'export-all' 'powershell' ($vra + @{ vraDomains = 'corp"x' })
Assert-True (-not $s.Ok) 'domains: a quote in a name is refused'
$loadVals = @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'finance-org'; vcfaMethod = 'browser'; vcfaToken = $tok }
$s = Get-Spec 'load-dry' 'powershell' ($loadVals + @{ verifyTls = $true })
Assert-Equal $s.Env['VCFA_VERIFY_TLS'] 'true' 'TLS: on is passed to the VCFA loader'
$s = Get-Spec 'load-dry' 'python' $loadVals
Assert-Equal $s.Env['VCFA_VERIFY_TLS'] 'false' 'TLS: off is passed to the Python loader'
$syncVals = @{ idmHost = 'idm.corp.local'; opsHost = 'ops.corp.local'; idmMethod = 'token'; idmToken = $tok; opsMethod = 'token'; opsToken = $tok }
$s = Get-Spec 'sync-extract' 'powershell' ($syncVals + @{ verifyTls = $true })
Assert-Equal $s.Env['SYNC_VERIFY_TLS'] 'true' 'TLS: on is passed to the identity source step'
$html = Get-Content -LiteralPath (Join-Path $here 'migration-ui.html') -Raw
Assert-True ($html -match 'id="verify-tls"' -and $html -match 'data-run="export-domains"') 'page: TLS box and domain button exist'

# Page layout and token boxes: IDM and VCF Operations side by side, each with its own login fields
$idmCol = $html.IndexOf('id="idm-h"'); $opsCol = $html.IndexOf('id="ops-h"'); $ssoRow = $html.IndexOf('class="sso-row"')
Assert-True ($idmCol -gt 0 -and $opsCol -gt $idmCol -and $ssoRow -gt $opsCol) 'page: IDM column, then VCF Operations column, then the SSO row'
Assert-True ($html.IndexOf('id="idm-user"') -gt $idmCol -and $html.IndexOf('id="idm-pass"') -lt $opsCol -and $html.IndexOf('id="idm-tok-in"') -lt $opsCol) 'page: IDM username, password and token are inside the IDM column'
Assert-True ($html.IndexOf('id="ops-user"') -gt $opsCol -and $html.IndexOf('id="ops-pass"') -lt $ssoRow -and $html.IndexOf('id="ops-tok-in"') -lt $ssoRow) 'page: VCF Operations username, password and token are inside its column'
Assert-True ($html -match 'type="password" id="vcfa-tok-in"' -and $html -match 'type="password" id="idm-tok-in"' -and $html -match 'type="password" id="ops-tok-in"') 'page: token boxes are password fields (a token is never shown)'
Assert-True (-not ($html -match '<textarea id="(vcfa|idm|ops)-tok-in"')) 'page: no token box is a text area'
Assert-True (-not ($html -match 'id="drawer"')) 'page: the fixed output drawer is gone'
Assert-True ($html -match 'id="btn-browse-import"' -and $html -match 'data-cancel') 'page: Browse button for the import file, cancel in the result panel'


$load = @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'finance-org'; vcfaToken = $tok; vcfaMethod = 'browser'; importFile = 'vcfa-import.json' }
$s = Get-Spec 'load-dry' 'powershell' $load
Assert-True $s.Ok 'load-dry builds'
Assert-True ($s.Args -match '-BrowserToken') 'browser token flag'
Assert-True (-not ($s.Args -match '-Apply')) 'dry run has no -Apply'
Assert-Equal $s.Env['VCFA_BROWSER_TOKEN'] $tok 'browser token goes to the environment'
Assert-True (-not $s.Env.ContainsKey('VCFA_API_TOKEN')) 'only the chosen token is set'
Assert-True ($s.Args -match '-Org finance-org') 'org flag'

# Import file from the Browse dialog: a full path with spaces is quoted and reaches both loaders unchanged
$browsed = 'C:\My Exports\customer 1\vcfa-import.json'
$browsedVals = $load.Clone(); $browsedVals['importFile'] = $browsed     # a copy: the key is replaced, not added twice
$s = Get-Spec 'load-dry' 'powershell' $browsedVals
Assert-True ($s.Ok -and $s.Args.Contains('-ImportFile "' + $browsed + '"')) 'browsed import file: quoted for PowerShell'
$s = Get-Spec 'load-dry' 'python' $browsedVals
Assert-True ($s.Ok -and $s.Args.Contains('--import-file "' + $browsed + '"')) 'browsed import file: quoted for Python'
$quoteVals = $load.Clone(); $quoteVals['importFile'] = 'C:\x"y.json'
$s = Get-Spec 'load-dry' 'powershell' $quoteVals
Assert-True (-not $s.Ok) 'an import file path with a quote is refused'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; vcfaMethod = 'api'; scope = 'groups' }
Assert-True ($s.Args -match '-ApiToken' -and $s.Args -match '-GroupsOnly') 'api token and groups-only flags'
Assert-Equal $s.Env['VCFA_API_TOKEN'] $tok 'api token goes to VCFA_API_TOKEN'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; scope = 'users' }
Assert-True ($s.Args -match '-Users' -and -not ($s.Args -match '-GroupsOnly')) 'users flag only'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; scope = 'only'; only = @('Infra-Admins@corp.example.com', 'olga@corp.example.com') }
Assert-True ($s.Args -match '-Only Infra-Admins@corp\.example\.com olga@corp\.example\.com') 'several -Only names, one argument each'
Assert-Equal $s.Only "Infra-Admins@corp.example.com`nolga@corp.example.com" 'only names are recorded for the page'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; scope = 'free'; only = @('Infra-Admins@corp.example.com') }
Assert-True (-not ($s.Args -match '-Only')) 'names left in the box are ignored unless the scope is "only"'
Assert-Equal $s.Only '' 'no names are recorded for the other scopes'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; scope = 'only'; only = @() }
Assert-True (-not $s.Ok) 'scope "only" with no names is refused'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; scope = 'only'; only = @('-Apply') }
Assert-True (-not $s.Ok) 'a name that starts with a dash is refused'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = $tok; scope = 'only'; only = @('a"b') }
Assert-True (-not $s.Ok) 'a name with a quote is refused'

$s = Get-Spec 'load-login' 'powershell' $load
Assert-True ($s.Args -match '-LoginOnly' -and -not ($s.Args -match '-Apply')) 'login step uses -LoginOnly'

$s = Get-Spec 'load-apply' 'powershell' ($load + @{ confirm = '' })
Assert-True (-not $s.Ok) 'apply without typed yes is refused'

$s = Get-Spec 'load-apply' 'powershell' ($load + @{ confirm = 'yes'; allowMissingRoles = $true })
Assert-True $s.Ok 'apply with yes builds'
Assert-True ($s.Args -match '-Apply' -and $s.Args -match '-AllowMissingRoles') 'apply and allow-missing-roles flags'

$s = Get-Spec 'load-apply' 'python' ($load + @{ confirm = 'yes' })
Assert-True ($s.Args -match ' --apply' -and $s.Args -match '--import-file vcfa-import\.json' -and $s.Args -match '--browser-token') 'python apply flags'
Assert-True ($s.Args -match 'load_vcfa\.py"? --org finance-org') 'python org flag'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = 'short' }
Assert-True (-not $s.Ok) 'a short token is refused'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o'; vcfaToken = 'Bearer ' + $tok }
Assert-True (-not $s.Ok) 'a token with a space is refused (paste only the token)'

$s = Get-Spec 'load-dry' 'powershell' @{ vcfaHost = 'vcfa.corp.local'; vcfaOrg = 'o' }
Assert-True (-not $s.Ok) 'load without a token is refused'

$sync = @{ idmHost = 'ca-idm.corp.local'; idmMethod = 'token'; idmToken = $tok; opsHost = 'vcf-ops.corp.local'; opsMethod = 'password'; opsUsername = 'admin'; opsPassword = 'Ops-Secret-1'; opsAuthSource = 'VCF SSO'; ssoDomainId = '00000000-0000-0000-0000-000000000000' } # pragma: allowlist secret
$s = Get-Spec 'sync-login' 'python' $sync
Assert-True $s.Ok 'sync-login builds'
Assert-Equal $s.Env['IDM_METHOD'] 'token' 'sync IDM method token'
Assert-Equal $s.Env['IDM_TOKEN'] $tok 'sync IDM token goes to the environment'
Assert-True (-not $s.Env.ContainsKey('IDM_PASSWORD')) 'token login sets no IDM password'
Assert-Equal $s.Env['VCFOPS_AUTHSOURCE'] 'VCF SSO' 'ops auth source is passed'
Assert-True ($s.Args -match 'Sync-IdentitySource\.ps1"? -Step login') 'sync always runs the PowerShell script'
Assert-True ($s.Args -match '-SsoDomainId 00000000') 'SSO domain ID is passed'
Assert-True (-not $s.Console) 'sync-login is not a console step'

$s = Get-Spec 'sync-apply-console' 'powershell' $sync
Assert-True ($s.Ok -and $s.Console) 'sync-apply-console opens a console'
Assert-True ($s.Args -match '-NoExit' -and $s.Args -match '-Step apply') 'console runs the apply wizard with -NoExit'
Assert-True (-not ($s.Args -match '-Apply')) 'the console step never passes -Apply (the wizard asks)'

$s = Get-Spec 'sync-apply-console' 'powershell' ($sync + @{ addBaseDn = 'CN=my-test-group,OU=ca-vra-users,OU=Test,OU=Users,DC=corp,DC=local' })
Assert-True ($s.Args -match '-AddBaseDn CN=my-test-group') 'base DN is passed to the wizard'

$bad = Get-Spec 'export-login' 'powershell' @{ vraHost = 'bad host;rm'; vraUsername = 'u'; vraPassword = 'p' } # pragma: allowlist secret
Assert-True (-not $bad.Ok) 'a host with a space or semicolon is refused'
Assert-True ($bad.Error -match 'host name') 'the refusal explains the host'

$s = Get-Spec 'export-login' 'powershell' @{ vraHost = 'https://dev.vra.local/'; vraUsername = 'u'; vraPassword = 'p' } # pragma: allowlist secret
Assert-True $s.Ok 'a host with https:// and a slash is accepted (the script normalises it)'

$s = Get-Spec 'export-login' 'powershell' @{ vraHost = 'dev.vra.local'; vraUsername = 'u'; vraPassword = 'p'; vraDomain = 'a"b' } # pragma: allowlist secret
Assert-True (-not $s.Ok) 'a quote in a domain is refused'

$s = New-RunSpec 'export-login' 'powershell' 'relative\folder' ([pscustomobject]$vra)
Assert-True (-not $s.Ok) 'a relative output folder is refused'

$s = New-RunSpec 'rm-everything' 'powershell' $folder ([pscustomobject]@{})
Assert-True (-not $s.Ok) 'an unknown action is refused'

$s = New-RunSpec 'export-login' 'cmd' $folder ([pscustomobject]$vra)
Assert-True (-not $s.Ok) 'an unknown engine is refused'

$syncBad = $sync.Clone(); $syncBad['ssoDomainId'] = 'x y'
$s = Get-Spec 'sync-login' 'powershell' $syncBad
Assert-True (-not $s.Ok) 'an SSO domain ID with a space is refused'

# Helpers
Assert-Equal (Quote-Arg 'plain') 'plain' 'Quote-Arg leaves plain text alone'
Assert-Equal (Quote-Arg 'two words') '"two words"' 'Quote-Arg quotes spaces'
Assert-True (Test-HostText 'https://dev.vra.local:443') 'host with scheme and port is valid'
Assert-True (-not (Test-HostText 'dev vra')) 'host with a space is not valid'
Assert-True (Test-TokenText $tok) 'a plain token is valid'
Assert-True (-not (Test-TokenText ($tok + "`n" + 'x'))) 'a token with a line break is not valid'
Assert-True (-not (Test-PlainText "a`tb" 10)) 'control characters are not plain text'
Assert-True (-not (Test-PlainText ('x' * 11) 10)) 'text longer than the limit is refused'
Assert-Equal (Get-Text ([pscustomobject]@{ a = '  x  ' }) 'a') 'x' 'Get-Text trims'
Assert-Equal (Get-Text $null 'a') '' 'Get-Text on null is empty'
Assert-True (Test-TokenEqual 'abc' 'abc') 'token compare: equal'
Assert-True (-not (Test-TokenEqual 'abd' 'abc')) 'token compare: different'
Assert-True (-not (Test-TokenEqual '' 'abc')) 'token compare: empty'

# ---- 2. Live server ----------------------------------------------------------
function Invoke-Http([string]$Method, [string]$Url, [hashtable]$Headers = @{}, [string]$Body = '', [string]$HostHeader = '') {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = 120000
    $req.AllowAutoRedirect = $false
    $req.Proxy = $null
    if ($HostHeader) { $req.Host = $HostHeader }
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, [string]$Headers[$k]) }
    if ($Method -eq 'POST') {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    }
    $res = $null
    try { $res = $req.GetResponse() }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { $res = $_.Exception.Response } else { throw }
    }
    $sr = New-Object System.IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd(); $sr.Close()
    return @{ Status = [int]$res.StatusCode; Body = $text; Csp = [string]$res.Headers['Content-Security-Policy'] }
}

$port = Get-Random -Minimum 20000 -Maximum 40000
$base = "http://127.0.0.1:$port"
$hostOk = "127.0.0.1:$port"
$proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uiScript, '-Port', [string]$port, '-NoBrowser') -PassThru -WindowStyle Hidden
$token = ''
try {
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Milliseconds 500
        try { $r = Invoke-Http 'GET' "$base/" @{} '' $hostOk; if ($r.Status -eq 200) { $ready = $true; $token = [regex]::Match($r.Body, 'name="ui-token" content="([0-9a-f]+)"').Groups[1].Value } } catch { }
    }
    Assert-True $ready 'server starts on 127.0.0.1'
    if (-not $ready) { throw 'server did not start' }

    $r = Invoke-Http 'GET' "$base/" @{} '' $hostOk
    Assert-True ($token.Length -eq 48) 'page carries a 48-character token'
    Assert-True ($r.Csp -match "default-src 'none'") 'page has a Content-Security-Policy'
    Assert-True ($r.Body -match 'vRA to VCFA identity migration') 'page is served'
    $r = Invoke-Http 'GET' "$base/" @{} '' "evil.example.com:$port"
    Assert-Equal $r.Status 403 'a foreign Host header is refused'
    $r = Invoke-Http 'GET' "$base/api/info" @{} '' $hostOk
    Assert-Equal $r.Status 403 'API without token is refused'
    $r = Invoke-Http 'GET' "$base/api/info" @{ 'X-UI-Token' = 'nope' } '' $hostOk
    Assert-Equal $r.Status 403 'API with a wrong token is refused'
    $r = Invoke-Http 'GET' "$base/api/info" @{ 'X-UI-Token' = $token; 'Origin' = 'http://evil.example.com' } '' $hostOk
    Assert-Equal $r.Status 403 'API from another site (Origin) is refused'
    $r = Invoke-Http 'GET' "$base/api/info" @{ 'X-UI-Token' = $token } '' $hostOk
    Assert-Equal $r.Status 200 'API with the page token answers'
    Assert-True ($r.Body -match '"scripts"' -and $r.Body -match '"powershell"') 'info lists scripts and engines'
    Assert-True (-not ($r.Body -match 'password')) 'info holds no password'
    $r = Invoke-Http 'GET' "$base/api/info" @{ 'X-UI-Token' = $token } '' $hostOk
    Assert-True ($r.Body -match '"folder":""' -and -not ($r.Body -match '"exists":true')) 'no folder is suggested: nothing is looked for until one is chosen'

    $H = @{ 'X-UI-Token' = $token }
    function Wait-Job([int]$Id) {
        for ($i = 0; $i -lt 120; $i++) {
            $j = Invoke-Http 'GET' "$base/api/jobs/$Id`?after=0" $H '' $hostOk
            if ($j.Body -notmatch '"status":"running"') { return $j.Body }
            Start-Sleep -Milliseconds 500
        }
        return 'TIMEOUT'
    }
    $secret = 'Zq9-FakePw-TEST' # pragma: allowlist secret
    $vraBody = @{ action = 'export-login'; engine = 'powershell'; folder = $folder; values = @{ vraHost = '127.0.0.1:9'; vraUsername = 'testuser'; vraPassword = $secret; vraDomain = 'System Domain' } } | ConvertTo-Json -Depth 5 -Compress
    $r = Invoke-Http 'POST' "$base/api/jobs" $H $vraBody $hostOk
    Assert-Equal $r.Status 200 'PowerShell export login starts'
    $id = [int]([regex]::Match($r.Body, '"id":(\d+)').Groups[1].Value)
    $out = Wait-Job $id
    Assert-True ($out -match '"exitCode":1') 'a failed login reports exit code 1 (not null)'
    Assert-True ($out -match 'Logging in to https://127\.0\.0\.1:9') 'the output streams to the page'
    Assert-True (-not ($out -match [regex]::Escape($secret))) 'the password is not in the output'
    Assert-True ($out -match '"reason":"[^"]') 'a failed step gives the reason in plain words'

    $vraBody = @{ action = 'export-login'; engine = 'python'; folder = $folder; values = @{ vraHost = '127.0.0.1:9'; vraUsername = 'testuser'; vraPassword = $secret; vraDomain = 'System Domain' } } | ConvertTo-Json -Depth 5 -Compress
    $r = Invoke-Http 'POST' "$base/api/jobs" $H $vraBody $hostOk
    $id = [int]([regex]::Match($r.Body, '"id":(\d+)').Groups[1].Value)
    $out = Wait-Job $id
    Assert-True ($out -match '"exitCode":1') 'Python login reports exit code 1'
    Assert-True (-not ($out -match [regex]::Escape($secret))) 'the password is not in the Python output either'

    $r = Invoke-Http 'POST' "$base/api/jobs" $H (@{ action = 'load-apply'; engine = 'powershell'; folder = $folder; values = @{ vcfaHost = '127.0.0.1:9'; vcfaOrg = 'o'; vcfaToken = $tok; confirm = '' } } | ConvertTo-Json -Depth 5 -Compress) $hostOk
    Assert-Equal $r.Status 400 'apply without yes is refused by the server too'
    $r = Invoke-Http 'POST' "$base/api/jobs" $H (@{ action = 'export-login'; engine = 'powershell'; folder = $folder; values = @{ vraHost = 'bad host;rm'; vraUsername = 'u'; vraPassword = 'p' } } | ConvertTo-Json -Depth 5 -Compress) $hostOk # pragma: allowlist secret
    Assert-Equal $r.Status 400 'a bad host is refused'
    $r = Invoke-Http 'POST' "$base/api/jobs" $H (@{ action = 'export-login'; engine = 'powershell'; folder = 'examples'; values = @{ vraHost = 'h.example.com'; vraUsername = 'u'; vraPassword = 'p' } } | ConvertTo-Json -Depth 5 -Compress) $hostOk # pragma: allowlist secret
    Assert-Equal $r.Status 400 'a relative folder is refused'
    $r = Invoke-Http 'POST' "$base/api/jobs" $H '{"action":"export-login"' $hostOk
    Assert-Equal $r.Status 400 'invalid JSON is refused'

    # Browse: the page's token is needed, and only JSON files can be picked (both refused before any dialog opens)
    $r = Invoke-Http 'POST' "$base/api/browse" @{} '{"kind":"json"}' $hostOk
    Assert-Equal $r.Status 403 'browse without the page token is refused'
    $r = Invoke-Http 'POST' "$base/api/browse" $H '{"kind":"exe"}' $hostOk
    Assert-Equal $r.Status 400 'browse offers JSON files only'

    # Busy and cancel: a host that never answers keeps the step running long enough to test the second request.
    $slow = @{ action = 'export-login'; engine = 'powershell'; folder = $folder; values = @{ vraHost = '10.255.255.1'; vraUsername = 'u'; vraPassword = 'p' } } | ConvertTo-Json -Depth 5 -Compress # pragma: allowlist secret
    $r = Invoke-Http 'POST' "$base/api/jobs" $H $slow $hostOk
    $slowId = [int]([regex]::Match($r.Body, '"id":(\d+)').Groups[1].Value)
    $second = Invoke-Http 'POST' "$base/api/jobs" $H $vraBody $hostOk
    if ($second.Status -eq 409) {
        Assert-Equal $second.Status 409 'a second step is refused while one runs'
        $c = Invoke-Http 'POST' "$base/api/jobs/$slowId/cancel" $H '{}' $hostOk
        Assert-Equal $c.Status 200 'cancel answers'
        $out = Wait-Job $slowId
        Assert-True ($out -match '"status":"cancelled"') 'a cancelled step ends as cancelled'
    } else {
        $script:Skip++; Say "SKIP: the slow step finished before the second request (no network timeout here)"
        [void](Wait-Job $slowId)
    }

    $r = Invoke-Http 'POST' "$base/api/open" $H '{"name":"vcfa-plan.json","folder":"C:\\x"}' $hostOk
    Assert-Equal $r.Status 400 'only the two HTML reports can be opened'
    $r = Invoke-Http 'GET' "$base/api/jobs" $H '' $hostOk
    Assert-True ($r.Body -match '"jobs"') 'job list answers'

    $r = Invoke-Http 'POST' "$base/api/shutdown" $H '{}' $hostOk
    Assert-Equal $r.Status 200 'shutdown answers'
    $exited = $proc.WaitForExit(15000)
    Assert-True $exited 'the server stops after shutdown'
} finally {
    if (-not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force } catch { } }
}

Say ''
Say "Results: $($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped."
if ($script:Fail -gt 0) { exit 1 }

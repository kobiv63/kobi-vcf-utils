<#
.SYNOPSIS
    End-to-end test: runs the real scripts against a mock vRA + VCFA server on localhost (no Pester, no internet).
    Export-VraIdentity.ps1 runs first; Import-Vcfa.ps1 then loads the file the export wrote.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Integration.ps1
#>
$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Say([string]$Text) { [Console]::Out.WriteLine($Text) }
function Assert-True($Cond, [string]$Name) {
    if ($Cond) { $script:Pass++ } else {
        $script:Fail++; Say "FAIL: $Name"
        if ($script:LastOut) { Say ("   last script output: " + $script:LastOut.Substring(0, [Math]::Min(2500, $script:LastOut.Length))) }
    }
}
function Assert-Equal($Actual, $Expected, [string]$Name) {
    $a = ConvertTo-Json -InputObject $Actual -Compress -Depth 20; $e = ConvertTo-Json -InputObject $Expected -Compress -Depth 20
    if ($a -ceq $e) { $script:Pass++ } else { $script:Fail++; Say "FAIL: $Name`n   expected: $e`n   actual:   $a" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("vcf-int-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$logPath = Join-Path $work 'requests.log'
$port = Get-Random -Minimum 20000 -Maximum 40000
$base = "http://127.0.0.1:$port"
$exportScript = Join-Path $PSScriptRoot 'Export-VraIdentity.ps1'
$importScript = Join-Path $PSScriptRoot 'Import-Vcfa.ps1'

$server = {
    param($port, $logPath)
    $e = [string][char]233   # e-acute, to prove UTF-8 survives
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    $l.Start()
    $createdGroups = New-Object System.Collections.ArrayList
    $createdUsers = New-Object System.Collections.ArrayList
    $vraUsers = '[{"user":{"username":"aaron","firstName":"Aaron","lastName":"L","domain":"corp.example.com","email":"aaron@corp.example.com","userId":"u1"},"organizationRoles":[{"name":"org_member"}],"serviceRoles":[{"serviceRoles":[{"name":"catalog:user"},{"name":"saltstack:admin"}]}]},{"user":{"username":"admin","domain":"System Domain","email":"a@example.com","userId":"u2"},"organizationRoles":[{"name":"org_owner"}],"serviceRoles":[]},{"user":{"username":"adiel","domain":"other.example.com","email":"adiel@other.example.com","userId":"u3"},"organizationRoles":[],"serviceRoles":[]}]'
    $vraGroups = '[{"id":"g1","displayName":"Infra@corp.example.com","domain":"corp.example.com","groupType":"AD_GROUP","organizationRoles":[{"name":"org_member"}],"serviceRoles":[{"serviceRoleNames":["catalog:admin","orchestration:viewer"]}]},{"id":"g2","displayName":"Caf' + $e + '@corp.example.com","domain":"corp.example.com","groupType":"AD_GROUP","organizationRoles":[{"name":"org_member"}],"serviceRoles":[]}]'
    $vcfaRoles = '[{"name":"Organization Member","id":"urn:role:1"},{"name":"Service Broker Administrator","id":"urn:role:2"},{"name":"Orchestrator Viewer","id":"urn:role:3"},{"name":"Service Broker User","id":"urn:role:4"}]'
    while ($true) {
        $ctx = $l.GetContext(); $req = $ctx.Request
        $body = ''
        if ($req.HasEntityBody) { $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() }
        $path = $req.Url.AbsolutePath; $method = $req.HttpMethod
        $auth = $req.Headers['Authorization']
        $tenant = $req.Headers['x-vmware-vcloud-tenant-context']; $authctx = $req.Headers['x-vmware-vcloud-auth-context']
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("{0} {1}{2} | auth={3} | type={4} | tenant={5} | authctx={6} | {7}" -f $method, $path, $req.Url.Query, $auth, $req.ContentType, $tenant, $authctx, ($body -replace '\s+', ' '))
        $status = 200; $out = '{}'
        $vraOk = ($auth -eq 'Bearer csp-token'); $iaasOk = ($auth -eq 'Bearer iaas-token'); $vcfaOk = ($auth -eq ('Bearer ' + ('t' * 30)))
        switch -regex ("$method $path") {
            '^GET /__ping$' { $out = '"pong"' }
            '^GET /__stop$' { $status = 200 }
            '^POST /csp/gateway/am/api/login$' { if ($body -match '"password":\s*"pw"') { $out = '{"refresh_token":"rt"}' } else { $status = 401; $out = '{"message":"bad credentials"}' } }
            '^POST /csp/gateway/am/api/auth/api-tokens/authorize$' { $out = '{"access_token":"csp-token"}' }
            '^POST /iaas/api/login$' { $out = '{"token":"iaas-token"}' }
            '^GET /csp/gateway/am/api/loggedin/user/orgs$' { if ($vraOk) { $out = '{"refLinks":["/csp/gateway/am/api/orgs/org-1"]}' } else { $status = 401 } }
            '^GET /csp/gateway/am/api/v2/orgs/org-1/users$' { if ($vraOk) { $out = '{"results":' + $vraUsers + '}' } else { $status = 401 } }
            '^GET /csp/gateway/am/api/v2/orgs/org-1/groups$' { $status = 404; $out = '{"message":"not found"}' }
            '^GET /csp/gateway/am/api/orgs/org-1/groups$' { if ($vraOk) { $out = '{"results":' + $vraGroups + '}' } else { $status = 401 } }
            '^GET /csp/gateway/am/api/orgs/org-1/groups/g1/users$' { $out = '{"results":[{"userId":"u1","username":"aaron","domain":"corp.example.com","email":"aaron@corp.example.com"}]}' }
            '^GET /csp/gateway/am/api/orgs/org-1/groups/g2/users$' { $out = '{"results":[]}' }
            '^GET /iaas/api/projects$' { if ($iaasOk) { $out = '{"content":[{"id":"p1","name":"P1","administrators":[{"email":"aaron","type":"user"}],"members":[{"email":"adiel","type":"user"},{"email":"Infra@corp.example.com","type":"group"}]}]}' } else { $status = 401 } }
            '^GET /cloudapi/1.0.0/sessions/current$' { if ($vcfaOk) { $out = '{"org":{"name":"finance","id":"urn:vcloud:org:abc-123"},"roles":["Organization Administrator"]}' } else { $status = 401; $out = '{"message":"expired"}' } }
            '^GET /cloudapi/1.0.0/roles$' { $out = '{"values":' + $vcfaRoles + ',"pageCount":1}' }
            '^GET /cloudapi/1.0.0/users$' { $out = '{"values":[' + (($createdUsers | ForEach-Object { $_ }) -join ',') + '],"pageCount":1}' }
            '^GET /cloudapi/1.0.0/groups$' { $out = '{"values":[' + (($createdGroups | ForEach-Object { $_ }) -join ',') + '],"pageCount":1}' }
            '^POST /cloudapi/1.0.0/groups$' { if ($vcfaOk -and $tenant -eq 'abc-123' -and $authctx -eq 'finance') { [void]$createdGroups.Add($body); $status = 201; $out = $body } else { $status = 403; $out = '{"message":"forbidden"}' } }
            '^POST /cloudapi/1.0.0/users$' { if ($vcfaOk -and $tenant -eq 'abc-123') { [void]$createdUsers.Add($body); $status = 201; $out = $body } else { $status = 403 } }
            default { $status = 404; $out = '{"message":"no route"}' }
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
        $ctx.Response.StatusCode = $status
        $ctx.Response.ContentType = 'application/json'   # no charset on purpose
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
        if ($path -eq '/__stop') { break }
    }
    $l.Stop()
}

function Invoke-Script([string]$Script, [string]$ArgText, [hashtable]$Env) {
    # Runs a script in its own powershell.exe with stdin redirected from NUL (no terminal, so nothing is prompted).
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    Push-Location $work
    try {
        $out = & cmd.exe /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$Script`" $ArgText < NUL 2>&1"
        $script:LastOut = (@($out) -join "`n")
        return @{ Out = $script:LastOut; Code = $LASTEXITCODE }
    }
    finally {
        Pop-Location
        foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

$job = Start-Job -ScriptBlock $server -ArgumentList $port, $logPath
try {
    $ready = $false
    for ($i = 0; $i -lt 50 -and -not $ready; $i++) {
        try { $null = Invoke-WebRequest -Uri "$base/__ping" -UseBasicParsing -TimeoutSec 2; $ready = $true } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw 'mock server did not start' }

    # ---- Export against mock vRA ---------------------------------------------
    $env1 = @{ VRA_HOST = $base; VRA_USERNAME = 'svc'; VRA_PASSWORD = 'pw'; VRA_DOMAIN = 'System Domain' }
    $r = Invoke-Script $exportScript 'login' $env1
    Assert-True ($r.Code -eq 0) 'export login: exit code 0'
    Assert-True ($r.Out -like '*LOGIN OK. Org: org-1*') 'export login: org found'
    $r = Invoke-Script $exportScript 'login' @{ VRA_HOST = $base; VRA_USERNAME = 'svc'; VRA_PASSWORD = 'wrong'; VRA_DOMAIN = 'x' }
    Assert-True ($r.Code -eq 1) 'export bad password: exit code 1'
    Assert-True ($r.Out -like '*login failed (401)*bad credentials*') 'export bad password: clear message with the 401 body'

    $r = Invoke-Script $exportScript 'all' $env1
    Assert-True ($r.Code -eq 0) 'export all: exit code 0'
    foreach ($f in 'vra-export.json', 'vcfa-import.json', 'users.json', 'groups.json') {
        Assert-True (Test-Path (Join-Path $work $f)) "export all: wrote $f"
    }
    Assert-True ($r.Out -like '*via /csp/gateway/am/api/orgs/org-1/groups*') 'export: fell back from the 404 group endpoint'
    $impText = [System.IO.File]::ReadAllText((Join-Path $work 'vcfa-import.json'), [System.Text.Encoding]::UTF8)
    $imp = ConvertFrom-Json $impText
    $e = [string][char]233
    Assert-True (@($imp.groups | Where-Object { $_.name -eq "Caf$e@corp.example.com" }).Count -eq 1) 'export: UTF-8 group name survives the HTTP round trip'
    Assert-True (@($imp.users | Where-Object { $_.username -eq 'adiel@other.example.com' }).Count -eq 1) 'export: project-only user resolved and added'
    Assert-True (@($imp.roleBindings | Where-Object { $_.principal -eq 'Infra@corp.example.com' -and $_.role -eq 'Service Broker Administrator' -and $_.scope -eq 'organization' }).Count -eq 1) 'export: group role mapped'
    Assert-True (@($imp.roleBindings | Where-Object { $_.scope -eq 'project:P1' }).Count -eq 3) 'export: project roles recorded'
    Assert-True (@($imp.groups | Where-Object { $_.name -eq 'Infra@corp.example.com' }).members -contains 'aaron@corp.example.com') 'export: group members fetched'

    if ($env:INT_DEBUG) { Get-Content -LiteralPath $logPath | Where-Object { $_ -like 'POST*' } | ForEach-Object { Say "   LOG: $_" } }
    $repPath = Join-Path $work 'vra-export-report.html'
    Assert-True (Test-Path $repPath) 'export report: the HTML file is written'
    $repHtml = [System.IO.File]::ReadAllText($repPath, [System.Text.Encoding]::UTF8)
    $repJson = [regex]::Match($repHtml, 'id="report-data" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value
    $rep = ConvertFrom-Json $repJson
    Assert-True ($rep.kind -eq 'export' -and $rep.counts.groups -eq 2 -and $rep.org -eq 'org-1') 'export report: embedded data is valid and matches the export'
    Assert-True (@($rep.groups | Where-Object { $_.name -eq "Caf$e@corp.example.com" }).Count -eq 1) 'export report: non-ASCII name survives into the report'

    # The export must be read only: the only POSTs are the three login calls.
    $log = @(Get-Content -LiteralPath $logPath -Encoding UTF8)
    $writes = @($log | Where-Object { $_ -match '^(POST|PUT|PATCH|DELETE) ' -and $_ -notmatch '^POST /(csp/gateway/am/api/(login|auth/api-tokens/authorize)|iaas/api/login)' })
    Assert-Equal $writes.Count 0 'export is read only (only login POSTs)'
    Assert-True (@($log | Where-Object { $_ -like 'POST /csp/gateway/am/api/auth/api-tokens/authorize*type=application/x-www-form-urlencoded*refresh_token=rt' }).Count -ge 1) 'export: authorize sent as a form body'
    Assert-True (@($log | Where-Object { $_ -like 'GET /csp/gateway/am/api/orgs/org-1/groups/g1/users*auth=Bearer csp-token*' }).Count -ge 1) 'export: bearer token on API calls'

    # ---- Load the export into mock VCFA --------------------------------------
    $token = 't' * 30
    $env2 = @{ VCFA_HOST = $base; VCFA_ORG = 'finance'; VCFA_BROWSER_TOKEN = $token }
    $r = Invoke-Script $importScript '-BrowserToken -LoginOnly' $env2
    Assert-True ($r.Code -eq 0 -and $r.Out -like '*LOGIN OK. Org: name=finance*') 'load login only: ok'
    $r = Invoke-Script $importScript '-BrowserToken -LoginOnly' @{ VCFA_HOST = $base; VCFA_ORG = 'finance'; VCFA_BROWSER_TOKEN = ('x' * 30) }
    Assert-True ($r.Code -eq 1 -and $r.Out -like '*probably expired*') 'load expired token: clear message'

    $r = Invoke-Script $importScript '-BrowserToken -Only "Infra@corp.example.com"' $env2
    Assert-True ($r.Code -eq 0) 'load dry run: exit code 0'
    Assert-True ($r.Out -like '*Plan: create 0 users, 1 groups*') 'load dry run: plans one group'
    Assert-True ($r.Out -like '*DRY RUN - nothing created*') 'load dry run: says so'
    Assert-True (Test-Path (Join-Path $work 'vcfa-plan.json')) 'load dry run: plan file written'
    $postsBefore = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { $_ -like 'POST /cloudapi*' }).Count
    Assert-Equal $postsBefore 0 'load dry run: no create calls'

    $r = Invoke-Script $importScript '-BrowserToken -Only "Infra@corp.example.com" -Apply' $env2
    Assert-True ($r.Code -eq 0) 'load apply: exit code 0'
    Assert-True ($r.Out -like '*Done: 1 created, 0 failed*') 'load apply: one group created'
    Assert-True ($r.Out -like '*Role check: 1/1 objects have the same org/service roles as in vRA*') 'load apply: role check passes against the server'
    $log = @(Get-Content -LiteralPath $logPath -Encoding UTF8)
    $post = @($log | Where-Object { $_ -like 'POST /cloudapi/1.0.0/groups*' })
    Assert-True ($post.Count -eq 1) 'load apply: exactly one create call'
    Assert-True ($post[0] -like '*type=application/json*charset=utf-8*tenant=abc-123*authctx=finance*') 'load apply: JSON body with the tenant and auth context headers'
    Assert-True ($post[0] -match 'urn:role:1' -and $post[0] -match 'urn:role:2' -and $post[0] -match 'urn:role:3') 'load apply: VCFA role ids in the request'
    Assert-True ($post[0] -match '"providerType":\s*"OAUTH"') 'load apply: provider type'

    # A second run must not recreate it (the mock now returns the group).
    $r = Invoke-Script $importScript '-BrowserToken -Only "Infra@corp.example.com" -Apply' $env2
    Assert-True ($r.Out -like '*nothing to create or update*') 'load again: existing group is not recreated'

    # Default load: groups plus the users whose roles are not inherited. aaron has a role his group lacks and adiel
    # has project access only; admin is a local user and bob-style users with no roles would be skipped.
    $r = Invoke-Script $importScript '-BrowserToken' $env2
    Assert-True ($r.Out -like '*Users loaded because their roles are not inherited from a group: 2*') 'load default: the two non-inherited users are chosen'
    Assert-True ($r.Out -like '*Local users with roles are NOT created*admin*') 'load default: local users are listed, not created'
    $r = Invoke-Script $importScript '-BrowserToken -Apply' $env2
    Assert-True ($r.Code -eq 0) 'load default apply: exit code 0'
    Assert-True ($r.Out -like '*Done: 3 created, 0 failed*') 'load default apply: the remaining group and the two users are created'
    Assert-True ($r.Out -like '*Role check: 3/3*') 'load default apply: role check passes for all three'
    $log = @(Get-Content -LiteralPath $logPath -Encoding UTF8)
    Assert-True (@($log | Where-Object { $_ -like 'POST /cloudapi/1.0.0/users*' }).Count -eq 2) 'load default apply: two user create calls'
    Assert-True (@($log | Where-Object { $_ -like 'POST /cloudapi/1.0.0/groups*' -and $_ -like "*Caf$e@corp.example.com*" }).Count -eq 1) 'load: a non-ASCII group name is sent as UTF-8 (not mangled)'

    $loadRep = [System.IO.File]::ReadAllText((Join-Path $work 'vcfa-load-report.html'), [System.Text.Encoding]::UTF8)
    $lj = ConvertFrom-Json ([regex]::Match($loadRep, 'id="report-data" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value)
    Assert-True ($lj.kind -eq 'load' -and $lj.mode -eq 'applied' -and $lj.counts.created -eq 3 -and $lj.roleCheck.matched -eq 3) 'load report: applied run is recorded with its role check'
    Assert-True (@($lj.users | Where-Object { $_.name -eq 'aaron@corp.example.com' }).notInherited -contains 'Service Broker User') 'load report: shows why a user was loaded'

    # Wrong role names stop the apply.
    $r = Invoke-Script $importScript '-BrowserToken -Only "Caf*" -Apply' $env2
    Assert-True ($r.Code -eq 1) 'load: unknown --Only name stops'
}
finally {
    try { $null = Invoke-WebRequest -Uri "$base/__stop" -UseBasicParsing -TimeoutSec 3 } catch { }
    Wait-Job $job -Timeout 5 | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Say "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail) { exit 1 }

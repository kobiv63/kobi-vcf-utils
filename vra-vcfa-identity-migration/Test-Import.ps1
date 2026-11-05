<#
.SYNOPSIS
    Offline tests for Import-Vcfa.ps1 (no network, no Pester needed).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Import.ps1
#>
$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Say([string]$Text) { [Console]::Out.WriteLine($Text) }
function Assert-Equal($Actual, $Expected, [string]$Name) {
    $a = ConvertTo-Json -InputObject $Actual -Compress -Depth 20
    $e = ConvertTo-Json -InputObject $Expected -Compress -Depth 20
    if ($a -ceq $e) { $script:Pass++ } else { $script:Fail++; Say "FAIL: $Name`n   expected: $e`n   actual:   $a" }
}
function Assert-True($Cond, [string]$Name) {
    if ($Cond) { $script:Pass++ } else { $script:Fail++; Say "FAIL: $Name" }
}
function Assert-Throws([scriptblock]$Block, [string]$Like, [string]$Name) {
    try { & $Block; $script:Fail++; Say "FAIL: $Name (no error)" }
    catch {
        if ($_.Exception.Message -like $Like) { $script:Pass++ }
        else { $script:Fail++; Say "FAIL: $Name`n   error was: $($_.Exception.Message)" }
    }
}

$script:ScriptPath = Join-Path $PSScriptRoot 'Import-Vcfa.ps1'
# Make sure the machine's own settings do not leak into the tests.
$savedEnv = @{}
foreach ($n in 'VCFA_HOST', 'VCFA_ORG', 'VCFA_USERNAME', 'VCFA_PASSWORD', 'VCFA_API_TOKEN', 'VCFA_BROWSER_TOKEN', 'VCFA_API_VERSION') {
    $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null)
}

. $script:ScriptPath
$script:ForceInteractive = $false
function J($Text) { return , (ConvertFrom-JsonText $Text) }

$IMP = J '{"users":[{"username":"ann@corp.local","providerType":"OAUTH"},{"username":"bob@corp.local","providerType":"OAUTH"}],"groups":[{"name":"Infra@corp.local","providerType":"OAUTH","members":["ann@corp.local"]}],"roleBindings":[{"principalType":"user","principal":"ann@corp.local","scope":"organization","role":"Organization Member"},{"principalType":"user","principal":"ann@corp.local","scope":"organization","role":"Service Broker User"},{"principalType":"user","principal":"ann@corp.local","scope":"project:P1","role":"Project Administrator"},{"principalType":"group","principal":"Infra@corp.local","scope":"organization","role":"Assembler Administrator"}]}'
$ROLES = J '[{"name":"Organization Member","id":"r1"},{"name":"Service Broker User","id":"r2"},{"name":"Assembler Administrator","id":"r3"}]'
$ROLES_NO_SB = @($ROLES | Where-Object { $_['name'] -ne 'Service Broker User' })
$SESSION = J '{"org":{"name":"my-org","id":"urn:vcloud:org:abc"},"roles":["Organization Administrator"]}'
$TOKEN = 'tok' * 10

function Find-Create($Plan, $Name) { return (@($Plan['creates']) | Where-Object { (Get-ObjName $_) -eq $Name } | Select-Object -First 1) }
function Role-Names($Create) { return ,@($Create['body']['roleEntityRefs'] | ForEach-Object { $_['name'] } | Sort-Object) }

# ---- Role names -------------------------------------------------------------
Assert-Equal (Get-NormRole 'Assembler Admin') (Get-NormRole 'Assembler Administrator') 'norm_role: Admin == Administrator'
Assert-Equal (Get-NormRole 'Service-Broker  User') 'servicebrokeruser' 'norm_role: ignores case and punctuation'

# ---- Plan -------------------------------------------------------------------
$plan = New-Plan $IMP $ROLES @() @()
Assert-Equal (Role-Names (Find-Create $plan 'ann@corp.local')) @('Organization Member', 'Service Broker User') 'plan: org and service roles carried'
Assert-Equal (Role-Names (Find-Create $plan 'Infra@corp.local')) @('Assembler Administrator') 'plan: group roles carried'
Assert-Equal $plan['projectBindingsNotHandled'] 1 'plan: project binding counted'
Assert-Equal @($plan['projectBindings']['project:P1'])[0]['role'] 'Project Administrator' 'plan: project binding recorded per project'
Assert-Equal @((Find-Create $plan 'bob@corp.local')['body']['roleEntityRefs']).Count 0 'plan: user with no roles gets none'
Assert-Equal (Find-Create $plan 'ann@corp.local')['body']['inheritGroupRoles'] $true 'plan: user body matches the UI'
Assert-Equal @((Get-BlockedByMissingRoles $plan).Keys).Count 0 'plan: nothing blocked when all roles exist'
Assert-Equal $plan['roleMapping']['Organization Member'] 'Organization Member' 'plan: role mapping table'

$plan = New-Plan $IMP $ROLES_NO_SB @() @()
$blocked = Get-BlockedByMissingRoles $plan
Assert-Equal @($blocked.Keys) @('ann@corp.local') 'blocked: missing VCFA role blocks the affected user'
Assert-Equal @($blocked['ann@corp.local']) @('Service Broker User') 'blocked: names the missing role'
Assert-Equal $plan['roleMapping']['Service Broker User'] $null 'plan: missing role shown as not found'

$imp2 = J '{"users":[],"groups":[{"name":"G","providerType":"OAUTH"}],"roleBindings":[{"principalType":"group","principal":"G","scope":"organization","role":"Assembler Admin"},{"principalType":"group","principal":"G","scope":"organization","role":"Org Owner"}]}'
$plan = New-Plan $imp2 (J '[{"name":"Assembler Administrator","id":"x"}]') @() @()
Assert-Equal @($plan['creates'])[0]['body']['roleEntityRefs'][0]['name'] 'Assembler Administrator' 'plan: uses the VCFA spelling of the role'
Assert-Equal $plan['roleMapping']['Assembler Admin'] 'Assembler Administrator' 'plan: loose match reported'
Assert-Equal @((Get-BlockedByMissingRoles $plan)['g']) @('Org Owner') 'plan: unmatched role blocks'

$existingGroup = J '{"id":"g9","name":"Infra@corp.local","roleEntityRefs":[{"name":"Organization Member","id":"r1"}]}'
$plan = New-Plan $IMP $ROLES @() @($existingGroup)
Assert-Equal @($plan['creates'] | Where-Object { $_['type'] -eq 'group' }).Count 0 'plan: existing group is not recreated'
$upd = @($plan['updates'])[0]
Assert-Equal @($upd['adding']) @('Assembler Administrator') 'plan: existing group gets only the roles it lacks'
Assert-Equal @($upd['body']['roleEntityRefs'] | ForEach-Object { $_['name'] }) @('Organization Member', 'Assembler Administrator') 'plan: existing roles are kept, never removed'
Assert-Equal $upd['path'] '/cloudapi/1.0.0/groups/g9' 'plan: update path'
$existingUser = J '{"id":"u9","username":"ANN@corp.local","roleEntityRefs":[{"name":"Organization Member","id":"r1"},{"name":"Service Broker User","id":"r2"}]}'
$plan = New-Plan $IMP $ROLES @($existingUser) @()
Assert-Equal @($plan['updates']).Count 0 'plan: up-to-date existing user needs no update (case-insensitive match)'
$localImp = J '{"users":[{"username":"admin","providerType":"LOCAL"}],"groups":[],"roleBindings":[]}'
$plan = New-Plan $localImp $ROLES @() @()
Assert-Equal @($plan['creates']).Count 0 'plan: local users are not created'
Assert-True (@($plan['skipped'])[0]['reason'] -like 'local user*') 'plan: local user skip reason'

# ---- Which users still need loading ------------------------------------------
function Imp-Of($users, $groups, $bindings) { return (J (ConvertTo-Json -InputObject ([ordered]@{ users = $users; groups = $groups; roleBindings = $bindings }) -Depth 20)) }
function B($kind, $who, $role, $scope = 'organization') { return [ordered]@{ principalType = $kind; principal = $who; scope = $scope; role = $role } }
function U($name, $provider = 'OAUTH') { return [ordered]@{ username = $name; providerType = $provider } }
$d = Get-DirectUsers (Imp-Of @((U 'a@x')) @([ordered]@{ name = 'G'; members = @('a@x') }) @((B 'group' 'G' 'Assembler Administrator'), (B 'user' 'a@x' 'Assembler Admin')))
Assert-Equal @($d.Keys).Count 0 'direct users: roles all inherited from the group -> not loaded (loose name match)'
$d = Get-DirectUsers (Imp-Of @((U 'a@x')) @([ordered]@{ name = 'G'; members = @('a@x') }) @((B 'group' 'G' 'Organization Member'), (B 'user' 'a@x' 'Organization Member'), (B 'user' 'a@x' 'Service Broker User')))
Assert-Equal @($d['a@x']) @('Service Broker User') 'direct users: an extra role beyond the group is loaded'
$d = Get-DirectUsers (Imp-Of @((U 'free@x')) @() @((B 'user' 'free@x' 'Organization Owner')))
Assert-Equal @($d['free@x']) @('Organization Owner') 'direct users: user in no group with roles is loaded'
Assert-Equal @((Get-DirectUsers (Imp-Of @((U 'n@x')) @() @())).Keys).Count 0 'direct users: user with no roles is not loaded'
Assert-Equal @((Get-DirectUsers (Imp-Of @((U 'p@x')) @() @((B 'user' 'p@x' 'Project Administrator' 'project:P1')))).Keys).Count 0 'direct users: project roles do not count'
$d = Get-DirectUsers (Imp-Of @((U 'a@x')) @([ordered]@{ name = 'G'; members = @('someone@x') }) @((B 'group' 'G' 'Organization Member'), (B 'user' 'a@x' 'Organization Member')))
Assert-Equal @($d['a@x']) @('Organization Member') 'direct users: group roles only count for groups the user is in'
$plan = New-Plan (Imp-Of @((U 'vradmin' 'LOCAL')) @() @((B 'user' 'vradmin' 'Organization Owner'))) @((J '[{"name":"Organization Owner","id":"r9"}]')) @() @()
Assert-Equal @($plan['localUsersWithRoles'])[0]['name'] 'vradmin' 'local users: listed in the plan'
Assert-Equal @($plan['localUsersWithRoles'])[0]['roles'] @('Organization Owner') 'local users: with their roles'
Assert-Equal @($plan['creates']).Count 0 'local users: never created'

# ---- Verify after apply -----------------------------------------------------
$plan = New-Plan $IMP $ROLES @() @()
function Get-AllVcfa([string]$Path, [hashtable]$Headers, [int]$PageSize = 128, [int]$MaxPages = 200) { return $script:FakeVcfa[$Path] }
$script:FakeVcfa = @{
    '/cloudapi/1.0.0/users'  = @((J '{"username":"ann@corp.local","roleEntityRefs":[{"name":"Organization Member"}]}'))
    '/cloudapi/1.0.0/groups' = @()
}
$bad = @(Test-VcfaRoles $plan @{})
$problems = @{}; foreach ($b in $bad) { $problems[$b['name']] = $b['problem'] }
Assert-Equal $problems['ann@corp.local'] 'missing roles: service broker user' 'verify: reports a missing role'
Assert-Equal $problems['infra@corp.local'] 'not found in VCFA' 'verify: reports a missing object'
$script:FakeVcfa = @{
    '/cloudapi/1.0.0/users'  = @((J '{"username":"ann@corp.local","roleEntityRefs":[{"name":"Organization Member"},{"name":"Service Broker User"}]}'), (J '{"username":"bob@corp.local","roleEntityRefs":[]}'))
    '/cloudapi/1.0.0/groups' = @((J '{"name":"Infra@corp.local","roleEntityRefs":[{"name":"Assembler Administrator"}]}'))
}
Assert-Equal @(Test-VcfaRoles $plan @{}).Count 0 'verify: clean when roles match'
Remove-Item Function:\Get-AllVcfa

# ---- Logins (HTTP faked) ----------------------------------------------------
function Invoke-Api { param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null, [string]$ContentType = '') return (& $script:FakeApi $Method $Url $Headers $Body) }
$script:Calls = New-Object System.Collections.ArrayList
$script:FakeApi = { param($m, $u, $h, $b) [void]$script:Calls.Add(@{ Method = $m; Url = $u; Headers = $h; Body = $b }); @{ Status = 200; Text = '{}'; Headers = @{ 'X-VMWARE-VCLOUD-ACCESS-TOKEN' = 'sess-token' }; Body = (J '{"org":{"name":"o","id":"urn:x:1"},"access_token":"at"}') } }
$script:VcfaHost = 'https://v.local'
$script:Calls.Clear()
$capture = "fetch('https://v.local/cloudapi/1.0.0/users', {headers: {`"authorization`": `"Bearer abcdefghijklmnopqrstuvwxyz`"}})"
$login = Connect-VcfaBearer $capture 'test'
Assert-Equal $login.Headers['Authorization'] 'Bearer abcdefghijklmnopqrstuvwxyz' 'bearer: token extracted from a Copy-as-fetch capture'
$login = Connect-VcfaBearer "Bearer $('z' * 30)" 'test'
Assert-Equal $login.Headers['Authorization'] "Bearer $('z' * 30)" 'bearer: raw token with Bearer prefix'
Assert-Throws { Connect-VcfaBearer 'short' 'test' } '*no bearer token*' 'bearer: too-short token rejected'
$tk = 'abcdefghijklmnopqrstuvwxyz0123'
Assert-Equal (Get-BearerToken $tk) $tk 'token text: raw token'
Assert-Equal (Get-BearerToken "  $tk`r`n") $tk 'token text: surrounding whitespace and newline'
Assert-Equal (Get-BearerToken "Bearer $tk") $tk 'token text: Bearer prefix'
Assert-Equal (Get-BearerToken "bearer   $tk") $tk 'token text: lower-case Bearer prefix'
Assert-Equal (Get-BearerToken "`"$tk`"") $tk 'token text: double quotes'
Assert-Equal (Get-BearerToken "'$tk'") $tk 'token text: single quotes'
$fetch = "fetch(`"https://v.local/cloudapi/1.0.0/users`", {`n  `"headers`": {`n    `"accept`": `"application/json`",`n    `"authorization`": `"Bearer $tk`",`n    `"x-vmware-vcloud-tenant-context`": `"abc`"`n  },`n  `"method`": `"GET`"`n});"
Assert-Equal (Get-BearerToken $fetch) $tk 'token text: whole multi-line Copy as fetch'
Assert-Equal (Get-BearerToken "curl 'https://v.local/cloudapi/1.0.0/users' \`n  -H 'accept: application/json' \`n  -H 'authorization: Bearer $tk' \`n  --compressed") $tk 'token text: Copy as cURL'
Assert-Equal (Get-BearerToken "Invoke-WebRequest -Uri `"https://v.local/x`" -Headers @{`n`"authorization`"=`"Bearer $tk`"`n`"accept`"=`"application/json`"}") $tk 'token text: Copy as PowerShell'
Assert-Throws { Connect-VcfaBearer "fetch(`"https://v.local/x`", {`n  `"method`": `"GET`"`n});" 'the clipboard' } '*not a token*' 'bearer: pasted request without an authorization header is refused clearly'
Assert-Throws { Connect-VcfaBearer 'one two three four five six seven' 'test' } '*not a token*' 'bearer: text with spaces is refused'
$script:FakeApi = { param($m, $u, $h, $b) @{ Status = 401; Text = 'expired'; Headers = @{}; Body = $null } }
Assert-Throws { Connect-VcfaBearer ('x' * 30) 'test' } '*probably expired*' 'bearer: expired token explained'
$script:FakeApi = { param($m, $u, $h, $b) [void]$script:Calls.Add(@{ Method = $m; Url = $u }); if ($u -like '*oauth/tenant*') { @{ Status = 200; Text = ''; Headers = @{}; Body = (J '{"access_token":"at"}') } } else { @{ Status = 200; Text = ''; Headers = @{}; Body = (J '{"org":{"name":"o","id":"urn:x:1"}}') } } }
$script:Calls.Clear()
$login = Connect-VcfaApiToken 'api' 'my-org'
Assert-True ($script:Calls[0].Url -like '*/oauth/tenant/my-org/token') 'api token: tenant exchange endpoint'
Assert-Equal $login.Headers['Authorization'] 'Bearer at' 'api token: access token used'
$script:Calls.Clear()
Remove-Item Function:\Invoke-Api

# ---- Token prompt -----------------------------------------------------------
$script:ForceInteractive = $true
$script:Answers = New-Object System.Collections.Queue
$script:Prompts = New-Object System.Collections.ArrayList
$script:ClipText = ''
function Read-Secret([string]$Prompt) { [void]$script:Prompts.Add($Prompt); return $script:Answers.Dequeue() }
function Get-Clipboard { param([switch]$Raw) return $script:ClipText }
function Write-Host { }
$script:Answers.Enqueue('typed-token'); Assert-Equal (Read-BrowserToken) 'typed-token' 'token prompt: typed token is used'
$script:ClipText = $fetch; $script:Answers.Enqueue(''); Assert-Equal (Read-BrowserToken) $fetch 'token prompt: Enter reads the whole request from the clipboard'
$script:ClipText = $fetch; $script:Answers.Enqueue(''); $got = Read-BrowserToken
Assert-Equal (Get-BearerToken $got) $tk 'token prompt: clipboard request yields the token'
$script:ClipText = ''; $script:Answers.Enqueue(''); Assert-Equal (Read-BrowserToken) '' 'token prompt: empty clipboard gives nothing'
$script:ClipText = $fetch; $script:Answers.Enqueue(''); Assert-Equal (Read-BrowserToken 'env-token') 'env-token' 'token prompt: a preset token wins over the clipboard'
Assert-True ($script:Prompts[0] -like '*press Enter to read it from the clipboard*') 'token prompt: tells the user about the clipboard'
$script:ForceInteractive = $false
Remove-Item Function:\Read-Secret, Function:\Get-Clipboard, Function:\Write-Host

# ---- Main scenarios ---------------------------------------------------------
function Invoke-Scenario {
    param([hashtable]$Params = @{}, $Imp = $IMP, $Roles = $ROLES, $VUsers = @(), $VGroups = @(), [string[]]$Answers = @(), [bool]$Interactive = $false, [hashtable]$Env = @{}, [string]$Clip = '', [string]$FailLike = '')
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try {
        & {
            param($sp, $params, $imp, $roles, $vusers, $vgroups, $answers, $interactive, $session, $clip, $failLike)
            $script:ClipText = $clip
            $script:FailLike = $failLike
            . $sp @params
            $script:ForceInteractive = $interactive
            $script:Out = New-Object System.Collections.ArrayList
            $script:Sent = New-Object System.Collections.ArrayList
            $script:Saved = @{}
            $script:Logins = New-Object System.Collections.ArrayList
            $script:Created = @{ users = New-Object System.Collections.ArrayList; groups = New-Object System.Collections.ArrayList }
            $script:Answers = New-Object System.Collections.Queue
            foreach ($a in $answers) { $script:Answers.Enqueue($a) }
            $script:Prompts = New-Object System.Collections.ArrayList
            $script:ContextHeaders = $null
            $script:TlsAsked = $null
            $script:ImportRead = $null
            function Write-Host { [void]$script:Out.Add(($args -join ' ')) }
            function Get-Clipboard { param([switch]$Raw) return $script:ClipText }
            function Read-Line([string]$Prompt) { [void]$script:Prompts.Add($Prompt); return $script:Answers.Dequeue() }
            function Read-Secret([string]$Prompt) { [void]$script:Prompts.Add($Prompt); return $script:Answers.Dequeue() }
            function Set-TlsPolicy([bool]$Verify) { $script:TlsAsked = $Verify; $script:VerifyTls = $Verify }
            function Connect-VcfaBearer([string]$Text, [string]$Source) { [void]$script:Logins.Add(@{ Kind = 'bearer'; Text = $Text; Source = $Source }); return @{ Headers = @{ Authorization = 'Bearer x' }; Session = $session } }
            function Connect-VcfaApiToken([string]$ApiToken, [string]$OrgName) { [void]$script:Logins.Add(@{ Kind = 'api'; Text = $ApiToken }); return @{ Headers = @{ Authorization = 'Bearer x' }; Session = $session } }
            function Read-ImportFile([string]$Path) { $script:ImportRead = $Path; return $imp }
            function Get-AllVcfa([string]$Path, [hashtable]$Headers, [int]$PageSize = 128, [int]$MaxPages = 200) {
                $script:ContextHeaders = $Headers
                switch ($Path) {
                    '/cloudapi/1.0.0/roles' { return @($roles) }
                    '/cloudapi/1.0.0/users' { return @(@($vusers) + @($script:Created.users)) }
                    '/cloudapi/1.0.0/groups' { return @(@($vgroups) + @($script:Created.groups)) }
                }
            }
            function Send-Vcfa([string]$Method, [string]$Path, [hashtable]$Headers, $Body) {
                [void]$script:Sent.Add(@{ Method = $Method; Path = $Path; Body = $Body })
                if ($script:FailLike -and $Path -like $script:FailLike) { return @{ Status = 403; Text = 'forbidden'; Body = $null } }
                if ($Method -eq 'POST') {
                    $bucket = if ($Path -like '*users') { 'users' } else { 'groups' }
                    [void]$script:Created[$bucket].Add($Body)
                }
                return @{ Status = 201; Text = ''; Body = $null }
            }
            function Save-Json([string]$Path, $Data) { $script:Saved[(Split-Path $Path -Leaf)] = $Data }
            $script:Report = $null
            function Write-HtmlReport([string]$Path, $Data) { $script:Report = $Data; return $true }
            $err = $null
            try { Main } catch { $err = $_.Exception.Message }
            $script:Result = @{ Out = $script:Out; Sent = $script:Sent; Saved = $script:Saved; Error = $err; Logins = $script:Logins; Prompts = $script:Prompts
                Headers = $script:ContextHeaders; Tls = $script:TlsAsked; ImportRead = $script:ImportRead; Left = $script:Answers.Count; Report = $script:Report }
        } $script:ScriptPath $Params $Imp $Roles $VUsers $VGroups $Answers $Interactive $SESSION $Clip $FailLike
        return $script:Result
    }
    finally { foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $null) } }
}
function Created-Names($R) {
    $names = Sort-Ordinal @(@($R.Saved['vcfa-plan.json']['creates']) | ForEach-Object { Get-ObjName $_ })
    return , $names
}
function Out-Has($R, [string]$Like) { return (@($R.Out | Where-Object { $_ -like $Like }).Count -gt 0) }
$BT = @{ BrowserToken = $true }
$env_bt = @{ VCFA_BROWSER_TOKEN = $TOKEN }

# default: groups only
$r = Invoke-Scenario -Params $BT -Env $env_bt
Assert-Equal $r.Error $null 'scenario: dry run has no error'
Assert-Equal (Created-Names $r) @('Infra@corp.local', 'ann@corp.local') 'default: groups plus users whose roles are not inherited (bob has no roles, so he is skipped)'
Assert-Equal @($r.Sent).Count 0 'dry run: sends nothing'
Assert-True ($null -ne $r.Saved['vcfa-plan.json']) 'dry run: writes the plan file'
Assert-True (Out-Has $r 'DRY RUN*') 'dry run: says so'
Assert-True (Out-Has $r '  Organization Member -> Organization Member') 'dry run: prints the role mapping'
Assert-True (Out-Has $r 'Project roles (1 in 1 projects) are only recorded*') 'dry run: project roles reported as recorded only'
Assert-Equal $r.Headers['x-vmware-vcloud-tenant-context'] 'abc' 'headers: tenant context from the org id'
Assert-Equal $r.Headers['x-vmware-vcloud-auth-context'] 'my-org' 'headers: auth context is the org'
Assert-True (Out-Has $r 'Users loaded because their roles are not inherited from a group: 1 (ann@corp.local: Organization Member, Service Broker User)') 'default: dry run names the users and the roles that are not inherited'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; GroupsOnly = $true } -Env $env_bt
Assert-Equal (Created-Names $r) @('Infra@corp.local') '-GroupsOnly: groups only'
Assert-True (Out-Has $r 'Users: none (-GroupsOnly)*') '-GroupsOnly: says no users are loaded'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Users = $true; GroupsOnly = $true } -Env $env_bt
Assert-True ($r.Error -like '*either -Users*') '-Users with -GroupsOnly: refused'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Users = $true } -Env $env_bt
Assert-Equal (Created-Names $r) @('Infra@corp.local', 'ann@corp.local', 'bob@corp.local') '-Users: groups and users'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('Infra@corp.local') } -Env $env_bt
Assert-Equal (Created-Names $r) @('Infra@corp.local') '-Only group: just that group'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('ann@corp.local') } -Env $env_bt
Assert-Equal (Created-Names $r) @('ann@corp.local') '-Only user: just that user, no -Users needed'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('nobody@corp.local') } -Env $env_bt
Assert-True ($r.Error -like '*nothing to create or update*') '-Only unknown name: stops'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('Infra@corp.local'); Users = $true } -Env $env_bt
Assert-Equal (Created-Names $r) @('Infra@corp.local', 'ann@corp.local') '-Only group with -Users: pulls in its members'

# login only and import file
$r = Invoke-Scenario -Params @{ BrowserToken = $true; LoginOnly = $true } -Env $env_bt
Assert-Equal $r.Error $null '-LoginOnly: ok'
Assert-Equal @($r.Saved.Keys).Count 0 '-LoginOnly: reads and writes nothing'
Assert-True ($null -eq $r.ImportRead) '-LoginOnly: import file not read'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; ImportFile = 'example-vcfa-import.json' } -Env $env_bt
Assert-Equal $r.ImportRead 'example-vcfa-import.json' '-ImportFile: that file is read'

# apply
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Users = $true; Apply = $true } -Roles $ROLES_NO_SB -Env $env_bt
Assert-True ($r.Error -like 'ERROR: not applying*') 'apply: refuses when a role is missing in VCFA'
Assert-Equal @($r.Sent).Count 0 'apply: nothing sent when refused'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Users = $true; Apply = $true; AllowMissingRoles = $true } -Roles $ROLES_NO_SB -Env $env_bt
Assert-Equal $r.Error $null '-AllowMissingRoles: goes ahead'
Assert-True ((@($r.Sent).Count) -eq 3) '-AllowMissingRoles: creates sent'
Assert-True (Out-Has $r '*would get FEWER roles than in vRA*') '-AllowMissingRoles: the shortfall is still reported'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('Infra@corp.local'); Apply = $true } -Env $env_bt
Assert-Equal $r.Error $null 'apply one group: ok'
Assert-Equal @($r.Sent).Count 1 'apply one group: one request'
Assert-Equal $r.Sent[0].Method 'POST' 'apply one group: POST'
Assert-Equal $r.Sent[0].Path '/cloudapi/1.0.0/groups' 'apply one group: groups endpoint'
Assert-Equal $r.Sent[0].Body['roleEntityRefs'][0]['name'] 'Assembler Administrator' 'apply one group: roles in the request'
Assert-True (Out-Has $r 'Done: 1 created, 0 failed') 'apply one group: summary'
Assert-True (Out-Has $r 'Role check: 1/1 objects have the same org/service roles as in vRA') 'apply one group: role check passes'
$existingGroup = J '{"id":"g9","name":"Infra@corp.local","roleEntityRefs":[{"name":"Organization Member","id":"r1"}]}'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('Infra@corp.local'); Apply = $true } -VGroups @($existingGroup) -Env $env_bt
Assert-Equal $r.Sent[0].Method 'PUT' 'apply existing group: roles added with PUT'
Assert-Equal $r.Sent[0].Path '/cloudapi/1.0.0/groups/g9' 'apply existing group: PUT path'

# prompts / wizard
$r = Invoke-Scenario -Params $BT -Interactive $true -Answers @('dev.vcfa.local', 'my-org', 'n', 'my-import.json', 'pasted-token') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-Equal $r.Error $null 'flags: prompts only for what is missing'
Assert-Equal $r.Logins[0].Text 'pasted-token' '-BrowserToken: asks for the token when it is not set'
Assert-Equal $r.ImportRead 'my-import.json' 'prompt: import file is asked'
Assert-Equal $r.Tls $false 'prompt: TLS verification is asked'
$r = Invoke-Scenario -Params $BT -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', 'my-import.json', 'pasted-token') -Env @{ VCFA_BROWSER_TOKEN = ''; VCFA_VERIFY_TLS = 'true' }
Assert-Equal $r.Tls $true 'prompt: an empty answer takes VCFA_VERIFY_TLS'
Assert-Equal $script:VcfaHost 'https://dev.vcfa.local' 'prompt: host is normalised to https'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '1', 'tok-from-wizard', '1', '', '1') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-Equal $r.Error $null 'wizard: login only run'
Assert-Equal $r.Logins[0].Kind 'bearer' 'wizard: browser token method'
Assert-Equal $r.Logins[0].Text 'tok-from-wizard' 'wizard: pasted token used'
Assert-Equal @($r.Saved.Keys).Count 0 'wizard: login-only action stops before the plan'
Assert-Equal $r.Left 0 'wizard: asked exactly the expected questions'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '1', $TOKEN, '', '', '') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-Equal (Created-Names $r) @('Infra@corp.local', 'ann@corp.local') 'wizard: default is groups plus non-inherited users, as a dry run'
Assert-Equal @($r.Sent).Count 0 'wizard: default action sends nothing'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '1', $TOKEN, '3', 'ann@corp.local', '2') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-Equal (Created-Names $r) @('ann@corp.local') 'wizard: groups and users, filtered to one name'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '1', $TOKEN, '', 'Infra@corp.local', '3', 'no') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-True ($r.Error -like '*not confirmed*') 'wizard: apply needs a typed yes'
Assert-Equal @($r.Sent).Count 0 'wizard: nothing sent without the yes'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '1', $TOKEN, '', 'Infra@corp.local', '3', 'yes') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-Equal @($r.Sent).Count 1 'wizard: typed yes applies'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '2', 'atok', '', '', '1') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-Equal $r.Logins[0].Kind 'api' 'wizard: API token method'
Assert-Equal $r.Logins[0].Text 'atok' 'wizard: pasted API token is used'
Assert-Equal @($r.Prompts | Where-Object { $_ -like '*Browser session token*' -or $_ -like '*Username*' }).Count 0 'wizard: only the two token methods are offered'
$r = Invoke-Scenario -Params @{ ApiToken = $true; LoginOnly = $true } -Env @{ VCFA_API_TOKEN = 'api-secret'; VCFA_BROWSER_TOKEN = '' }
Assert-Equal $r.Error $null '-ApiToken: ok'
Assert-Equal $r.Logins[0].Kind 'api' '-ApiToken: logs in with the API token'
Assert-Equal $r.Logins[0].Text 'api-secret' '-ApiToken: the token from VCFA_API_TOKEN is used'
$r = Invoke-Scenario -Params @{ ApiToken = $true; LoginOnly = $true } -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', 'pasted-api') -Env @{ VCFA_API_TOKEN = ''; VCFA_BROWSER_TOKEN = '' }
Assert-Equal $r.Logins[0].Text 'pasted-api' '-ApiToken: asks for the token when it is not set'
$r = Invoke-Scenario -Params @{ LoginOnly = $true } -Env @{ VCFA_API_TOKEN = 'env-api'; VCFA_BROWSER_TOKEN = '' }
Assert-Equal $r.Logins[0].Kind 'api' 'no parameter: a token already in the environment is used (API token)'
$r = Invoke-Scenario -Params @{ LoginOnly = $true } -Env @{ VCFA_BROWSER_TOKEN = $TOKEN; VCFA_API_TOKEN = '' }
Assert-Equal $r.Logins[0].Kind 'bearer' 'no parameter: a token already in the environment is used (browser token)'
$r = Invoke-Scenario -Params @{ LoginOnly = $true } -Env @{ VCFA_BROWSER_TOKEN = ''; VCFA_API_TOKEN = '' }
Assert-True ($r.Error -like '*no login method*') 'no parameter and no token: stops and says what to add'
Assert-Equal @($r.Logins).Count 0 'no login method: nothing was attempted'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; ApiToken = $true } -Env $env_bt
Assert-True ($r.Error -like '*either -BrowserToken or -ApiToken*') '-BrowserToken with -ApiToken: refused'
$r = Invoke-Scenario -Params @{} -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '1', 'tok', '', '', '1') -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-True (@($r.Prompts | Where-Object { $_ -like '*[[]https://vcfa.example.com]*' }).Count -eq 1) 'prompt: host default shown'
Assert-True (@($r.Prompts | Where-Object { $_ -like '*Infra-Admins@corp.example.com*' }).Count -eq 1) 'prompt: name filter example shown'

# the HTML report data
$r = Invoke-Scenario -Params $BT -Env $env_bt
$rep = $r.Report
Assert-Equal $rep['kind'] 'load' 'report: kind'
Assert-Equal $rep['mode'] 'dry-run' 'report: dry run mode'
Assert-Equal $rep['userMode'] 'free' 'report: default user mode'
Assert-Equal $rep['counts']['groups'] 1 'report: one group planned'
Assert-Equal $rep['counts']['users'] 1 'report: one user planned'
Assert-Equal @($rep['groups'])[0]['result'] 'planned' 'report: dry run results are "planned"'
Assert-Equal @($rep['groups'])[0]['roles'] @('Assembler Administrator') 'report: group roles'
Assert-Equal @($rep['users'])[0]['name'] 'ann@corp.local' 'report: the chosen user'
Assert-Equal @($rep['users'])[0]['notInherited'] @('Organization Member', 'Service Broker User') 'report: roles the groups do not give the user'
Assert-Equal @($rep['notLoaded'])[0]['name'] 'bob@corp.local' 'report: the user that is not loaded'
Assert-Equal @($rep['notLoaded'])[0]['reason'] 'no roles of their own' 'report: why he is not loaded'
Assert-Equal @($rep['projects'])[0]['project'] 'P1' 'report: project roles recorded'
Assert-Equal $rep['roleCheck'] $null 'report: no role check on a dry run'
Assert-Equal $rep['host'] 'https://vcfa.example.com' 'report: host'
Assert-Equal $rep['vcfa']['roles'] 3 'report: VCFA role count'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; GroupsOnly = $true } -Env $env_bt
Assert-Equal @($r.Report['notLoaded'] | ForEach-Object { $_['reason'] } | Select-Object -Unique) @('groups-only mode') 'report: groups-only reason'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Only = @('Infra@corp.local') } -Env $env_bt
Assert-Equal @($r.Report['notLoaded'] | ForEach-Object { $_['reason'] } | Select-Object -Unique) @('not selected with -Only') 'report: -Only reason'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Apply = $true } -Env $env_bt
Assert-Equal $r.Report['mode'] 'applied' 'report: applied mode'
Assert-Equal $r.Report['counts']['created'] 2 'report: created count'
Assert-Equal @($r.Report['groups'])[0]['result'] 'created' 'report: applied result per object'
Assert-Equal $r.Report['roleCheck']['total'] 2 'report: role check total'
Assert-Equal $r.Report['roleCheck']['matched'] 2 'report: role check matched'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Apply = $true } -Env $env_bt -FailLike '*groups'
Assert-Equal $r.Report['counts']['failed'] 1 'report: failed count'
Assert-Equal @($r.Report['groups'])[0]['result'] 'failed (HTTP 403)' 'report: failed result on the object'
Assert-Equal @($r.Report['failures'])[0]['name'] 'Infra@corp.local' 'report: failure is listed'
Assert-True (@($r.Report['failures'])[0]['detail'] -like 'HTTP 403*') 'report: failure detail'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Apply = $true } -Roles $ROLES_NO_SB -Env $env_bt
Assert-Equal $r.Report['mode'] 'blocked' 'report: a refused apply still writes a report, marked blocked'
Assert-Equal @($r.Report['blocked'])[0]['name'] 'ann@corp.local' 'report: blocked object named'
Assert-Equal @($r.Report['blocked'])[0]['roles'] @('Service Broker User') 'report: blocked role named'
Assert-Equal @($r.Report['groups'])[0]['result'] 'not applied' 'report: nothing applied when blocked'
Assert-Equal @($r.Report['roleMapping'] | Where-Object { $_['source'] -eq 'Service Broker User' })[0]['target'] $null 'report: missing role has no target'
Assert-Equal @($r.Report['missingRoles'])[0]['role'] 'Service Broker User' 'report: missing role listed'
$localImp = J '{"users":[{"username":"vradmin","providerType":"LOCAL"}],"groups":[],"roleBindings":[{"principalType":"user","principal":"vradmin","scope":"organization","role":"Organization Member"}]}'
$r = Invoke-Scenario -Params @{ BrowserToken = $true; Users = $true } -Imp $localImp -Env $env_bt
Assert-Equal @($r.Report['localUsers'])[0]['name'] 'vradmin' 'report: local user listed'
Assert-Equal @($r.Report['skipped'])[0]['reason'] 'local user: needs a password, create manually' 'report: local user skip reason'

# the whole copied request, read from the clipboard at the token prompt (Enter on an empty line)
$tkn = 'abcdefghijklmnopqrstuvwxyz0123'
$copied = "fetch(`"https://v.local/cloudapi/1.0.0/users`", {`n  `"headers`": {`n    `"authorization`": `"Bearer $tkn`"`n  }`n});"
$r = Invoke-Scenario -Params $BT -Interactive $true -Answers @('dev.vcfa.local', 'my-org', '', '', '') -Env @{ VCFA_BROWSER_TOKEN = '' } -Clip $copied
Assert-Equal $r.Error $null 'clipboard: login proceeds after reading the copied request'
Assert-Equal $r.Logins[0].Text $copied 'clipboard: the whole copied request is handed to the token extractor'
Assert-Equal $r.Left 0 'clipboard: nothing left over to answer later prompts'

# non-interactive
$r = Invoke-Scenario -Params @{ BrowserToken = $true } -Env @{ VCFA_BROWSER_TOKEN = $TOKEN; VCFA_HOST = 'dev.vcfa.local'; VCFA_ORG = 'envorg' }
Assert-Equal $r.Error $null 'no terminal: uses env defaults without prompting'
Assert-Equal $script:VcfaHost 'https://dev.vcfa.local' 'no terminal: env host normalised'
Assert-Equal $r.Headers['x-vmware-vcloud-auth-context'] 'envorg' 'no terminal: env org used'
$r = Invoke-Scenario -Params @{ BrowserToken = $true } -Env @{ VCFA_BROWSER_TOKEN = '' }
Assert-True ($r.Error -like '*no token given*') 'no terminal and no token: stops with a clear message'

foreach ($n in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }
Say "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail) { exit 1 }

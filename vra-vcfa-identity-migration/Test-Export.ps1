<#
.SYNOPSIS
    Offline tests for Export-VraIdentity.ps1 (no network, no Pester needed).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Export.ps1
#>
$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Say([string]$Text) { [Console]::Out.WriteLine($Text) }   # not Write-Host: tests silence that
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

. (Join-Path $PSScriptRoot 'Export-VraIdentity.ps1')
$script:ForceInteractive = $false

function J($Text) { return , (ConvertFrom-JsonText $Text) }   # comma keeps arrays from unrolling
$USER = J '{"orgId":"org1","user":{"username":"aaron","firstName":"Aaron","lastName":"L","domain":"corp.example.com","email":"aaron@corp.example.com","userId":"u1"},"organizationRoles":[{"name":"org_member"}],"serviceRoles":[{"serviceRoles":[{"name":"catalog:user"},{"name":"saltstack:admin"}]}]}'
$SYS_USER = J '{"user":{"username":"admin","domain":"System Domain","email":"a@example.com","userId":"u2"},"organizationRoles":[{"name":"org_owner"}],"serviceRoles":[{"serviceRoles":[{"name":"CodeStream:administrator"},{"name":"weird:role"}]}]}'
$GROUP = J '{"id":"g1","displayName":"Infra@corp.example.com","domain":"corp.example.com","groupType":"AD_GROUP","organizationRoles":[{"name":"org_member"}],"serviceRoles":[{"serviceRoleNames":["catalog:admin","orchestration:viewer"]}]}'
$PROJECT = J '{"name":"P1","administrators":[{"email":"aaron@corp.example.com","type":"user"}],"members":[{"email":"Infra@corp.example.com","type":"group"}]}'
function Copy-Obj($o) { return (J (ConvertTo-Json -InputObject $o -Depth 30)) }
function Has-Binding($Imp, $Principal, $Scope, $Role) {
    foreach ($b in $Imp['roleBindings']) { if ($b['principal'] -eq $Principal -and $b['scope'] -eq $Scope -and $b['role'] -eq $Role) { return $true } }
    return $false
}

# ---- Host input -------------------------------------------------------------
Assert-Equal (ConvertTo-HostUrl 'dev.vra.local') 'https://dev.vra.local' 'host: bare fqdn gets https'
Assert-Equal (ConvertTo-HostUrl '  Dev.VRA.local  ') 'https://dev.vra.local' 'host: trimmed and lower-cased'
Assert-Equal (ConvertTo-HostUrl 'https://dev.vra.local/') 'https://dev.vra.local' 'host: trailing slash dropped'
Assert-Equal (ConvertTo-HostUrl 'https://dev.vra.local/csp/gateway?x=1') 'https://dev.vra.local' 'host: path and query dropped'
Assert-Equal (ConvertTo-HostUrl 'http://dev.vra.local') 'http://dev.vra.local' 'host: explicit http kept'
Assert-Equal (ConvertTo-HostUrl 'dev.vra.local:8443/') 'https://dev.vra.local:8443' 'host: port kept'
Assert-Equal (ConvertTo-HostUrl 'HTTPS://dev.vra.local') 'https://dev.vra.local' 'host: scheme case'
foreach ($bad in '', '   ', 'dev vra.local', 'ftp://dev.vra.local', 'https://', 'user:pw@dev.vra.local', 'dev.vra.local:notaport') {
    Assert-Throws { ConvertTo-HostUrl $bad } '*' "host: rejects '$bad'"
}

# ---- Prompts ----------------------------------------------------------------
$script:ForceInteractive = $false
Assert-Equal (Read-Value 'x' 'dflt') 'dflt' 'ask: default without terminal'
Assert-Equal (Confirm-Yes 'x' $true) $true 'confirm: default without terminal'
Assert-Equal (Select-Option 'pick' @(@{ Value = 'a'; Text = 'A' }, @{ Value = 'b'; Text = 'B' }) 2) 'b' 'choose: default without terminal'
Assert-Throws { Read-HostUrl 'host' '' } '*host*' 'host prompt: empty default without terminal dies'
Assert-Equal (Read-HostUrl 'host' 'https://x.local/') 'https://x.local' 'host prompt: default normalised without terminal'

$script:ForceInteractive = $true
$script:Answers = New-Object System.Collections.Queue
$script:Prompts = New-Object System.Collections.ArrayList
function Read-Line([string]$Prompt) { [void]$script:Prompts.Add($Prompt); return $script:Answers.Dequeue() }
function Read-Secret([string]$Prompt) { return $script:Answers.Dequeue() }
function Set-Answers { $script:Answers.Clear(); $script:Prompts.Clear(); foreach ($a in $args) { $script:Answers.Enqueue($a) } }
function Write-Host { }   # keep test output quiet

Set-Answers 'typed'; Assert-Equal (Read-Value 'x' 'dflt') 'typed' 'ask: typed value wins'
Set-Answers ''; Assert-Equal (Read-Value 'x' 'dflt') 'dflt' 'ask: Enter accepts default'
Set-Answers ''; [void](Read-Value 'Thing' '' -Example 'foo@bar'); Assert-True ($script:Prompts[0] -like '*(e.g. foo@bar)*') 'ask: example shown when no default'
Set-Answers 'secret'; Assert-Equal (Read-Value 'pw' '' -Secret) 'secret' 'ask: secret value'
Set-Answers '' 'maybe' 'Y'; Assert-Equal (Confirm-Yes 'x' $false) $false 'confirm: Enter keeps default false'
Set-Answers 'maybe' 'Y'; Assert-Equal (Confirm-Yes 'x' $false) $true 'confirm: re-asks until y/n'
Set-Answers '9' 'x' '2'; Assert-Equal (Select-Option 'pick' @(@{ Value = 'a'; Text = 'A' }, @{ Value = 'b'; Text = 'B' })) 'b' 'choose: retries until valid'
Set-Answers '' 'bad host' 'dev.vra.local'; Assert-Equal (Read-HostUrl 'host' '' 'dev.vra.local') 'https://dev.vra.local' 'host prompt: re-asks and adds https'
$script:ForceInteractive = $false

# ---- Parsing ----------------------------------------------------------------
Assert-Equal @(Get-ItemsOf (J '[1]')) @(1) 'items_of: list'
Assert-Equal @(Get-ItemsOf (J '{"results":[1]}')) @(1) 'items_of: results'
Assert-Equal @(Get-ItemsOf (J '{"content":[2]}')) @(2) 'items_of: content'
Assert-Equal @(Get-ItemsOf (J '{"items":null}')).Count 0 'items_of: null items'
Assert-Equal (Get-PrincipalDomain $USER) 'corp.example.com' 'domain: nested user'
Assert-Equal (Get-PrincipalDomain $SYS_USER) 'System Domain' 'domain: system'
Assert-Equal (Get-PrincipalName $USER) 'aaron@corp.example.com' 'name: user'
Assert-Equal (Get-PrincipalName $GROUP) 'Infra@corp.example.com' 'name: group displayName'
Assert-Equal (Get-PrincipalDomain (J '{"username":"x@corp.local"}')) 'corp.local' 'domain: @ suffix fallback'
Assert-Equal @(Get-RoleNames $USER) @('org_member', 'catalog:user', 'saltstack:admin') 'role_names: user'
Assert-Equal @(Get-RoleNames $GROUP) @('org_member', 'catalog:admin', 'orchestration:viewer') 'role_names: group'
Assert-Equal (Get-Upn (J '{"user":{"username":"olga","domain":"corp.example.com"}}')) 'olga@corp.example.com' 'upn: adds domain'
Assert-Equal (Get-Upn $SYS_USER) 'admin' 'upn: system domain stays bare'
Assert-True (Test-IgnoredRole 'CodeStream:administrator') 'ignored: codestream (case-insensitive)'
Assert-True (-not (Test-IgnoredRole 'catalog:user')) 'ignored: catalog is kept'

$script:IncludeDomains = @('corp.example.com')
Assert-True (Test-InScope $USER) 'scope: in selected domain'
Assert-True (-not (Test-InScope $SYS_USER)) 'scope: out of selected domain'
$script:IncludeDomains = @()
Assert-True (Test-InScope $SYS_USER) 'scope: empty list = everything'

# ---- Env settings, domain list and the domains step ------------------------
Assert-True (Get-FlagSetting 'TRUE' $false) 'flag: env true (any case)'
Assert-True (-not (Get-FlagSetting 'off' $true)) 'flag: env off'
Assert-True (Get-FlagSetting 'maybe' $true) 'flag: unknown text keeps the default'
Assert-True (-not (Get-FlagSetting '' $false)) 'flag: blank keeps the default'
Assert-Equal @(ConvertTo-DomainList 'ALL').Count 0 'domains: all = no filter'
Assert-Equal @(ConvertTo-DomainList ' corp.example.com , System Domain ,') @('corp.example.com', 'System Domain') 'domains: list trimmed, blanks dropped'
$domLines = @(Get-DomainLines @($USER, $SYS_USER) @($GROUP))
Assert-Equal $domLines.Count 2 'domain lines: one per domain'
Assert-Equal $domLines[0] 'DOMAIN: corp.example.com | users 1 | groups 1' 'domain lines: counts, sorted without case'
Assert-Equal $domLines[1] 'DOMAIN: System Domain | users 1 | groups 0' 'domain lines: system domain'

# ---- Shaping ----------------------------------------------------------------
$s = Get-Summary (Copy-Obj $USER)
Assert-Equal $s['serviceRoles'] @('catalog:user') 'summary: ignored service roles removed'
Assert-Equal $s['organizationRoles'] @('org_member') 'summary: org roles'
$t = Get-TrimmedUser $USER
Assert-True (-not $t['user'].Contains('orgId')) 'trim_user: no per-user orgId'
Assert-Equal ($t['user'].Keys | Sort-Object) @('domain', 'email', 'firstName', 'lastName', 'userId', 'username') 'trim_user: kept fields'
$tp = Get-TrimmedProject (J '{"id":"1","name":"P","zones":[{}],"constraints":{},"orgId":"o","administrators":[{"email":"a","type":"user"}]}')
Assert-Equal @($tp.Keys) @('id', 'name', 'administrators') 'trim_project: kept fields'

# ---- Import building --------------------------------------------------------
$imp = New-VcfaImport @($USER, $SYS_USER) @($GROUP) @($PROJECT)
Assert-True (Has-Binding $imp 'aaron@corp.example.com' 'organization' 'Organization Member') 'import: org role mapped'
Assert-True (Has-Binding $imp 'aaron@corp.example.com' 'organization' 'Service Broker User') 'import: service role mapped'
Assert-True (Has-Binding $imp 'admin' 'organization' 'Organization Owner') 'import: system user role'
Assert-True (Has-Binding $imp 'Infra@corp.example.com' 'organization' 'Service Broker Administrator') 'import: group role'
Assert-True (Has-Binding $imp 'aaron@corp.example.com' 'project:P1' 'Project Administrator') 'import: project role recorded'
Assert-True (Has-Binding $imp 'Infra@corp.example.com' 'project:P1' 'Project User') 'import: project group role recorded'
$all = @($imp['roleBindings'] | ForEach-Object { $_['vraRole'] })
Assert-True (-not ($all -contains 'saltstack:admin')) 'import: saltstack ignored'
Assert-True (-not ($all -contains 'CodeStream:administrator')) 'import: codestream ignored'
Assert-Equal @($imp['warnings']) @("unmapped role 'weird:role' for user 'admin' (organization)") 'import: only unmapped role warns'
Assert-Equal ($imp['roleBindings'] | Where-Object { $_['role'] -eq 'Assembler Administrator' }).Count 0 'import: no phantom roles'
$prov = @{}; foreach ($u in $imp['users']) { $prov[$u['username']] = $u['providerType'] }
Assert-Equal $prov['aaron@corp.example.com'] 'OAUTH' 'import: directory user is OAUTH'
Assert-Equal $prov['admin'] 'LOCAL' 'import: system user is LOCAL'
Assert-Equal @($imp['groups'])[0]['providerType'] 'OAUTH' 'import: group is OAUTH'
$noWarn = New-VcfaImport @($USER) @($GROUP) @($PROJECT)
Assert-True (-not $noWarn.Contains('warnings')) 'import: no warnings when all roles map'

$g2 = Copy-Obj $GROUP; $g2['members'] = @(J '{"userId":"u9","username":"adiel","domain":"corp.example.com","email":"adiel@corp.example.com"}')
$imp = New-VcfaImport @($USER) @($g2) @()
Assert-Equal @($imp['groups'])[0]['members'] @('adiel@corp.example.com') 'import: group members as UPN'
Assert-True (@($imp['users'] | Where-Object { $_['username'] -eq 'adiel@corp.example.com' }).Count -eq 1) 'import: group member added as user'

# Project members arrive as bare usernames and must resolve to UPNs.
$other = J '{"user":{"username":"adiel","domain":"corp.example.com","email":"adiel@corp.example.com","firstName":"Adi","lastName":"El","userId":"u9"},"organizationRoles":[],"serviceRoles":[]}'
$proj2 = J '{"name":"P2","administrators":[{"email":"adiel","type":"user"}],"members":[{"email":"aaron","type":"user"},{"email":"ghost","type":"user"}]}'
$imp = New-VcfaImport @($USER) @() @($proj2) @($USER, $other)
Assert-True (@($imp['users'] | Where-Object { $_['username'] -eq 'adiel@corp.example.com' }).Count -eq 1) 'project-only: user added'
Assert-True (Has-Binding $imp 'adiel@corp.example.com' 'project:P2' 'Project Administrator') 'project-only: bare name resolved'
Assert-True (Has-Binding $imp 'adiel@corp.example.com' 'organization' 'Organization Member') 'project-only: gets org member'
Assert-Equal @($imp['projectOnlyUsers']) @('adiel@corp.example.com') 'project-only: listed'
Assert-Equal (@($imp['users'] | Where-Object { $_['username'] -eq 'aaron@corp.example.com' }).Count) 1 'project-only: existing user not duplicated'
Assert-Equal (@($imp['roleBindings'] | Where-Object { $_['principal'] -eq 'aaron@corp.example.com' -and $_['scope'] -eq 'organization' -and $_['role'] -eq 'Organization Member' }).Count) 1 'project-only: existing user gets no extra org binding'
Assert-Equal @($imp['unresolvedProjectUsers']) @('ghost') 'project-only: unknown user listed'
Assert-True (@($imp['warnings'] | Where-Object { $_ -like '*ghost*' }).Count -eq 1) 'project-only: unknown user warned'
Assert-True (@($imp['users'] | Where-Object { $_['username'] -like 'ghost*' }).Count -eq 0) 'project-only: unknown user not guessed'
$imp = New-VcfaImport @($USER) @() @($proj2) @($USER, $other) 'corp.example.com'
Assert-True (@($imp['users'] | Where-Object { $_['username'] -eq 'ghost@corp.example.com' }).Count -eq 1) 'project-only: default domain resolves unknown user'
Assert-True (-not $imp.Contains('unresolvedProjectUsers')) 'project-only: nothing unresolved with default domain'
$imp = New-VcfaImport @($USER) @($g2) @($proj2) @($USER, $other)
Assert-True (-not $imp.Contains('projectOnlyUsers')) 'project-only: group member is not project-only'

# Each user records the groups they belong to.
$g3 = Copy-Obj $GROUP; $g3['members'] = @(J '{"userId":"u1","username":"aaron","domain":"corp.example.com"}')
$imp = New-VcfaImport @((Copy-Obj $USER), (Copy-Obj $SYS_USER)) @($g3) @()
$byName = @{}; foreach ($u in $imp['users']) { $byName[$u['username']] = $u }
Assert-Equal @($byName['aaron@corp.example.com']['memberOf']) @('Infra@corp.example.com') 'memberOf: user lists their groups'
Assert-True (-not $byName['admin'].Contains('memberOf')) 'memberOf: absent for users in no group'

# ---- Ordinal sorting used by the reports
$rowsS = @([ordered]@{ n = 'b@x' }, [ordered]@{ n = 'A@x' }, [ordered]@{ n = 'a-b@x' }, [ordered]@{ n = 'c@x' })
$sorted = Sort-ByKey $rowsS { param($x) $x['n'].ToLower() }
Assert-Equal @($sorted | ForEach-Object { $_['n'] }) @('a-b@x', 'A@x', 'b@x', 'c@x') 'sort: ordinal on the lower-cased key (punctuation before letters, like Python)'
Assert-Equal @((Sort-ByKey @([ordered]@{ n = 'only' }) { param($x) $x['n'] })).Count 1 'sort: a single row is returned as is'
Assert-Equal @((Sort-ByKey @() { param($x) $x })).Count 0 'sort: nothing in, nothing out'
Assert-Equal (Sort-Ordinal @('b', 'B', 'a', '_')) @('B', '_', 'a', 'b') 'sort: ordinal puts upper case before lower case'

# ---- The HTML report data and file -------------------------------------------
$g4 = Copy-Obj $GROUP; $g4['members'] = @(J '{"userId":"u1","username":"aaron","domain":"corp.example.com"}')
$u4 = @((Copy-Obj $USER), (Copy-Obj $SYS_USER))
$other4 = J '{"user":{"username":"adiel","domain":"other.example.com","email":"adiel@other.example.com","userId":"u3"},"organizationRoles":[],"serviceRoles":[]}'
$proj4 = @((J '{"name":"P1","administrators":[{"email":"aaron","type":"user"}],"members":[{"email":"adiel","type":"user"},{"email":"ghost","type":"user"},{"email":"Infra@corp.example.com","type":"group"}],"viewers":[]}'))
$imp4 = New-VcfaImport $u4 @($g4) $proj4 (@($u4) + @($other4))
$failed4 = @([ordered]@{ name = 'Broken@corp.example.com'; status = 403 })
$rep = New-ExportReportData -Imp $imp4 -Users $u4 -Groups @($g4) -Projects $proj4 -UsersAll 5 -GroupsAll 2 -Org 'org-1' -DomainsSeen @('System Domain', 'corp.example.com') `
    -Files @('a.json', 'b.json') -FailedMembers $failed4 -OutputDir 'C:\out' -Endpoints @{ users = '/u'; groups = '/g' }
Assert-Equal $rep['kind'] 'export' 'report: kind'
Assert-Equal $rep['counts']['users'] 2 'report: org users in the selected domains'
Assert-Equal $rep['counts']['usersAll'] 5 'report: org users in vRA'
Assert-Equal $rep['counts']['usersInImport'] @($imp4['users']).Count 'report: users in the import file'
Assert-Equal $rep['counts']['groups'] 1 'report: groups'
Assert-Equal $rep['counts']['warnings'] @($imp4['warnings']).Count 'report: warnings count matches the import file'
$gr = @($rep['groups'])[0]
Assert-Equal $gr['name'] 'Infra@corp.example.com' 'report: group name'
Assert-Equal $gr['members'] 1 'report: group member count'
Assert-Equal @($gr['roles']) @('Orchestrator Viewer', 'Organization Member', 'Service Broker Administrator') 'report: group roles, sorted'
$aaron = @($rep['users'] | Where-Object { $_['name'] -eq 'aaron@corp.example.com' })[0]
Assert-Equal @($aaron['memberOf']) @('Infra@corp.example.com') 'report: user group membership'
Assert-Equal @($aaron['roles']) @('Organization Member', 'Service Broker User') 'report: user own roles (ignored services left out)'
Assert-Equal $aaron['projectOnly'] $false 'report: ordinary user is not project-only'
$adiel = @($rep['users'] | Where-Object { $_['name'] -eq 'adiel@other.example.com' })[0]
Assert-Equal $adiel['projectOnly'] $true 'report: project-only user flagged'
$weird = @($rep['roleMapping'] | Where-Object { $_['vraRole'] -eq 'weird:role' })[0]
Assert-Equal $weird['role'] $null 'report: unmapped role shows no VCFA role'
Assert-Equal $weird['bindings'] 1 'report: unmapped role use counted'
$owner = @($rep['roleMapping'] | Where-Object { $_['vraRole'] -eq 'org_owner' })[0]
Assert-Equal $owner['role'] 'Organization Owner' 'report: role mapping target'
Assert-Equal @($rep['roleMapping'] | Where-Object { $_['vraRole'] -eq 'project:administrators' })[0]['scope'] 'project' 'report: project roles marked as project scope'
$titles = @($rep['attention'] | ForEach-Object { $_['tone'] + ':' + $_['title'].Substring(0, 20) })
Assert-Equal $titles @('warn:Group member lists t', 'warn:vRA roles with no VC', 'warn:Project members that', 'info:Users added because ') 'report: attention items and their order'
Assert-Equal @($rep['attention'][0]['items']) @('Broken@corp.example.com (HTTP 403)') 'report: failed member list is named'
Assert-Equal @($rep['attention'][2]['items']) @('ghost') 'report: unresolved project user named'
Assert-Equal @($rep['projects'])[0]['members'] 3 'report: project member count (two users and a group)'
Assert-Equal @($rep['projects'])[0]['viewers'] 0 'report: empty project role counted as zero'
Assert-Equal @($rep['files']) @('a.json', 'b.json') 'report: files'
Assert-Equal @($rep['roleMapping'] | ForEach-Object { $_['vraRole'] + '|' + $_['scope'] }) @($rep['roleMapping'] | ForEach-Object { $_['vraRole'] + '|' + $_['scope'] } | Sort-Object { $_ } -CaseSensitive) 'report: role mapping rows are in a stable sorted order'

# Writing the HTML: data is embedded safely and the template placeholder is replaced.
$dir5 = Join-Path ([System.IO.Path]::GetTempPath()) ("vra-rep-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir5)
try {
    $evil = '</script><script>alert(1)</script>'
    $e5 = [string][char]233
    $data5 = [ordered]@{ kind = 'export'; name = "$evil caf$e5"; list = @('x') }
    $ok5 = Write-HtmlReport (Join-Path $dir5 'r.html') $data5
    Assert-True $ok5 'html report: written'
    $html = [System.IO.File]::ReadAllText((Join-Path $dir5 'r.html'), [System.Text.Encoding]::UTF8)
    Assert-True (-not $html.Contains('/*REPORT_DATA*/')) 'html report: placeholder replaced'
    Assert-Equal ([regex]::Matches($html, '</script>').Count) 2 'html report: data cannot close the script tag (only the 2 template tags remain)'
    $m5 = [regex]::Match($html, 'id="report-data" type="application/json">(.*?)</script>', 'Singleline')
    $back = ConvertFrom-JsonText $m5.Groups[1].Value
    Assert-Equal $back['name'] "$evil caf$e5" 'html report: embedded data round-trips, including markup and non-ASCII'
    Assert-True ($html -like '*<title>vRA to VCFA migration report</title>*') 'html report: the template is used'
}
finally { Remove-Item -Recurse -Force $dir5 }

# ---- API paging and discovery (HTTP faked) ----------------------------------
function Get-VraJson([string]$Path, [string]$Token, $Params = $null) { return (& $script:FakeGet $Path $Params) }
$script:FakeGet = { param($p, $q) $page = $q['page']; @{ Status = 200; Text = ''; Body = (J ('{"content":[' + ((@(1..3) | ForEach-Object { '{"id":' + ($page * 3 + $_) + '}' }) -join ',') + '],"totalPages":2}')) } }
$r = Get-AllVra '/x' 'tok' 3
Assert-Equal @($r.Items | ForEach-Object { $_['id'] }) @(1, 2, 3, 4, 5, 6) 'paging: follows totalPages'
$script:FakeGet = { param($p, $q) @{ Status = 200; Text = ''; Body = (J '{"results":[{"id":1},{"id":2}]}') } }
$r = Get-AllVra '/x' 'tok' 100
Assert-Equal @($r.Items | ForEach-Object { $_['id'] }) @(1, 2) 'paging: API that ignores paging does not loop'
$script:FakeGet = { param($p, $q) @{ Status = 403; Text = 'no'; Body = $null } }
$r = Get-AllVra '/x' 'tok'
Assert-Equal $r.Status 403 'paging: error status returned'
$script:FakeGet = { param($p, $q) if ($p -like '*v2*') { @{ Status = 404; Text = ''; Body = $null } } else { @{ Status = 200; Text = ''; Body = (J '[{"id":1}]') } } }
$r = Find-FirstWorking @('/v2/{org}', '/v1/{org}') 'o' 'tok'
Assert-Equal $r.Path '/v1/o' 'first_working: skips 404'
Assert-Equal @($r.Items).Count 1 'first_working: items'
$script:FakeGet = { param($p, $q) @{ Status = 200; Text = ''; Body = (J '{"refLinks":["/csp/gateway/am/api/orgs/abc-123"],"items":null}') } }
Assert-Equal (Get-OrgId 'tok') 'abc-123' 'org id: from refLinks'

# ---- Output files -----------------------------------------------------------
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("vra-test-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
try {
    $data = [ordered]@{ one = @('x'); none = @(); name = "caf$([char]0xE9)" }
    Save-Json (Join-Path $dir 'a.json') $data
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir 'a.json'))
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'save: no BOM'
    $back = J ([System.IO.File]::ReadAllText((Join-Path $dir 'a.json'), [System.Text.Encoding]::UTF8))
    Assert-True ($back['one'] -is [array]) 'save: one-element array stays an array'
    Assert-Equal @($back['none']).Count 0 'save: empty array stays empty'
    Assert-Equal $back['name'] "caf$([char]0xE9)" 'save: non-ASCII round trip'
}
finally { Remove-Item -Recurse -Force $dir }

Say "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail) { exit 1 }

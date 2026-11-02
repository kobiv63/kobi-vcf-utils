/**
 * vRO scriptable task: export vRA users, groups and their roles, return JSON string.
 *
 * Inputs:
 *   restHost        REST:RESTHost   REST host for https://vra.example.com (no authentication set on the host)
 *   username        string
 *   password        SecureString
 *   domain          string          e.g. "corp.example.com"
 *   includeDomains  Array/string    optional, e.g. ["System Domain","corp.example.com"]; empty = all
 * Output:
 *   result          string          JSON: { meta, users: [...], groups: [...] }
 *
 * Same endpoints and parsing as export_vra_identity.py. vRO scripting is ES5: no const/let/arrow functions.
 */

var IGNORE_ROLE_PREFIXES = ["saltstack:", "codestream:"];
var PAGE_SIZE = 100;
var MAX_PAGES = 50;

function call(method, path, token, body, form) {
    var req = restHost.createRequest(method, path, form ? null : (body ? JSON.stringify(body) : null));
    if (form) {
        req.contentType = "application/x-www-form-urlencoded";
        req.content = form;
    } else {
        req.contentType = "application/json";
    }
    req.setHeader("Accept", "application/json");
    if (token) {
        req.setHeader("Authorization", "Bearer " + token);
    }
    var resp = req.execute();
    return { status: resp.statusCode, text: resp.contentAsString };
}

function mustJson(r, what) {
    if (r.status !== 200) {
        throw what + " failed (" + r.status + "): " + String(r.text).substring(0, 300);
    }
    return JSON.parse(r.text);
}

function login() {
    var r = call("POST", "/csp/gateway/am/api/login?access_token", null,
        { username: username, password: password, domain: domain });
    var refresh = mustJson(r, "login").refresh_token;
    r = call("POST", "/csp/gateway/am/api/auth/api-tokens/authorize", null, null,
        "refresh_token=" + encodeURIComponent(refresh));
    return mustJson(r, "token authorize").access_token;
}

function getOrgId(token) {
    var body = mustJson(call("GET", "/csp/gateway/am/api/loggedin/user/orgs", token), "list orgs");
    var link = body.refLinks && body.refLinks[0];
    if (link) { return link.split("/").pop(); }
    var items = itemsOf(body);
    return items.length ? (items[0].id || items[0].orgId) : null;
}

function itemsOf(body) {
    if (body instanceof Array) { return body; }
    var keys = ["results", "content", "items", "values"];
    for (var i = 0; i < keys.length; i++) {
        if (body[keys[i]] instanceof Array) { return body[keys[i]]; }
    }
    return [];
}

/** Returns array, or null if the endpoint does not exist (e.g. 404). */
function getAll(path, token) {
    var out = [], prevFirst = null;
    for (var page = 0; page < MAX_PAGES; page++) {
        var r = call("GET", path + "?page=" + page + "&size=" + PAGE_SIZE, token);
        if (r.status !== 200) { return page === 0 ? null : out; }
        var body = JSON.parse(r.text);
        var batch = itemsOf(body);
        if (batch.length === 0) { break; }
        var first = JSON.stringify(batch[0]);
        if (first === prevFirst) { break; }  // API ignored paging
        prevFirst = first;
        out = out.concat(batch);
        if (batch.length < PAGE_SIZE) { break; }
        if (body.totalPages !== undefined && page + 1 >= body.totalPages) { break; }
    }
    return out;
}

function firstWorking(paths, token) {
    for (var i = 0; i < paths.length; i++) {
        var items = getAll(paths[i], token);
        if (items !== null) { return items; }
    }
    return [];
}

function principalDomain(p) {
    var u = p.user || p;
    if (u.domain) { return u.domain; }
    if (u.identityProviderDomain) { return u.identityProviderDomain; }
    var keys = ["username", "email", "name"];
    for (var i = 0; i < keys.length; i++) {
        var v = u[keys[i]] || "";
        if (v.indexOf("@") >= 0) { return v.split("@")[1]; }
    }
    return "System Domain";
}

function principalName(p) {
    var u = p.user || p;
    return u.email || u.username || u.displayName || u.name || u.userId || u.id;
}

function inScope(p) {
    if (!includeDomains || includeDomains.length === 0) { return true; }
    var d = principalDomain(p).toLowerCase();
    for (var i = 0; i < includeDomains.length; i++) {
        if (String(includeDomains[i]).toLowerCase() === d) { return true; }
    }
    return false;
}

function ignored(role) {
    var r = role.toLowerCase();
    for (var i = 0; i < IGNORE_ROLE_PREFIXES.length; i++) {
        if (r.indexOf(IGNORE_ROLE_PREFIXES[i]) === 0) { return true; }
    }
    return false;
}

/** Service role names: users use serviceRoles[].serviceRoles[].name, groups use serviceRoles[].serviceRoleNames[]. */
function serviceRoleNames(p) {
    var names = [];
    var list = p.serviceRoles || [];
    for (var i = 0; i < list.length; i++) {
        var sr = list[i];
        if (typeof sr === "string") { names.push(sr); continue; }
        var byName = sr.serviceRoleNames || [];
        for (var j = 0; j < byName.length; j++) { names.push(byName[j]); }
        var nested = sr.serviceRoles || [];
        for (var k = 0; k < nested.length; k++) {
            if (nested[k].name) { names.push(nested[k].name); }
        }
    }
    return names.filter(function (n) { return !ignored(n); });
}

function summarize(p) {
    var u = p.user || p;
    var orgRoles = [];
    var o = p.organizationRoles || [];
    for (var i = 0; i < o.length; i++) {
        orgRoles.push(typeof o[i] === "string" ? o[i] : o[i].name);
    }
    return {
        id: u.userId || p.id,
        name: principalName(p),
        domain: principalDomain(p),
        email: u.email || null,
        firstName: u.firstName || null,
        lastName: u.lastName || null,
        groupType: p.groupType || null,
        organizationRoles: orgRoles,
        serviceRoles: serviceRoleNames(p)
    };
}

var token = login();
var org = getOrgId(token);
if (!org) { throw "could not determine org id"; }

var users = firstWorking([
    "/csp/gateway/am/api/v2/orgs/" + org + "/users",
    "/csp/gateway/am/api/orgs/" + org + "/users"
], token).filter(inScope);

var groups = firstWorking([
    "/csp/gateway/am/api/v2/orgs/" + org + "/groups",
    "/csp/gateway/am/api/orgs/" + org + "/groups",
    "/csp/gateway/am/api/v3/orgs/" + org + "/groups"
], token).filter(inScope);

result = JSON.stringify({
    meta: { orgId: org, exportedAt: new Date().toISOString(), users: users.length, groups: groups.length },
    users: users.map(summarize),
    groups: groups.map(summarize)
}, null, 2);

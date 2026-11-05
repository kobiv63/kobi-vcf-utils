"""Tests for the interactive flow of load_vcfa.py: python -m unittest test_load"""
import unittest
from unittest import mock

import load_vcfa as L

SESSION = {"org": {"name": "my-org", "id": "urn:vcloud:org:abc"}, "roles": ["Organization Administrator"]}


class Wizard(unittest.TestCase):
    def run_main(self, argv, answers=(), tty=True, secret="tok" * 10):
        with mock.patch("sys.argv", ["load_vcfa.py", *argv]),                 mock.patch("sys.stdin.isatty", return_value=tty),                 mock.patch("builtins.input", side_effect=list(answers)),                 mock.patch("getpass.getpass", return_value=secret),                 mock.patch.object(L, "bearer_login", return_value=({}, SESSION)) as bl,                 mock.patch.object(L, "token_login", return_value=({}, SESSION)) as tl,                 mock.patch.object(L, "get_all") as ga:
            L.main()
        self.tl = tl
        return bl, ga

    def test_login_only_flag_stops_before_reading_vcfa_objects(self):
        with mock.patch.object(L, "VCFA_BROWSER_TOKEN", "tok" * 10):
            bl, ga = self.run_main(["--org", "my-org", "--browser-token", "--login-only"], tty=False)
        bl.assert_called_once()
        ga.assert_not_called()

    def test_wizard_login_only_with_browser_token(self):
        # URL, org, TLS (default), import file (default), login method 1 (browser), groups-only default, filter blank, action 1 (login only)
        with mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""):
            bl, ga = self.run_main([], ["https://vcfa.example", "my-org", "", "", "1", "1", "", "1"])
        bl.assert_called_once()
        self.assertEqual(bl.call_args.kwargs["text"], "tok" * 10)
        ga.assert_not_called()

    def test_wizard_defaults_to_groups_and_users(self):
        with mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""),                 mock.patch.object(L, "build_plan", side_effect=AssertionError("stop")),                 mock.patch("builtins.open", mock.mock_open(read_data='{"users": [], "groups": [], "roleBindings": []}')):
            with self.assertRaises(AssertionError):
                # URL, org, browser token, groups-and-users (default), no filter, dry run (default)
                self.run_main([], ["https://vcfa.example", "my-org", "", "", "1", "", "", ""])

    def test_import_file_and_tls_are_asked(self):
        opened = []
        real = mock.mock_open(read_data='{"users": [], "groups": [], "roleBindings": []}')

        def fake_open(path, *a, **k):
            opened.append(path)
            return real(path, *a, **k)
        with mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""), mock.patch.object(L, "IMPORT_FILE", "vcfa-import.json"),                 mock.patch.object(L, "build_plan", side_effect=AssertionError("stop")),                 mock.patch("builtins.open", fake_open):
            with self.assertRaises(AssertionError):
                # URL, org, TLS = y, import file, browser method, groups only, no filter, dry run
                self.run_main([], ["https://vcfa.example", "my-org", "y", "my-import.json", "1", "", "", ""])
        self.assertIn("my-import.json", opened)
        self.assertTrue(L.s.verify)
        L.s.verify = False

    def test_tls_setting_comes_from_env(self):
        with mock.patch.dict("os.environ", {"VCFA_VERIFY_TLS": "true"}), \
                mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""), \
                mock.patch.object(L, "build_plan", side_effect=AssertionError("stop")), \
                mock.patch("builtins.open", mock.mock_open(read_data='{"users": [], "groups": [], "roleBindings": []}')):
            with self.assertRaises(AssertionError):
                # URL, org, TLS (empty = take VCFA_VERIFY_TLS), import file, browser method, groups only, no filter, dry run
                self.run_main([], ["https://vcfa.example", "my-org", "", "", "1", "", "", ""])
        self.assertTrue(L.s.verify)
        L.s.verify = False

    def test_browser_token_flag_prompts_when_token_missing(self):
        with mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""), mock.patch.dict("os.environ", {}, clear=False):
            import os
            os.environ.pop("VCFA_BROWSER_TOKEN", None)
            bl, ga = self.run_main(["--org", "my-org", "--browser-token", "--login-only"],
                                   ["", "", "", ""], tty=True, secret="pasted" * 5)
        self.assertEqual(bl.call_args.kwargs["text"], "pasted" * 5)

    def test_api_token_flag_uses_the_token_exchange(self):
        with mock.patch.dict("os.environ", {"VCFA_API_TOKEN": "api-secret", "VCFA_BROWSER_TOKEN": ""}):
            bl, ga = self.run_main(["--org", "my-org", "--api-token", "--login-only"], tty=False)
        self.tl.assert_called_once_with("api-secret", "my-org")
        bl.assert_not_called()

    def test_api_token_flag_prompts_when_token_missing(self):
        with mock.patch.dict("os.environ", {"VCFA_API_TOKEN": "", "VCFA_BROWSER_TOKEN": ""}), \
                mock.patch.object(L, "VCFA_API_TOKEN", ""):
            self.run_main(["--org", "my-org", "--api-token", "--login-only"], ["", "", ""], tty=True, secret="pasted-api")
        self.tl.assert_called_once_with("pasted-api", "my-org")

    def test_wizard_offers_only_the_two_token_methods(self):
        self.assertEqual([m for m, _ in L.AUTH_METHODS], ["browser", "api"])
        with mock.patch.dict("os.environ", {"VCFA_API_TOKEN": "", "VCFA_BROWSER_TOKEN": ""}), \
                mock.patch.object(L, "VCFA_API_TOKEN", ""):
            bl, ga = self.run_main([], ["https://vcfa.example", "my-org", "", "", "2", "1", "", "1"], secret="a" * 12)
        self.tl.assert_called_once_with("a" * 12, "my-org")
        bl.assert_not_called()

    def test_both_token_flags_are_refused(self):
        with self.assertRaises(SystemExit):
            self.run_main(["--org", "my-org", "--browser-token", "--api-token"], tty=False)

    def test_no_login_method_stops_with_a_clear_message(self):
        with mock.patch.dict("os.environ", {"VCFA_API_TOKEN": "", "VCFA_BROWSER_TOKEN": ""}), \
                mock.patch.object(L, "VCFA_API_TOKEN", ""), mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""), \
                self.assertRaises(SystemExit) as cm:
            self.run_main(["--org", "my-org", "--login-only"], tty=False)
        self.assertIn("no login method", str(cm.exception))

    def test_removed_options_are_rejected(self):
        for flag in (["--provider"], ["--bearer-file", "x.txt"]):
            with self.assertRaises(SystemExit):
                self.run_main(["--org", "my-org", *flag], tty=False)

    def test_apply_needs_typed_yes(self):
        with mock.patch.object(L, "VCFA_BROWSER_TOKEN", ""), self.assertRaises(SystemExit):
            # action 3 = apply, then answer "no" to the confirmation
            self.run_main([], ["https://vcfa.example", "my-org", "", "", "1", "1", "", "3", "no"])


IMP = {
    "users": [{"username": "ann@corp.local", "providerType": "OAUTH"}, {"username": "bob@corp.local", "providerType": "OAUTH"}],
    "groups": [{"name": "Infra@corp.local", "providerType": "OAUTH", "members": ["ann@corp.local"]}],
    "roleBindings": [
        {"principalType": "user", "principal": "ann@corp.local", "scope": "organization", "role": "Organization Member"},
        {"principalType": "user", "principal": "ann@corp.local", "scope": "organization", "role": "Service Broker User"},
        {"principalType": "user", "principal": "ann@corp.local", "scope": "project:P1", "role": "Project Administrator"},
        {"principalType": "group", "principal": "Infra@corp.local", "scope": "organization", "role": "Assembler Administrator"},
    ],
}
ROLES = [{"name": "Organization Member", "id": "r1"}, {"name": "Service Broker User", "id": "r2"},
         {"name": "Assembler Administrator", "id": "r3"}]


class RoleParity(unittest.TestCase):
    def test_roles_are_carried_and_project_bindings_are_reported(self):
        plan = L.build_plan(IMP, ROLES, [], [], {})
        ann = next(c for c in plan["creates"] if c["body"].get("username") == "ann@corp.local")
        self.assertEqual({r["name"] for r in ann["body"]["roleEntityRefs"]}, {"Organization Member", "Service Broker User"})
        self.assertEqual(plan["projectBindingsNotHandled"], 1)
        self.assertEqual(plan["projectBindings"]["project:P1"][0]["role"], "Project Administrator")
        self.assertEqual(L.blocked_by_missing_roles(plan), {})

    def test_missing_vcfa_role_blocks_the_affected_objects(self):
        plan = L.build_plan(IMP, [r for r in ROLES if r["name"] != "Service Broker User"], [], [], {})
        self.assertEqual(L.blocked_by_missing_roles(plan), {"ann@corp.local": ["Service Broker User"]})

    def test_apply_refuses_when_roles_missing(self):
        roles = [r for r in ROLES if r["name"] != "Service Broker User"]
        with mock.patch("sys.stdin.isatty", return_value=False), mock.patch("sys.argv", ["x", "--org", "my-org", "--browser-token", "--users", "--apply"]),                 mock.patch.object(L, "VCFA_BROWSER_TOKEN", "tok" * 10),                 mock.patch.object(L, "bearer_login", return_value=({}, SESSION)),                 mock.patch.object(L, "get_all", side_effect=[roles, [], []]),                 mock.patch.object(L, "post") as post,                 mock.patch("builtins.open", mock.mock_open(read_data=__import__("json").dumps(IMP))),                 self.assertRaises(SystemExit) as cm:
            L.main()
        self.assertIn("not applying", str(cm.exception))
        post.assert_not_called()

    def test_verify_reports_missing_roles_and_objects(self):
        plan = L.build_plan(IMP, ROLES, [], [], {})
        vcfa_users = [{"username": "ann@corp.local", "roleEntityRefs": [{"name": "Organization Member"}]}]  # lacks SB User
        with mock.patch.object(L, "get_all", side_effect=[vcfa_users, []]):
            bad = L.verify_roles(plan, {})
        problems = {b["name"]: b["problem"] for b in bad}
        self.assertEqual(problems["ann@corp.local"], "missing roles: service broker user")
        self.assertEqual(problems["infra@corp.local"], "not found in VCFA")

    def test_verify_clean_when_roles_match(self):
        plan = L.build_plan(IMP, ROLES, [], [], {})
        users = [{"username": "ann@corp.local", "roleEntityRefs": [{"name": "Organization Member"}, {"name": "Service Broker User"}]},
                 {"username": "bob@corp.local", "roleEntityRefs": []}]
        groups = [{"name": "Infra@corp.local", "roleEntityRefs": [{"name": "Assembler Administrator"}]}]
        with mock.patch.object(L, "get_all", side_effect=[users, groups]):
            self.assertEqual(L.verify_roles(plan, {}), [])


class Selection(unittest.TestCase):
    """Default is groups only; users only with --users or when a user is named in --only."""
    def run_dry(self, argv):
        written = {}
        real_open = open

        def fake_open(path, mode="r", *a, **k):
            if "w" in mode:
                import io
                buf = io.StringIO()
                buf.close = lambda: written.__setitem__(path, buf.getvalue())
                return buf
            return mock.mock_open(read_data=__import__("json").dumps(IMP))()
        with mock.patch("sys.stdin.isatty", return_value=False), mock.patch("sys.argv", ["x", "--org", "my-org", "--browser-token", *argv]),                 mock.patch.object(L, "VCFA_BROWSER_TOKEN", "tok" * 10),                 mock.patch.object(L, "bearer_login", return_value=({}, SESSION)),                 mock.patch.object(L, "get_all", side_effect=[ROLES, [], []]),                 mock.patch("builtins.open", fake_open):
            L.main()
        return __import__("json").loads(written[L.PLAN_FILE])

    @staticmethod
    def names(plan):
        return sorted((c["type"], c["body"].get("username") or c["body"]["name"]) for c in plan["creates"])

    def test_default_is_groups_plus_users_whose_roles_are_not_inherited(self):
        # ann has direct roles the group does not give her; bob has no roles at all
        self.assertEqual(self.names(self.run_dry([])), [("group", "Infra@corp.local"), ("user", "ann@corp.local")])

    def test_groups_only_flag(self):
        self.assertEqual(self.names(self.run_dry(["--groups-only"])), [("group", "Infra@corp.local")])

    def test_users_flag_loads_all_users(self):
        self.assertEqual([t for t, _ in self.names(self.run_dry(["--users"]))], ["group", "user", "user"])

    def test_users_and_groups_only_conflict(self):
        with self.assertRaises(SystemExit):
            self.run_dry(["--users", "--groups-only"])

    def test_only_a_group_loads_just_that_group(self):
        self.assertEqual(self.names(self.run_dry(["--only", "Infra@corp.local"])), [("group", "Infra@corp.local")])

    def test_only_a_user_loads_just_that_user(self):
        self.assertEqual(self.names(self.run_dry(["--only", "ann@corp.local"])), [("user", "ann@corp.local")])



class DirectUsers(unittest.TestCase):
    """Which users still need loading once the groups are there."""
    @staticmethod
    def imp(users, groups, bindings):
        return {"users": [{"username": u, "providerType": p} for u, p in users], "groups": groups, "roleBindings": bindings}

    @staticmethod
    def b(kind, who, role, scope="organization"):
        return {"principalType": kind, "principal": who, "scope": scope, "role": role}

    def test_roles_all_inherited_from_group_means_not_loaded(self):
        imp = self.imp([("a@x", "OAUTH")], [{"name": "G", "members": ["a@x"]}],
                       [self.b("group", "G", "Assembler Administrator"), self.b("user", "a@x", "Assembler Admin")])
        self.assertEqual(L.direct_users(imp), {})  # loose name match counts as inherited

    def test_extra_role_beyond_the_group_is_loaded(self):
        imp = self.imp([("a@x", "OAUTH")], [{"name": "G", "members": ["a@x"]}],
                       [self.b("group", "G", "Organization Member"), self.b("user", "a@x", "Organization Member"),
                        self.b("user", "a@x", "Service Broker User")])
        self.assertEqual(L.direct_users(imp), {"a@x": ["Service Broker User"]})

    def test_user_in_no_group_with_roles_is_loaded(self):
        imp = self.imp([("free@x", "OAUTH")], [], [self.b("user", "free@x", "Organization Owner")])
        self.assertEqual(L.direct_users(imp), {"free@x": ["Organization Owner"]})

    def test_user_with_no_roles_is_not_loaded(self):
        self.assertEqual(L.direct_users(self.imp([("n@x", "OAUTH")], [], [])), {})

    def test_project_bindings_do_not_count(self):
        imp = self.imp([("p@x", "OAUTH")], [], [self.b("user", "p@x", "Project Administrator", "project:P1")])
        self.assertEqual(L.direct_users(imp), {})

    def test_group_roles_only_count_for_groups_the_user_is_in(self):
        imp = self.imp([("a@x", "OAUTH")], [{"name": "G", "members": ["someone@x"]}],
                       [self.b("group", "G", "Organization Member"), self.b("user", "a@x", "Organization Member")])
        self.assertEqual(L.direct_users(imp), {"a@x": ["Organization Member"]})

    def test_local_users_with_roles_are_listed_not_created(self):
        imp = self.imp([("vradmin", "LOCAL")], [], [self.b("user", "vradmin", "Organization Owner")])
        plan = L.build_plan(imp, ROLES + [{"name": "Organization Owner", "id": "r9"}], [], [], {})
        self.assertEqual(plan["localUsersWithRoles"], [{"name": "vradmin", "roles": ["Organization Owner"]}])
        self.assertEqual(plan["creates"], [])


class RoleNames(unittest.TestCase):
    def test_admin_and_administrator_match(self):
        self.assertEqual(L.norm_role("Assembler Admin"), L.norm_role("Assembler Administrator"))

    def test_uses_vcfa_spelling_and_reports_mapping(self):
        imp = {"users": [], "groups": [{"name": "G", "providerType": "OAUTH"}], "roleBindings": [
            {"principalType": "group", "principal": "G", "scope": "organization", "role": "Assembler Admin"},
            {"principalType": "group", "principal": "G", "scope": "organization", "role": "Org Owner"}]}
        plan = L.build_plan(imp, [{"name": "Assembler Administrator", "id": "x"}], [], [], {})
        self.assertEqual(plan["creates"][0]["body"]["roleEntityRefs"], [{"name": "Assembler Administrator", "id": "x"}])
        self.assertEqual(plan["roleMapping"], {"Assembler Admin": "Assembler Administrator", "Org Owner": None})
        self.assertEqual(L.blocked_by_missing_roles(plan), {"g": ["Org Owner"]})


class HostInput(unittest.TestCase):
    def test_normalize_variants(self):
        n = L.normalize_host
        self.assertEqual(n("dev.vra.local"), "https://dev.vra.local")
        self.assertEqual(n("  Dev.VRA.local  "), "https://dev.vra.local")
        self.assertEqual(n("https://dev.vra.local/"), "https://dev.vra.local")
        self.assertEqual(n("https://dev.vra.local/csp/gateway?x=1"), "https://dev.vra.local")
        self.assertEqual(n("http://dev.vra.local"), "http://dev.vra.local")
        self.assertEqual(n("dev.vra.local:8443/"), "https://dev.vra.local:8443")
        self.assertEqual(n("HTTPS://dev.vra.local"), "https://dev.vra.local")

    def test_normalize_rejects_bad_input(self):
        for bad in ("", "   ", "dev vra.local", "ftp://dev.vra.local", "https://", "user:pw@dev.vra.local",
                    "dev.vra.local:notaport"):
            with self.assertRaises(ValueError, msg=bad):
                L.normalize_host(bad)

    def test_prompt_adds_https_and_reasks_on_bad_input(self):
        with mock.patch("sys.stdin.isatty", return_value=True), \
                mock.patch("builtins.input", side_effect=["", "bad host", "dev.vra.local"]):
            self.assertEqual(L.ask_host("host", "", example="dev.vra.local"), "https://dev.vra.local")

    def test_default_is_normalized_without_terminal(self):
        with mock.patch("sys.stdin.isatty", return_value=False):
            self.assertEqual(L.ask_host("host", "https://x.local/"), "https://x.local")
            with self.assertRaises(SystemExit):
                L.ask_host("host", "")


class BearerText(unittest.TestCase):
    """The token may arrive raw, quoted, with a Bearer prefix, or inside a whole copied request."""
    TK = "abcdefghijklmnopqrstuvwxyz0123"

    def login_with(self, text):
        resp = mock.Mock(status_code=200)
        resp.json.return_value = {"org": {"name": "o", "id": "urn:x:1"}}
        with mock.patch.object(L.s, "get", return_value=resp) as g:
            L.bearer_login(None, "o", text=text)
        return g.call_args.kwargs["headers"]["Authorization"]

    def test_accepted_forms(self):
        tk = self.TK
        fetch = ('fetch("https://v/x", {\n  "headers": {\n    "authorization": "Bearer %s",\n'
                 '    "accept": "a"\n  }\n});' % tk)
        curl = "curl 'https://v/x' \\\n  -H 'authorization: Bearer %s' \\\n  --compressed" % tk
        ps = 'Invoke-WebRequest -Headers @{\n"authorization"="Bearer %s"\n"accept"="a"}' % tk
        for text in (tk, "  %s\r\n" % tk, "Bearer " + tk, "bearer   " + tk, '"%s"' % tk, "'%s'" % tk,
                     fetch, curl, ps):
            self.assertEqual(self.login_with(text), "Bearer " + tk, text[:30])

    def test_pasted_text_without_a_token_is_refused_clearly(self):
        with self.assertRaises(SystemExit) as cm:
            L.bearer_login(None, "o", text='fetch("https://v/x", {\n  "method": "GET"\n});')
        self.assertIn("not a token", str(cm.exception))
        with self.assertRaises(SystemExit):
            L.bearer_login(None, "o", text="one two three four five six seven")


class LoadReport(unittest.TestCase):
    """The data behind vcfa-load-report.html, for each way a run can end."""
    def run_report(self, argv, roles=None, post_status=201, imp=None):
        import json as _json
        captured = {}
        roles = ROLES if roles is None else roles
        imp = IMP if imp is None else imp

        def fake_open(path, mode="r", *a, **k):
            if "w" in mode:
                import io
                buf = io.StringIO()
                buf.close = lambda: None
                return buf
            return mock.mock_open(read_data=_json.dumps(imp))()

        def fake_report(path, data):
            captured["data"] = data
            return True
        created = []
        with mock.patch("sys.stdin.isatty", return_value=False), \
                mock.patch("sys.argv", ["x", "--org", "my-org", "--browser-token", *argv]), \
                mock.patch.object(L, "VCFA_BROWSER_TOKEN", "tok" * 10), \
                mock.patch.object(L, "bearer_login", return_value=({}, SESSION)), \
                mock.patch.object(L, "get_all", side_effect=lambda path, headers, *a, **k: {
                    "/cloudapi/1.0.0/roles": roles,
                    "/cloudapi/1.0.0/users": [c["body"] for c in created if c["type"] == "user"],
                    "/cloudapi/1.0.0/groups": [c["body"] for c in created if c["type"] == "group"]}[path]), \
                mock.patch.object(L, "post", side_effect=lambda path, headers, body: (
                    created.append({"type": "user" if path.endswith("users") else "group", "body": body}) or (post_status, {}))), \
                mock.patch.object(L, "write_html_report", side_effect=fake_report), \
                mock.patch("builtins.open", fake_open):
            try:
                L.main()
                error = None
            except SystemExit as e:
                error = str(e)
        return captured.get("data"), error

    def test_dry_run_report(self):
        d, err = self.run_report([])
        self.assertIsNone(err)
        self.assertEqual((d["kind"], d["mode"], d["userMode"]), ("load", "dry-run", "free"))
        self.assertEqual((d["counts"]["groups"], d["counts"]["users"]), (1, 1))
        self.assertEqual(d["groups"][0]["result"], "planned")
        self.assertEqual(d["groups"][0]["roles"], ["Assembler Administrator"])
        self.assertEqual(d["users"][0]["name"], "ann@corp.local")
        self.assertEqual(d["users"][0]["notInherited"], ["Organization Member", "Service Broker User"])
        self.assertEqual(d["notLoaded"], [{"name": "bob@corp.local", "reason": "no roles of their own"}])
        self.assertEqual(d["projects"], [{"project": "P1", "bindings": 1}])
        self.assertIsNone(d["roleCheck"])
        self.assertEqual(d["vcfa"]["roles"], 3)

    def test_not_loaded_reasons(self):
        d, _ = self.run_report(["--groups-only"])
        self.assertEqual({n["reason"] for n in d["notLoaded"]}, {"groups-only mode"})
        d, _ = self.run_report(["--only", "Infra@corp.local"])
        self.assertEqual({n["reason"] for n in d["notLoaded"]}, {"not selected with -Only"})

    def test_applied_report(self):
        d, err = self.run_report(["--apply"])
        self.assertIsNone(err)
        self.assertEqual((d["mode"], d["counts"]["created"]), ("applied", 2))
        self.assertEqual(d["groups"][0]["result"], "created")
        self.assertEqual(d["roleCheck"]["total"], 2)
        self.assertEqual(d["roleCheck"]["matched"], 2)

    def test_failed_create_is_reported(self):
        d, _ = self.run_report(["--apply"], post_status=403)
        self.assertEqual(d["counts"]["failed"], 2)
        self.assertEqual(d["groups"][0]["result"], "failed (HTTP 403)")
        self.assertTrue(d["failures"][0]["detail"].startswith("HTTP 403"))

    def test_blocked_apply_still_writes_a_report(self):
        d, err = self.run_report(["--apply"], roles=[r for r in ROLES if r["name"] != "Service Broker User"])
        self.assertIn("not applying", err)
        self.assertEqual(d["mode"], "blocked")
        self.assertEqual(d["blocked"], [{"name": "ann@corp.local", "roles": ["Service Broker User"]}])
        self.assertEqual(d["groups"][0]["result"], "not applied")
        self.assertEqual(d["missingRoles"], [{"role": "Service Broker User", "count": 1}])
        self.assertIsNone([r for r in d["roleMapping"] if r["source"] == "Service Broker User"][0]["target"])

    def test_local_user_is_listed_and_skipped(self):
        imp = {"users": [{"username": "vradmin", "providerType": "LOCAL"}], "groups": [],
               "roleBindings": [{"principalType": "user", "principal": "vradmin", "scope": "organization", "role": "Organization Member"}]}
        d, _ = self.run_report(["--users"], imp=imp)
        self.assertEqual(d["localUsers"], [{"name": "vradmin", "roles": ["Organization Member"]}])
        self.assertEqual(d["skipped"][0]["reason"], "local user: needs a password, create manually")

if __name__ == "__main__":
    unittest.main()

import copy
import json
import os
import tempfile
import unittest
from unittest import mock

import export_vra_identity as m

USER = {
    "orgId": "org1",
    "user": {"username": "aaron", "firstName": "Aaron", "lastName": "L", "domain": "corp.example.com",
             "email": "aaron@corp.example.com", "userId": "u1"},
    "organizationRoles": [{"name": "org_member"}],
    "serviceRoles": [{"serviceRoles": [{"name": "catalog:user"}, {"name": "saltstack:admin"}]}],
}
SYS_USER = {
    "user": {"username": "admin", "domain": "System Domain", "email": "a@example.com", "userId": "u2"},
    "organizationRoles": [{"name": "org_owner"}],
    "serviceRoles": [{"serviceRoles": [{"name": "CodeStream:administrator"}, {"name": "weird:role"}]}],
}
GROUP = {
    "id": "g1", "displayName": "Infra@corp.example.com", "domain": "corp.example.com", "groupType": "AD_GROUP",
    "organizationRoles": [{"name": "org_member"}],
    "serviceRoles": [{"serviceRoleNames": ["catalog:admin", "orchestration:viewer"]}],
}
PROJECT = {"name": "P1", "administrators": [{"email": "aaron@corp.example.com", "type": "user"}],
           "members": [{"email": "Infra@corp.example.com", "type": "group"}]}


class Parsing(unittest.TestCase):
    def test_items_of_shapes(self):
        self.assertEqual(m.items_of([1]), [1])
        self.assertEqual(m.items_of({"results": [1]}), [1])
        self.assertEqual(m.items_of({"content": [2]}), [2])
        self.assertEqual(m.items_of({"items": None}), [])

    def test_domain_and_name_nested_user(self):
        self.assertEqual(m.principal_domain(USER), "corp.example.com")
        self.assertEqual(m.principal_domain(SYS_USER), "System Domain")
        self.assertEqual(m.principal_name(USER), "aaron@corp.example.com")
        self.assertEqual(m.principal_name(GROUP), "Infra@corp.example.com")

    def test_domain_falls_back_to_at_suffix(self):
        self.assertEqual(m.principal_domain({"username": "x@corp.local"}), "corp.local")

    def test_role_names_user_and_group_shapes(self):
        self.assertEqual(m.role_names(USER), ["org_member", "catalog:user", "saltstack:admin"])
        self.assertEqual(m.role_names(GROUP), ["org_member", "catalog:admin", "orchestration:viewer"])

    def test_in_scope(self):
        with mock.patch.object(m, "INCLUDE_DOMAINS", ["corp.example.com"]):
            self.assertTrue(m.in_scope(USER))
            self.assertFalse(m.in_scope(SYS_USER))
        with mock.patch.object(m, "INCLUDE_DOMAINS", []):
            self.assertTrue(m.in_scope(SYS_USER))

    def test_summarize_user_flat_no_ignored_roles_no_nulls(self):
        s = m.summarize(USER)
        self.assertEqual(s["organizationRoles"], ["org_member"])
        self.assertEqual(s["serviceRoles"], ["catalog:user"])  # saltstack removed
        self.assertEqual(s["id"], "u1")
        self.assertNotIn("name", s)       # duplicate of email/username
        self.assertNotIn("groupType", s)  # only meaningful for groups
        self.assertFalse(any(v is None for v in s.values()))

    def test_summarize_group_has_no_user_fields(self):
        s = m.summarize(GROUP)
        self.assertEqual(s["serviceRoles"], ["catalog:admin", "orchestration:viewer"])
        self.assertEqual(s["groupType"], "AD_GROUP")
        for k in ("email", "firstName", "lastName", "username"):
            self.assertNotIn(k, s)

    def test_summarize_filters_codestream(self):
        self.assertEqual(m.summarize(SYS_USER)["serviceRoles"], ["weird:role"])

    def test_trim_user_and_project(self):
        raw = {"orgId": "o", "user": {"username": "a", "acct": "a", "idpId": "i", "userId": "i", "accessible": False,
                                     "userProfile": None, "domain": "d", "email": "e"},
               "organizationRoles": [], "serviceRoles": []}
        t = m.trim_user(raw)
        self.assertEqual(set(t["user"]), {"username", "domain", "email", "userId"})
        self.assertNotIn("orgId", t)
        t = m.trim_project({"id": "1", "name": "P", "zones": [{}], "constraints": {}, "_links": {}, "orgId": "o",
                            "administrators": [{"email": "x"}]})
        self.assertEqual(set(t), {"id", "name", "administrators"})


class Import(unittest.TestCase):
    def setUp(self):
        self.imp = m.build_import([USER, SYS_USER], [GROUP], [PROJECT])
        self.bindings = {(b["principal"], b["scope"], b["role"]) for b in self.imp["roleBindings"]}

    def test_mapped_roles(self):
        self.assertIn(("aaron@corp.example.com", "organization", "Organization Member"), self.bindings)
        self.assertIn(("aaron@corp.example.com", "organization", "Service Broker User"), self.bindings)
        self.assertIn(("Infra@corp.example.com", "organization", "Service Broker Administrator"), self.bindings)
        self.assertIn(("admin", "organization", "Organization Owner"), self.bindings)

    def test_ignored_roles_produce_no_binding_or_warning(self):
        roles = {b[2] for b in self.bindings}
        self.assertFalse(any("salt" in r.lower() or "codestream" in r.lower() for r in roles))
        self.assertFalse(any("saltstack" in w or "CodeStream" in w for w in self.imp["warnings"]))

    def test_import_shape_matches_vcfa_fields(self):
        self.assertEqual(set(self.imp), {"users", "groups", "roleBindings", "warnings"})
        u = next(x for x in self.imp["users"] if x["username"] == "aaron@corp.example.com")
        self.assertEqual((u["providerType"], u["domain"], u["fullName"]), ("OAUTH", "corp.example.com", "Aaron L"))
        self.assertEqual(next(x for x in self.imp["users"] if x["username"] == "admin")["providerType"], "LOCAL")
        self.assertEqual(self.imp["groups"][0], {"name": "Infra@corp.example.com", "domain": "corp.example.com", "providerType": "OAUTH", "members": []})

    def test_shared_email_does_not_merge_roles(self):
        def mk(name, role):
            return {"user": {"username": name, "domain": "corp.example.com", "email": "shared@x.com", "userId": name},
                    "organizationRoles": [{"name": role}], "serviceRoles": []}
        imp = m.build_import([mk("u1", "org_owner"), mk("u2", "org_member")], [], [])
        got = {(b["principal"], b["role"]) for b in imp["roleBindings"]}
        self.assertEqual(got, {("u1@corp.example.com", "Organization Owner"), ("u2@corp.example.com", "Organization Member")})

    def test_group_members_in_import_and_member_user_added(self):
        grp = dict(GROUP, members=[{"userId": "m1", "username": "fin01", "domain": "corp.example.com", "email": "f@x.com"}])
        imp = m.build_import([USER], [grp], [])
        self.assertEqual(imp["groups"][0]["members"], ["fin01@corp.example.com"])
        self.assertIn("fin01@corp.example.com", {u["username"] for u in imp["users"]})
        self.assertEqual(m.summarize(grp)["members"], ["fin01@corp.example.com"])

    def test_empty_warnings_omitted(self):
        self.assertNotIn("warnings", m.build_import([USER], [GROUP], [PROJECT]))

    def test_unmapped_role_warns(self):
        self.assertEqual(len(self.imp["warnings"]), 1)
        self.assertIn("weird:role", self.imp["warnings"][0])

    def test_project_roles(self):
        self.assertIn(("aaron@corp.example.com", "project:P1", "Project Administrator"), self.bindings)
        self.assertIn(("Infra@corp.example.com", "project:P1", "Project User"), self.bindings)
        grp = [b for b in self.imp["roleBindings"] if b["scope"] == "project:P1" and b["principal"].startswith("Infra")]
        self.assertEqual(grp[0]["principalType"], "group")


class Pagination(unittest.TestCase):
    @staticmethod
    def _resp(body, status=200):
        r = mock.Mock(status_code=status)
        r.json.return_value = body
        return r

    def test_stops_when_paging_ignored(self):
        same = self._resp({"results": [{"id": i} for i in range(100)]})
        with mock.patch.object(m, "get_json", return_value=same) as g:
            items, status = m.get_all("/x", "tok", page_size=100)
        self.assertEqual((len(items), status), (100, 200))
        self.assertEqual(g.call_count, 2)

    def test_dedupes_when_api_repeats_full_list(self):
        full = [{"id": i} for i in range(150)]
        with mock.patch.object(m, "get_json", side_effect=[self._resp({"results": full})] * 5):
            items, _ = m.get_all("/x", "tok", page_size=100)
        self.assertEqual(len(items), 150)

    def test_collects_pages_until_short_page(self):
        pages = [self._resp({"results": [{"id": 1}, {"id": 2}]}), self._resp({"results": [{"id": 3}]})]
        with mock.patch.object(m, "get_json", side_effect=pages):
            items, _ = m.get_all("/x", "tok", page_size=2)
        self.assertEqual([i["id"] for i in items], [1, 2, 3])

    def test_first_working_skips_404(self):
        def fake(path, token, page_size=100, max_pages=50):
            return ([], 404) if "v2" in path else ([{"id": 1}], 200)
        with mock.patch.object(m, "get_all", side_effect=fake):
            path, items = m.first_working(["/v2/{org}", "/v1/{org}"], "o", "tok")
        self.assertEqual((path, len(items)), ("/v1/o", 1))

    def test_org_id_from_reflinks(self):
        r = self._resp({"refLinks": ["/csp/gateway/am/api/orgs/abc-123"], "items": None})
        with mock.patch.object(m, "get_json", return_value=r):
            self.assertEqual(m.get_org_id("tok"), "abc-123")


class Output(unittest.TestCase):
    def test_main_writes_four_files_in_cwd(self):
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(m, "OUTPUT_DIR", d), \
                mock.patch.object(m, "USERNAME", "u"), \
                mock.patch.object(m, "PASSWORD", "p"), \
                mock.patch.object(m, "login", return_value=("c", "i")), \
                mock.patch.object(m, "get_org_id", return_value="org1"), \
                mock.patch.object(m, "INCLUDE_DOMAINS", []), \
                mock.patch.object(m, "first_working", side_effect=[("/u", copy.deepcopy([USER, SYS_USER])), ("/g", copy.deepcopy([GROUP]))]), \
                mock.patch.object(m, "get_all", side_effect=[([{"userId": "m1", "username": "fin01", "domain": "corp.example.com"}], 200), ([PROJECT], 200)]), \
                mock.patch("sys.argv", ["x", "all"]):
            m.main()
            self.assertEqual(sorted(os.listdir(d)),
                             ["groups.json", "users.json", "vcfa-import.json", "vra-export.json"])
            with open(os.path.join(d, "users.json")) as f:
                users = json.load(f)
            self.assertEqual({u["domain"] for u in users}, {"corp.example.com", "System Domain"})
            with open(os.path.join(d, "vra-export.json")) as f:
                raw = json.load(f)
            self.assertNotIn("orgId", raw["users"][0])


if __name__ == "__main__":
    unittest.main()

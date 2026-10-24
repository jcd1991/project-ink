"""Negative fixtures ensure the architecture gate rejects boundary violations."""
import unittest
from check_architecture import violations


def fixture(name, dependency=None, kind=None, target=None):
    packages = []
    names = [name] + ([dependency] if dependency in {"ink-engine", "ink-model", "ink-test-support"} else [])
    for item in dict.fromkeys(names):
        packages.append({"id": item, "name": item, "dependencies": []})
    if dependency:
        packages[0]["dependencies"] = [{
            "name": dependency, "rename": "innocent_alias", "kind": kind,
            "target": target,
        }]
    return {"workspace_members": [p["id"] for p in packages], "packages": packages}


class Boundaries(unittest.TestCase):
    def test_valid_foundation_edge(self):
        self.assertEqual(violations(fixture("ink-raster", "ink-model")), [])

    def test_upward_target_specific_and_build_edges(self):
        for kind in (None, "build"):
            with self.subTest(kind=kind):
                self.assertTrue(violations(fixture("ink-model", "ink-engine", kind, 'cfg(windows)')))

    def test_renaming_cannot_hide_frb_or_ui(self):
        for dep in ("flutter_rust_bridge", "egui", "winit"):
            self.assertTrue(violations(fixture("ink-model", dep)))

    def test_test_support_is_dev_only(self):
        self.assertTrue(violations(fixture("ink-engine", "ink-test-support")))
        self.assertEqual(violations(fixture("ink-engine", "ink-test-support", "dev")), [])

    def test_platform_handles_are_isolated(self):
        self.assertTrue(violations(fixture("ink-engine", "metal")))
        self.assertEqual(violations(fixture("ink-live-render", "metal")), [])

    def test_unknown_crates_fail_closed(self):
        self.assertTrue(violations(fixture("ink-new")))

    def test_parser_is_standalone_even_for_tests(self):
        self.assertTrue(violations(fixture("photocraft-psd", "ink-model", "dev")))


if __name__ == "__main__":
    unittest.main()

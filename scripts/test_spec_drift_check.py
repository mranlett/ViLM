#!/usr/bin/env python3
"""Tests for spec_drift_check.

The module carries an embedded `--selftest` so the check can be proven runnable
offline on any machine without a test runner. This file is the same guarantee
expressed where the repo's coverage gate can see it, plus the unit-level
assertions that pin the three measurement errors the check was written to avoid:

  1. test targets are indexed, so a cited test name is not read as missing;
  2. a dotted token needs BOTH halves, so `Performer.scenes` cannot "resolve"
     off `Performer` alone;
  3. built-ness is measured against SOURCE, so a symbol living only in a test is
     evidence a thing is NOT built.

Run:  python3 -m unittest discover -s scripts -p 'test_*.py'
  or: task spec-drift:selftest
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import spec_drift_check as sdc  # noqa: E402


SOURCE = """
struct AlphaWidget {}
struct Performer {}
struct GammaThing { func method() {} }
func registerMigration(_ v: String) {}
let _ = registerMigration("v9")
let _ = registerMigration("v12")
"""

TESTS = """
final class StudioPolicyParityTests {
    func testAThingHolds() {}
}
let orphan_column = "orphan_column"
"""


def spec(status: str, body: str) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "s.md"
        p.write_text(f'---\nspec: "S"\nstatus: {status}\n---\n{body}\n')
        return sdc.parse_spec(p)


class ResolutionTests(unittest.TestCase):
    def test_plain_symbol_resolves(self):
        self.assertTrue(sdc.resolves("AlphaWidget", SOURCE))

    def test_absent_symbol_does_not_resolve(self):
        self.assertFalse(sdc.resolves("NoSuchSymbol", SOURCE))

    def test_dotted_token_resolves_when_both_halves_exist(self):
        # The FileNameParser.parse case: base and member both real.
        self.assertTrue(sdc.resolves("GammaThing.method", SOURCE))

    def test_dotted_token_does_not_resolve_off_base_alone(self):
        # The Performer.scenes case. Measuring an approximation of the thing
        # under test is MISTAKES pattern 9; this assertion pins it shut.
        self.assertFalse(sdc.resolves("Performer.scenes", SOURCE))

    def test_test_name_classification(self):
        self.assertTrue(sdc.is_test_name("testAThingHolds"))
        self.assertTrue(sdc.is_test_name("StudioPolicyParityTests"))
        self.assertFalse(sdc.is_test_name("breast_type"))


class RuleTests(unittest.TestCase):
    def test_r1_fails_only_on_approved_over_awaiting_approval(self):
        dirty = spec("Approved", "> Status: In Review — awaiting Human Operator approval.")
        fails, warns = sdc.rule_status_contradiction(dirty)
        self.assertTrue(fails, "Art. II pairing must fail")
        self.assertFalse(warns)

    def test_r1_warns_on_stale_banner(self):
        stale = spec("Implemented", "> Status: In Review — awaiting Human Operator approval.")
        fails, warns = sdc.rule_status_contradiction(stale)
        self.assertFalse(fails, "a stale banner must not fail the gate")
        self.assertTrue(warns)

    def test_r1_ignores_a_quoted_past_status(self):
        # The correction note in performer-detail.md quotes the banner it
        # replaced. R1 flagged its own audit trail until this was fixed.
        corrected = spec(
            "Approved",
            '> ✅ APPROVED by the Human Operator.\n'
            '> ⚠️ Banner corrected 2026-09-06. It had read "In Review — awaiting '
            'Human Operator approval" while the Status property said Approved.',
        )
        fails, warns = sdc.rule_status_contradiction(corrected)
        self.assertEqual(([], []), (fails, warns),
                         "a quoted past status must not read as a live claim")

    def test_r1_still_fires_when_a_live_claim_sits_beside_a_quoted_one(self):
        mixed = spec(
            "Approved",
            '> Status: In Review — awaiting Human Operator approval.\n'
            '> Note: it had read "In Review — awaiting Human Operator approval".',
        )
        fails, _ = sdc.rule_status_contradiction(mixed)
        self.assertTrue(fails, "the unquoted live claim must still fail")

    def test_r1_silent_when_consistent(self):
        clean = spec("Implemented", "Nothing to declare.")
        self.assertEqual(([], []), sdc.rule_status_contradiction(clean))

    def test_r4_fires_when_evidence_is_behind_the_tree(self):
        s = spec("Approved", "Schema and code read at v3 on 2026-01-01.")
        self.assertTrue(sdc.rule_stale_evidence(s, 12))

    def test_r4_silent_when_evidence_is_current(self):
        s = spec("Approved", "Schema and code read at v12 on 2026-01-01.")
        self.assertFalse(sdc.rule_stale_evidence(s, 12))

    def test_r4_ignores_proposed_migration_headings(self):
        # "### v27 — the edge tables" is a proposal, not a staleness claim.
        s = spec("Approved", "### v27 — the edge tables\nSome prose about v28.")
        self.assertFalse(sdc.rule_stale_evidence(s, 47))

    def test_r5_fires_for_a_symbol_that_lives_only_in_tests(self):
        # The performer-detail case: breast_type et al. exist in tests alone.
        s = spec("Approved", "Adds `orphan_column` to the schema.")
        self.assertTrue(sdc.rule_tested_not_built(s, SOURCE, TESTS))

    def test_r5_silent_when_the_symbol_is_in_source(self):
        s = spec("Approved", "Uses `AlphaWidget`.")
        self.assertFalse(sdc.rule_tested_not_built(s, SOURCE, TESTS))

    def test_r3_does_not_count_test_only_symbols_as_built(self):
        body = " ".join(f"`orphan_column`" for _ in range(1)) + " " + " ".join(
            [f"`missingThing{i}`" for i in range(9)]
        )
        s = spec("Approved", body)
        self.assertFalse(
            sdc.rule_resolves_like_built(s, SOURCE, TESTS),
            "test-only presence must not read as built",
        )

    def test_r3_ignores_implemented_specs(self):
        s = spec("Implemented", " ".join(f"`AlphaWidget`" for _ in range(9)))
        self.assertFalse(sdc.rule_resolves_like_built(s, SOURCE, TESTS))


class SchemaTests(unittest.TestCase):
    def test_reads_the_highest_registered_migration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / sdc.MIGRATION_ROOT).mkdir(parents=True)
            (root / sdc.MIGRATION_ROOT / "S.swift").write_text(SOURCE)
            self.assertEqual(12, sdc.current_schema_version(root))


class EmbeddedSelftest(unittest.TestCase):
    def test_embedded_selftest_passes(self):
        self.assertEqual(0, sdc.selftest())


if __name__ == "__main__":
    unittest.main()

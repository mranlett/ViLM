#!/usr/bin/env python3
"""spec_drift_check.py — fail when a recorded status disagrees with the tree.

WHY THIS EXISTS
---------------
On 2026-09-05/06 three separate attempts to pick up work died on the same cause:
every record of what was done disagreed with what had actually been done, and
always in the same direction — claiming more work remained than did.

  * xbrief/pending/ + proposed/ held 24 briefs whose GitHub issues were all
    closed `completed` (#1-#24).
  * Six specs carried `status: Approved` while their code was largely built;
    The Library Graph is at schema v47 against its own "read at v23".
  * delta-refresh.md carries `status: Approved` in frontmatter and
    "Status: In Review — awaiting Human Operator approval" in its body.

Nothing compared the two expressions of that one fact. This is pattern 18 in
MISTAKES ("one fact with two expressions and nothing comparing them") applied to
status fields. This check is the comparison.

DESIGN NOTES, EARNED THE HARD WAY
---------------------------------
The first hand-run of this analysis made two measurement errors, and this file
must not inherit either:

  1. It indexed only LibraryCore/Sources + ViLM, EXCLUDING test targets, so 26
     identifiers in opaque-node-identity.md read as missing when they were test
     names that exist. -> index_code() indexes tests too.
  2. It matched dotted tokens literally, so `FileNameParser.parse` read as
     missing while FileNameParser exists. -> resolves() accepts a dotted token
     only when BOTH halves are present. (The first fix here retried the base
     symbol alone, which made `Performer.scenes` "resolve" off `Performer` —
     an approximation standing in for the thing measured, MISTAKES pattern 9.)
  3. It counted a symbol found anywhere as built. `breast_type`, `cup_size` and
     `eye_color` live ONLY in PerformerDetailTests.swift, so performer-detail.md
     scored 9/9 "reads as built" while none of the three exists in source.
     -> built-ness is measured against SOURCE; a domain identifier present only
     in tests is evidence of the OPPOSITE, and is reported as R5.

Per MISTAKES pattern 29's corollary, a prevention that is code needs its own
gate: `--selftest` runs offline fixtures proving every rule can FAIL and can
pass. A check that has never been observed failing is documentation.

RULES
-----
  R1 status-contradiction  FAIL  frontmatter status vs an explicit body status
  R2 shipped-brief         FAIL  xBRIEF in pending/proposed whose issue is closed
                                 as completed (needs gh; skipped when offline)
  R3 resolves-like-built   WARN  a non-Implemented spec whose cited identifiers
                                 resolve against SOURCE at a built-spec rate
  R4 stale-evidence        FAIL  a spec's "code read at vNN" is behind the tree
  R5 tested-not-built      WARN  a spec cites a domain identifier that exists in
                                 tests but not in source

R1 fails on exactly one pairing: frontmatter Approved over a body still awaiting
approval, which is what sends someone to build an unapproved thing. Every other
contradiction warns — see FAIL_PAIR for why that calibration, not strictness, is
the right call here.

R3 and R5 are heuristics and say so: they warn, never fail. R1/R2/R4 are
objective comparisons of two recorded facts and fail closed.

Usage:
  python3 scripts/spec_drift_check.py            # full run (uses gh if present)
  python3 scripts/spec_drift_check.py --offline  # skip R2
  python3 scripts/spec_drift_check.py --selftest # prove the rules can fail
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SPEC_DIR = "docs/specs"
CODE_ROOTS = ["LibraryCore/Sources", "ViLM"]
TEST_ROOTS = ["LibraryCore/Tests", "ViLMTests"]
MIGRATION_ROOT = "LibraryCore/Sources"

# R3 calibration, set against measured ground truth on 2026-09-06: Implemented
# specs resolved 50-100% and Approved ones 56-100%, so the rate alone cannot
# separate them. These thresholds are deliberately conservative — the rule is
# advisory and a noisy advisory rule gets ignored, which is worse than silence.
R3_MIN_TOKENS = 8
R3_RATE = 0.85

IDENT = re.compile(r"`([A-Za-z_][A-Za-z0-9_.]{3,60})`")
FRONTMATTER = re.compile(r"\A(?:<!--.*?-->\s*)?---\n(.*?)\n---", re.S)

# An explicit status assertion in the prose, as opposed to the frontmatter.
BODY_STATUS = [
    (re.compile(r"status:?\s*in review", re.I), "In Review"),
    (re.compile(r"status returned to in review", re.I), "In Review"),
    (re.compile(r"awaiting\s+human\s+operator\s+approval", re.I), "In Review"),
    (re.compile(r"status moved (?:from \w+ )?to implemented", re.I), "Implemented"),
]

# Only an evidence-style claim about the schema the spec was written against.
# Proposed migrations ("### v27 — the edge tables") are NOT staleness claims.
EVIDENCE_SCHEMA = re.compile(r"(?:schema[^.\n]{0,40})?code read at v(\d+)", re.I)

# A status phrase QUOTED as a past state is not a live claim. Correcting a spec
# in place and saying what it used to say is this project's house style (see
# "What building it corrected" in library-graph.md), and the first version of R1
# flagged its own audit trail: a banner corrected to Approved still tripped the
# rule because the correction note quoted the words it had replaced.
HISTORICAL = re.compile(
    r"had read|previously read|superseded|corrected|no longer says|used to (?:read|say)",
    re.I,
)


def looks_like_code(tok: str) -> bool:
    if tok.endswith(".swift"):
        return True
    if "_" in tok and tok.islower():
        return True
    if re.match(r"^[a-z]+[A-Z]", tok) or re.match(r"^[A-Z][a-z]+[A-Z]", tok):
        return True
    return "." in tok and bool(re.search(r"[a-z][A-Z]|\.[a-z]", tok))


def index_code(root: Path, roots: list[str] | None = None) -> str:
    """Concatenate Swift files under `roots` (default: sources + tests)."""
    chunks = []
    for rel in (roots if roots is not None else CODE_ROOTS + TEST_ROOTS):
        base = root / rel
        if not base.is_dir():
            continue
        for path in base.rglob("*.swift"):
            try:
                chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
            except OSError:
                pass
    return "\n".join(chunks)


def is_test_name(tok: str) -> bool:
    """A cited test identifier legitimately lives in a test target, not source."""
    leaf = tok.split(".")[-1]
    return leaf.startswith("test") or leaf.endswith("Tests") or tok.endswith("Tests")


def resolves(tok: str, code: str) -> bool:
    """Resolve a cited identifier.

    Design note 2 said to retry the base symbol so `FileNameParser.parse` would
    not read as missing. That overcorrected: `Performer.scenes` then "resolved"
    because `Performer` exists, which says nothing about `.scenes` — measuring an
    approximation of the thing under test (MISTAKES pattern 9). A dotted token
    now needs BOTH halves present, which still rescues FileNameParser.parse
    without inventing evidence for a member that does not exist.
    """
    if tok in code:
        return True
    if "." not in tok:
        return False
    base, leaf = tok.split(".")[0].split("(")[0], tok.split(".")[-1].split("(")[0]
    return len(base) > 3 and base in code and len(leaf) > 2 and leaf in code


def parse_spec(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="ignore")
    m = FRONTMATTER.search(text)
    fm = m.group(1) if m else ""

    def field(key: str) -> str:
        hit = re.search(rf"^{key}:\s*\"?(.*?)\"?\s*$", fm, re.M)
        return hit.group(1).strip() if hit else ""

    body = text[m.end():] if m else text
    return {
        "file": path.name,
        "path": path,
        "status": field("status"),
        "spec": field("spec") or path.stem,
        "priority": field("priority"),
        "body": body,
        "text": text,
    }


def current_schema_version(root: Path) -> int | None:
    best = None
    base = root / MIGRATION_ROOT
    if not base.is_dir():
        return None
    pat = re.compile(r"registerMigration\(\s*\"v(\d+)")
    for path in base.rglob("*.swift"):
        try:
            for hit in pat.finditer(path.read_text(encoding="utf-8", errors="ignore")):
                n = int(hit.group(1))
                best = n if best is None or n > best else best
        except OSError:
            pass
    return best


# ---------------------------------------------------------------- rules

# Only ONE contradiction is dangerous enough to fail: frontmatter says Approved
# (Constitution Art. II — "implementation may proceed") while the body says the
# spec is still awaiting that approval. Acting on it means building something
# nobody approved.
#
# Every other pairing warns. That is a calibration decision, not laziness: on the
# real corpus 10 of 12 hits are `Implemented` frontmatter over a stale in-review
# banner, a Notion authoring habit where the body header is not updated when the
# Status property moves. Failing those would leave this gate permanently red,
# and a gate that is always red is a gate nobody reads.
FAIL_PAIR = ("approved", "in review")


def _live_match(pattern: re.Pattern, body: str) -> bool:
    """True when `pattern` matches somewhere that is not a quoted past state."""
    for m in pattern.finditer(body):
        start = body.rfind("\n", 0, m.start()) + 1
        end = body.find("\n", m.end())
        line = body[start:end if end != -1 else len(body)]
        if not HISTORICAL.search(line):
            return True
    return False


def rule_status_contradiction(spec: dict) -> tuple[list[str], list[str]]:
    """Returns (fails, warns)."""
    fm_status = spec["status"].lower()
    if not fm_status:
        return [], []
    for pattern, claimed in BODY_STATUS:
        hit = _live_match(pattern, spec["body"])
        if hit and claimed.lower() != fm_status:
            msg = (f"R1 {spec['file']}: frontmatter says '{spec['status']}' but the "
                   f"body asserts '{claimed}'")
            if (fm_status, claimed.lower()) == FAIL_PAIR:
                return [msg + " — Art. II: approved-to-build, but not yet approved"], []
            return [], [msg + " — stale banner; frontmatter is the later value"]
    return [], []


def rule_stale_evidence(spec: dict, current: int | None) -> list[str]:
    if current is None:
        return []
    out = []
    for hit in EVIDENCE_SCHEMA.finditer(spec["text"]):
        cited = int(hit.group(1))
        if cited < current:
            out.append(
                f"R4 {spec['file']}: evidence cites code read at v{cited}; tree is at "
                f"v{current} ({current - cited} migrations ahead)"
            )
    return out


def spec_tokens(spec: dict) -> set[str]:
    return {t for t in IDENT.findall(spec["text"]) if looks_like_code(t) and len(t) > 4}


def rule_resolves_like_built(spec: dict, src: str, tests: str) -> list[str]:
    if spec["status"].lower() == "implemented":
        return []
    toks = spec_tokens(spec)
    if len(toks) < R3_MIN_TOKENS:
        return []
    # A cited test name legitimately lives in a test target; everything else must
    # be in SOURCE to count as built (design note 3).
    found = sum(1 for t in toks
                if resolves(t, tests if is_test_name(t) else src))
    rate = found / len(toks)
    if rate >= R3_RATE:
        return [f"R3 {spec['file']}: status '{spec['status']}' but {found}/{len(toks)} "
                f"({rate:.0%}) of cited identifiers resolve in source — reads as built"]
    return []


def rule_tested_not_built(spec: dict, src: str, tests: str) -> list[str]:
    """A domain identifier that exists only in tests is not implemented."""
    orphans = [t for t in sorted(spec_tokens(spec))
               if not is_test_name(t) and not resolves(t, src) and resolves(t, tests)]
    if not orphans:
        return []
    shown = ", ".join(orphans[:6]) + (" …" if len(orphans) > 6 else "")
    return [f"R5 {spec['file']}: {len(orphans)} identifier(s) exist in tests but not "
            f"in source — {shown}"]


def rule_shipped_briefs(root: Path) -> tuple[list[str], str | None]:
    """xBRIEFs parked in pending/proposed whose issue is closed as completed."""
    briefs = []
    for folder in ("pending", "proposed"):
        base = root / "xbrief" / folder
        if base.is_dir():
            briefs.extend((folder, p) for p in base.glob("*.xbrief.json"))
    if not briefs:
        return [], None

    helper = root / "scripts" / "gh-personal.sh"
    cmd = [str(helper)] if helper.exists() else ["gh"]
    cmd += ["issue", "list", "--state", "closed", "--limit", "200",
            "--json", "number,title,stateReason"]
    try:
        res = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=60)
        if res.returncode != 0:
            return [], "gh unavailable or unauthenticated"
        issues = json.loads(res.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return [], "gh unavailable"

    def norm(s: str) -> str:
        return re.sub(r"[^a-z0-9]+", "", s.lower())

    done = {
        norm(i["title"]): i
        for i in issues
        if (i.get("stateReason") or "").upper() == "COMPLETED"
    }
    out = []
    for folder, path in sorted(briefs):
        try:
            title = json.loads(path.read_text())["plan"]["title"]
        except (OSError, ValueError, KeyError):
            continue
        hit = done.get(norm(title))
        if hit:
            out.append(
                f"R2 {folder}/{path.name}: issue #{hit['number']} is closed as "
                f"completed, but the brief is still in {folder}/"
            )
    return out, None


# ---------------------------------------------------------------- selftest

SELFTEST_SPEC = """---
spec: "Fixture"
status: Approved
---
# Fixture
> Status: In Review — awaiting Human Operator approval.
Schema and code read at v3 on 2026-01-01.
Uses `AlphaWidget`, `betaThing`, `GammaThing.method`, `delta_table`,
`EpsilonThing`, `zetaThing`, `EtaThing`, `thetaThing`, `IotaThing`,
`orphan_column`.
"""

SELFTEST_STALE = """---
spec: "Stale banner"
status: Implemented
---
# Stale banner
> Status: In Review — awaiting Human Operator approval.
Uses `AlphaWidget`.
"""

SELFTEST_TESTCODE = "let orphan_column = \"orphan_column\"\n"

SELFTEST_CLEAN = """---
spec: "Clean"
status: Implemented
---
# Clean
Nothing to say. Uses `AlphaWidget`.
"""

SELFTEST_CODE = """
struct AlphaWidget {}
let betaThing = 1
struct GammaThing { func method() {} }
let delta_table = "delta_table"
struct EpsilonThing {}
let zetaThing = 2
struct EtaThing {}
let thetaThing = 3
struct IotaThing {}
func registerMigration(_ v: String) {}
let _ = registerMigration("v9")
"""


def selftest() -> int:
    """Prove each rule FAILS on a dirty fixture and stays silent on a clean one."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / SPEC_DIR).mkdir(parents=True)
        (root / MIGRATION_ROOT).mkdir(parents=True)
        (root / SPEC_DIR / "dirty.md").write_text(SELFTEST_SPEC)
        (root / SPEC_DIR / "clean.md").write_text(SELFTEST_CLEAN)
        (root / SPEC_DIR / "stale.md").write_text(SELFTEST_STALE)
        (root / MIGRATION_ROOT / "Schema.swift").write_text(SELFTEST_CODE)
        (root / TEST_ROOTS[0]).mkdir(parents=True, exist_ok=True)
        (root / TEST_ROOTS[0] / "OrphanTests.swift").write_text(SELFTEST_TESTCODE)

        code = index_code(root)
        src = index_code(root, CODE_ROOTS)
        tests = index_code(root, TEST_ROOTS)
        current = current_schema_version(root)
        dirty = parse_spec(root / SPEC_DIR / "dirty.md")
        clean = parse_spec(root / SPEC_DIR / "clean.md")
        stale = parse_spec(root / SPEC_DIR / "stale.md")

        checks = [
            ("R1 fails on over-claim", bool(rule_status_contradiction(dirty)[0])),
            ("R1 silent on clean", not any(rule_status_contradiction(clean))),
            ("R1 warns on stale banner", bool(rule_status_contradiction(stale)[1])),
            ("R1 stale banner does not fail", not rule_status_contradiction(stale)[0]),
            ("R4 fires", bool(rule_stale_evidence(dirty, current))),
            ("R4 silent on clean", not rule_stale_evidence(clean, current)),
            ("R3 fires", bool(rule_resolves_like_built(dirty, src, tests))),
            ("R3 silent on Implemented", not rule_resolves_like_built(clean, src, tests)),
            ("R5 fires on test-only symbol", bool(rule_tested_not_built(dirty, src, tests))),
            ("R5 silent when in source", not rule_tested_not_built(clean, src, tests)),
            ("schema head read", current == 9),
            # Design note 2: both halves of a dotted token must be present.
            ("dotted token resolves when both halves exist", resolves("GammaThing.method", src)),
            ("dotted token does NOT resolve off base alone",
             not resolves("GammaThing.noSuchMember", src)),
            ("absent token does not resolve", not resolves("NoSuchSymbol", src)),
        ]
        total = len(checks)
        for name, passed in checks:
            if not passed:
                failures.append(name)

    if failures:
        print("selftest FAILED: " + ", ".join(failures), file=sys.stderr)
        return 1
    print(f"selftest ok — {total} assertions; every rule both fires and stays silent")
    return 0


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description="Fail when recorded status disagrees with the tree.")
    ap.add_argument("--offline", action="store_true", help="skip R2 (no gh calls)")
    ap.add_argument("--selftest", action="store_true", help="prove the rules can fail")
    ap.add_argument("--project-root", default=None)
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    root = Path(args.project_root or Path(__file__).resolve().parent.parent)
    spec_dir = root / SPEC_DIR
    if not spec_dir.is_dir():
        print(f"spec-drift: no {SPEC_DIR}/ under {root}; nothing to check.")
        return 0

    src = index_code(root, CODE_ROOTS)
    tests = index_code(root, TEST_ROOTS)
    current = current_schema_version(root)
    specs = [parse_spec(p) for p in sorted(spec_dir.glob("*.md"))]

    fails: list[str] = []
    warns: list[str] = []
    for spec in specs:
        f1, w1 = rule_status_contradiction(spec)
        fails += f1
        warns += w1
        fails += rule_stale_evidence(spec, current)
        warns += rule_resolves_like_built(spec, src, tests)
        warns += rule_tested_not_built(spec, src, tests)

    skipped = None
    if args.offline:
        skipped = "R2 skipped (--offline)"
    else:
        r2, why = rule_shipped_briefs(root)
        fails += r2
        if why:
            skipped = f"R2 skipped ({why})"

    print(f"spec-drift: {len(specs)} spec(s), schema head "
          f"{'v%d' % current if current else 'unknown'}, "
          f"{len(src)} bytes source + {len(tests)} bytes tests indexed")
    for line in fails:
        print(f"  ✗ {line}")
    for line in warns:
        print(f"  ⚠ {line}")
    if skipped:
        print(f"  · {skipped}")

    if fails:
        print(f"\nspec-drift FAILED: {len(fails)} objective contradiction(s), "
              f"{len(warns)} advisory.")
        print("A status field that disagrees with the tree is how three separate "
              "attempts to pick up work were wasted. Fix the record in Notion "
              "(specs are generated) or move the brief, then re-run.")
        return 1

    print(f"\nspec-drift ok: no contradictions, {len(warns)} advisory.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

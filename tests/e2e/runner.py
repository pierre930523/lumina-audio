#!/usr/bin/env python3
"""
Lumina Audio End-to-End Test Suite Runner.
Discovers and executes tests across Tiers 1-4, tracks execution times and pass/fail assertions,
generates formatted console logs, saves structured JSON reports, and exits with appropriate codes.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
import unittest
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

DEFAULT_E2E_DIR = os.path.dirname(os.path.abspath(__file__))

BASELINE_TIER_FILES: Dict[str, List[str]] = {
    "1": ["test_tier1_features.py"],
    "2": ["test_tier2_boundaries.py"],
    "3": ["test_tier3_pairwise.py"],
    "4": ["test_tier4_scenarios.py"],
}

HARNESS_TIER_FILES: Dict[str, List[str]] = {
    "1": ["test_tier1_live_harness.py"],
    "2": ["test_tier2_live_harness.py"],
    "3": ["test_tier3_live_harness.py"],
    "4": ["test_tier4_live_harness.py"],
}

R1_R3_TIER_FILES: Dict[str, List[str]] = {
    "1": ["test_tier1_r1_r3.py"],
    "2": ["test_tier2_r1_r3.py"],
    "3": ["test_tier3_r1_r3.py"],
    "4": ["test_tier4_r1_r3.py"],
}

PHASE12_18_TIER_FILES: Dict[str, List[str]] = {
    "1": ["test_tier1_phase12_18.py"],
    "2": ["test_tier2_phase12_18.py"],
    "3": ["test_tier3_phase12_18.py"],
    "4": ["test_tier4_phase12_18.py"],
}

SUITE_CHOICES: Tuple[str, ...] = (
    "auto",
    "baseline",
    "harness",
    "r1",
    "r2",
    "r3",
    "r1_r3",
    "phase12_18",
    "full",
)

R1_FEATURES: Set[str] = {f"F{i}" for i in range(33, 43)}  # F33-F42
R2_FEATURES: Set[str] = {f"F{i}" for i in range(43, 46)}  # F43-F45
R3_FEATURES: Set[str] = {f"F{i}" for i in range(46, 50)}  # F46-F49

SCENARIO_FEATURE_MAP: Dict[str, List[str]] = {
    "17": ["F34", "F37", "F38"],
    "18": ["F34", "F35", "F36", "F40"],
    "19": ["F39", "F40", "F41", "F42"],
    "20": ["F33", "F41", "F42"],
    "21": ["F43", "F44"],
    "22": ["F43", "F45"],
    "23": ["F46", "F47"],
    "24": ["F46", "F48"],
    "25": ["F46", "F49"],
    "26": ["F33", "F50"],
}


def extract_test_features(test: unittest.TestCase) -> List[str]:
    """Extract ordered, deduplicated feature IDs (e.g. F01..F50 or P12_F01..P18_F14) from a TestCase."""
    classname = test.__class__.__name__
    method_name = getattr(test, "_testMethodName", "")
    ordered: List[str] = []
    seen: Set[str] = set()

    def _add_raw(tag: str) -> None:
        if tag not in seen:
            seen.add(tag)
            ordered.append(tag)

    # Phase 12-18 tags (e.g. P12_F01, P18_F14) take precedence without altering F01..F50 mapping
    class_doc = test.__class__.__doc__ or ""
    method_obj = getattr(test, method_name, None)
    method_doc = (getattr(method_obj, "__doc__", None) or "") if method_obj else ""
    for src_text in (classname, method_name, f"{class_doc} {method_doc}"):
        for p_num, f_num in re.findall(r"P(1[2-8])_F(\d+)", src_text, re.IGNORECASE):
            _add_raw(f"P{p_num}_F{int(f_num):02d}")
    if ordered:
        return ordered

    def _add(num_str: str) -> None:
        _add_raw(f"F{int(num_str):02d}")

    for m in re.findall(r"Feature(\d+)", classname):
        _add(m)
    for m in re.findall(r"(?:^|_|\bTest)F(\d+)(?=_|$)", classname):
        _add(m)
    for m in re.findall(r"(?:^|_)f(\d+)(?=_|$)", method_name, re.IGNORECASE):
        _add(m)

    if not ordered:
        for m in re.findall(r"\bF(3[3-9]|4[0-9]|50)\b", f"{class_doc} {method_doc}"):
            _add(m)

    if not ordered:
        sc = re.search(r"Scenario(\d+)", classname)
        if sc:
            sc_num = str(int(sc.group(1)))
            for tag in SCENARIO_FEATURE_MAP.get(sc_num, []):
                if tag not in seen:
                    seen.add(tag)
                    ordered.append(tag)

    return ordered


def extract_primary_feature(test: unittest.TestCase) -> str:
    """Return the primary feature tag for reporting, or UNKNOWN."""
    feats = extract_test_features(test)
    return feats[0] if feats else "UNKNOWN"


def iter_test_cases(suite: unittest.TestSuite) -> Iterable[unittest.TestCase]:
    """Yield individual TestCase instances from nested TestSuite objects."""
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from iter_test_cases(item)
        else:
            yield item


def _matches_milestone_suite(test: unittest.TestCase, suite_mode: str) -> bool:
    """Dependency-safe milestone matching for --suite r1|r2|r3 filtering."""
    feats = extract_test_features(test)
    if not feats:
        return False
    if suite_mode == "r1":
        return all(f in R1_FEATURES for f in feats)
    if suite_mode == "r2":
        return any(f in R2_FEATURES for f in feats) and all(
            f in (R1_FEATURES | R2_FEATURES) for f in feats
        )
    if suite_mode == "r3":
        return any(f in R3_FEATURES for f in feats) and all(
            f in (R1_FEATURES | R2_FEATURES | R3_FEATURES) for f in feats
        )
    return True


def filter_suite_by_milestone(
    suite: unittest.TestSuite, suite_mode: str
) -> unittest.TestSuite:
    """Filter a TestSuite to tests belonging to the requested milestone slice."""
    filtered = unittest.TestSuite()
    for tc in iter_test_cases(suite):
        if _matches_milestone_suite(tc, suite_mode):
            filtered.addTest(tc)
    return filtered


def parse_project_milestones(project_md_path: str) -> Dict[str, str]:
    """Parse milestone status strings (M1..M11) from PROJECT.md."""
    statuses: Dict[str, str] = {}
    if not os.path.isfile(project_md_path):
        return statuses

    with open(project_md_path, "r", encoding="utf-8") as f:
        for line in f:
            if re.match(r"^\|\s*(M\d+)\s*\|", line):
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                if len(cells) >= 5:
                    statuses[cells[0]] = cells[4]
    return statuses


def should_activate_r1_r3(
    workspace_root: str,
) -> Tuple[bool, str, Dict[str, str]]:
    """Determine whether --suite auto should include the R1-R3 test suite."""
    project_md = os.path.join(workspace_root, "PROJECT.md")
    statuses = parse_project_milestones(project_md)

    if os.environ.get("LUMINA_E2E_FULL") == "1":
        return True, "LUMINA_E2E_FULL=1", statuses

    target_milestones = ("M7", "M8", "M9", "M10")
    if all(
        re.match(r"^DONE(?:\b|$)", statuses.get(m, ""), re.IGNORECASE)
        for m in target_milestones
    ):
        return True, "PROJECT.md M7-M10 all DONE", statuses

    return False, "M7-M10 pending", statuses


class E2ETestResult(unittest.TestResult):
    """Custom TestResult collecting detailed execution metrics and structured reports."""

    def __init__(self, verbose: bool = False):
        super().__init__()
        self.verbose = verbose
        self.test_records: List[Dict[str, Any]] = []
        self._test_start_time: float = 0.0

    def startTest(self, test: unittest.TestCase):
        super().startTest(test)
        self._test_start_time = time.perf_counter()

    def addSuccess(self, test: unittest.TestCase):
        super().addSuccess(test)
        elapsed_ms = (time.perf_counter() - self._test_start_time) * 1000.0
        self._record(test, "PASS", elapsed_ms, None)
        if self.verbose:
            self._print_result("PASS", test, elapsed_ms)

    def addFailure(self, test: unittest.TestCase, err):
        super().addFailure(test, err)
        elapsed_ms = (time.perf_counter() - self._test_start_time) * 1000.0
        err_msg = self._format_error(err)
        self._record(test, "FAIL", elapsed_ms, err_msg)
        self._print_result("FAIL", test, elapsed_ms, err_msg)

    def addError(self, test: unittest.TestCase, err):
        super().addError(test, err)
        elapsed_ms = (time.perf_counter() - self._test_start_time) * 1000.0
        err_msg = self._format_error(err)
        self._record(test, "ERROR", elapsed_ms, err_msg)
        self._print_result("ERROR", test, elapsed_ms, err_msg)

    def addSkip(self, test: unittest.TestCase, reason: str):
        super().addSkip(test, reason)
        elapsed_ms = (time.perf_counter() - self._test_start_time) * 1000.0
        self._record(test, "SKIP", elapsed_ms, reason)
        if self.verbose:
            self._print_result("SKIP", test, elapsed_ms, reason)

    def _record(
        self,
        test: unittest.TestCase,
        status: str,
        duration_ms: float,
        error_detail: Optional[str],
    ):
        test_id = test.id()
        classname = test.__class__.__name__
        method_name = test._testMethodName
        doc = (getattr(test, method_name).__doc__ or "").strip()
        feature = extract_primary_feature(test)

        self.test_records.append(
            {
                "id": test_id,
                "classname": classname,
                "name": method_name,
                "doc": doc,
                "feature": feature,
                "status": status,
                "duration_ms": round(duration_ms, 3),
                "error": error_detail,
            }
        )

    def _format_error(self, err) -> str:
        exctype, value, tb = err
        import traceback

        return "".join(traceback.format_exception(exctype, value, tb))

    def _print_result(
        self,
        status: str,
        test: unittest.TestCase,
        duration_ms: float,
        error_msg: Optional[str] = None,
    ):
        classname = test.__class__.__name__
        name = test._testMethodName
        status_col = f"[{status}]"
        print(f"  {status_col:<7} {classname}.{name} ({duration_ms:.1f}ms)")
        if error_msg and status in ("FAIL", "ERROR"):
            for line in error_msg.strip().splitlines()[-5:]:
                print(f"         ! {line}")


def _resolve_tiers(tier: str) -> Tuple[List[str], bool]:
    """Resolve CLI --tier argument into normalized tier keys and is_all flag."""
    t_lower = tier.lower().strip()
    if t_lower in ("all", "*"):
        return ["1", "2", "3", "4"], True
    if tier in BASELINE_TIER_FILES:
        return [tier], False
    tier_clean = t_lower.replace("tier", "")
    if tier_clean in BASELINE_TIER_FILES:
        return [tier_clean], False
    raise ValueError(f"Unknown tier: {tier}. Valid options: 1, 2, 3, 4, all")


def _load_module_file(
    loader: unittest.TestLoader, e2e_dir: str, file_name: str
) -> unittest.TestSuite:
    stem = os.path.splitext(file_name)[0]
    if os.path.realpath(e2e_dir) == os.path.realpath(DEFAULT_E2E_DIR):
        mod_name = f"tests.e2e.{stem}"
        return loader.loadTestsFromName(mod_name)

    file_path = os.path.abspath(os.path.join(e2e_dir, file_name))
    dir_hash = hashlib.sha1(os.path.realpath(e2e_dir).encode("utf-8")).hexdigest()[:8]
    unique_mod_name = f"_lumina_e2e_custom_{dir_hash}.{stem}"
    spec = importlib.util.spec_from_file_location(unique_mod_name, file_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Could not load E2E module from {file_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[unique_mod_name] = module
    spec.loader.exec_module(module)
    return loader.loadTestsFromModule(module)


def discover_tier_suites(
    e2e_dir: str,
    tier: str,
    suite_mode: str = "auto",
    workspace_root: Optional[str] = None,
    quiet: bool = False,
) -> unittest.TestSuite:
    """Discovers test suites corresponding to the requested tier and suite mode."""
    if suite_mode not in SUITE_CHOICES:
        raise ValueError(
            f"Unknown suite: {suite_mode}. Valid options: {', '.join(SUITE_CHOICES)}"
        )

    if workspace_root is None:
        workspace_root = os.path.abspath(os.path.join(e2e_dir, "..", ".."))

    if workspace_root not in sys.path:
        sys.path.insert(0, workspace_root)

    tiers, is_all = _resolve_tiers(tier)
    loader = unittest.defaultTestLoader
    suite = unittest.TestSuite()

    if suite_mode == "auto":
        activate_r1_r3, reason, statuses = should_activate_r1_r3(workspace_root)
        r1_r3_on_disk = any(
            os.path.isfile(os.path.join(e2e_dir, fname))
            for t in tiers
            for fname in R1_R3_TIER_FILES[t]
        )

        if not quiet:
            if activate_r1_r3:
                print(f"[INFO] Auto-activated full R1-R3 E2E suite ({reason}).")
            elif r1_r3_on_disk:
                m_summary = ", ".join(
                    f"{m}={statuses.get(m, 'UNKNOWN')}" for m in ("M7", "M8", "M9", "M10")
                )
                print(
                    "[INFO] R1-R3 E2E suite is ready on disk "
                    f"(milestones pending: {m_summary})."
                )
                print(
                    "[INFO] Run with '--suite full' (or '--suite r1|r2|r3|r1_r3', "
                    "or set LUMINA_E2E_FULL=1) to execute R1-R3 tests."
                )

        for t in tiers:
            for fname in BASELINE_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))
                elif not is_all:
                    raise FileNotFoundError(f"Requested test file not found: {fpath}")

            for fname in HARNESS_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))

            if activate_r1_r3:
                for fname in R1_R3_TIER_FILES[t]:
                    fpath = os.path.join(e2e_dir, fname)
                    if os.path.isfile(fpath):
                        suite.addTests(_load_module_file(loader, e2e_dir, fname))
                    elif not is_all:
                        raise FileNotFoundError(
                            f"Activated R1-R3 test file not found: {fpath}"
                        )

        if activate_r1_r3 and is_all:
            loaded_r1_r3 = sum(
                1
                for t in tiers
                for fname in R1_R3_TIER_FILES[t]
                if os.path.isfile(os.path.join(e2e_dir, fname))
            )
            if loaded_r1_r3 == 0:
                raise FileNotFoundError(
                    "R1-R3 suite activated, but no test_tier*_r1_r3.py files were found."
                )
        return suite

    if suite_mode == "baseline":
        for t in tiers:
            for fname in BASELINE_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if not os.path.isfile(fpath):
                    raise FileNotFoundError(f"Requested test file not found: {fpath}")
                suite.addTests(_load_module_file(loader, e2e_dir, fname))
        return suite

    if suite_mode == "harness":
        for t in tiers:
            for fname in HARNESS_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if not os.path.isfile(fpath):
                    raise FileNotFoundError(f"Requested harness file not found: {fpath}")
                suite.addTests(_load_module_file(loader, e2e_dir, fname))
        return suite

    if suite_mode in ("r1", "r2", "r3", "r1_r3"):
        loaded_files = 0
        for t in tiers:
            for fname in R1_R3_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))
                    loaded_files += 1
                elif not is_all:
                    raise FileNotFoundError(
                        f"Requested R1-R3 test file not found: {fpath}"
                    )
        if loaded_files == 0:
            raise FileNotFoundError(
                f"No R1-R3 test modules (test_tier*_r1_r3.py) found in {e2e_dir} "
                f"for --suite {suite_mode}."
            )
        if suite_mode in ("r1", "r2", "r3"):
            suite = filter_suite_by_milestone(suite, suite_mode)
            if suite.countTestCases() == 0:
                raise ValueError(
                    f"No tests matched milestone filter '--suite {suite_mode}' for tier '{tier}'."
                )
        return suite

    if suite_mode == "phase12_18":
        loaded_files = 0
        for t in tiers:
            for fname in PHASE12_18_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))
                    loaded_files += 1
                elif not is_all:
                    raise FileNotFoundError(
                        f"Requested Phase 12-18 test file not found: {fpath}"
                    )
        if loaded_files == 0:
            raise FileNotFoundError(
                f"No Phase 12-18 test modules (test_tier*_phase12_18.py) found in {e2e_dir}."
            )
        return suite

    if suite_mode == "full":
        loaded_r1_r3 = 0
        for t in tiers:
            for fname in BASELINE_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if not os.path.isfile(fpath):
                    raise FileNotFoundError(f"Requested baseline file not found: {fpath}")
                suite.addTests(_load_module_file(loader, e2e_dir, fname))

            for fname in HARNESS_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))

            for fname in R1_R3_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))
                    loaded_r1_r3 += 1
                elif not is_all:
                    raise FileNotFoundError(
                        f"Requested R1-R3 test file not found for --suite full: {fpath}"
                    )

            for fname in PHASE12_18_TIER_FILES[t]:
                fpath = os.path.join(e2e_dir, fname)
                if os.path.isfile(fpath):
                    suite.addTests(_load_module_file(loader, e2e_dir, fname))
        if loaded_r1_r3 == 0:
            raise FileNotFoundError(
                f"No R1-R3 test modules (test_tier*_r1_r3.py) found in {e2e_dir} "
                f"for --suite full."
            )
        return suite

    raise ValueError(f"Unhandled suite mode: {suite_mode}")


def run_e2e(
    tier: str = "all",
    verbose: bool = False,
    report_path: Optional[str] = None,
    suite_mode: str = "auto",
    strict: bool = False,
    list_only: bool = False,
) -> int:
    """Main execution function for the E2E test runner."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    workspace_root = os.path.abspath(os.path.join(script_dir, "..", ".."))

    if workspace_root not in sys.path:
        sys.path.insert(0, workspace_root)

    if not list_only:
        print("=" * 72)
        print("  Lumina Audio E2E Test Suite Runner")
        print(f"  Target Tier : {tier}")
        print(f"  Target Suite: {suite_mode}")
        print(
            f"  Timestamp   : {datetime.datetime.now(datetime.timezone.utc).isoformat()}"
        )
        print("=" * 72)

    try:
        suite = discover_tier_suites(
            script_dir,
            tier,
            suite_mode=suite_mode,
            workspace_root=workspace_root,
            quiet=list_only,
        )
    except Exception as e:
        print(f"[FATAL] Test discovery failed: {e}")
        return 2

    if list_only:
        for tc in iter_test_cases(suite):
            print(tc.id())
        return 0

    total_discovered = suite.countTestCases()
    print(f"Discovered {total_discovered} test cases.\n")

    start_wall = time.perf_counter()
    result = E2ETestResult(verbose=verbose)
    suite.run(result)
    duration_total = time.perf_counter() - start_wall

    passed_count = sum(1 for t in result.test_records if t["status"] == "PASS")
    failed_count = sum(1 for t in result.test_records if t["status"] == "FAIL")
    error_count = sum(1 for t in result.test_records if t["status"] == "ERROR")
    skipped_count = sum(1 for t in result.test_records if t["status"] == "SKIP")
    pass_rate = (
        (passed_count / total_discovered * 100.0) if total_discovered > 0 else 0.0
    )

    print("-" * 72)
    print("Test Execution Summary:")
    print(f"  Total Run : {len(result.test_records)}")
    print(f"  Passed    : {passed_count}")
    print(f"  Failed    : {failed_count}")
    print(f"  Errors    : {error_count}")
    print(f"  Skipped   : {skipped_count}")
    print(f"  Pass Rate : {pass_rate:.1f}%")
    print(f"  Wall Time : {duration_total:.2f} seconds")
    print("=" * 72)

    # Save JSON report (preserve exact schema)
    if not report_path:
        reports_dir = os.path.join(script_dir, "reports")
        os.makedirs(reports_dir, exist_ok=True)
        report_path = os.path.join(reports_dir, "e2e_results.json")
    else:
        os.makedirs(os.path.dirname(os.path.abspath(report_path)), exist_ok=True)

    report_data = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "tier": tier,
        "total": len(result.test_records),
        "passed": passed_count,
        "failed": failed_count,
        "errors": error_count,
        "skipped": skipped_count,
        "pass_rate": round(pass_rate, 2),
        "duration_seconds": round(duration_total, 3),
        "tests": result.test_records,
    }

    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report_data, f, indent=2)
    print(f"Structured JSON report written to: {report_path}\n")

    if failed_count > 0 or error_count > 0:
        return 1
    if strict and skipped_count > 0:
        print(f"[STRICT] Failing run because {skipped_count} test(s) were skipped.")
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description="Lumina Audio E2E Test Suite Runner")
    parser.add_argument(
        "--tier",
        type=str,
        default="all",
        help="Tier target to run: 1, 2, 3, 4, or all (default: all)",
    )
    parser.add_argument(
        "--suite",
        type=str,
        choices=SUITE_CHOICES,
        default="auto",
        help="Suite selection: auto, baseline, harness, r1, r2, r3, r1_r3, phase12_18, full (default: auto)",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Print verbose execution details per test",
    )
    parser.add_argument(
        "--report",
        type=str,
        default=None,
        help="Custom output path for structured JSON results report",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat any skipped test as a failure (exit code 1)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List discovered test IDs without running tests or modifying e2e_results.json",
    )

    args = parser.parse_args()
    exit_code = run_e2e(
        tier=args.tier,
        verbose=args.verbose,
        report_path=args.report,
        suite_mode=args.suite,
        strict=args.strict,
        list_only=args.list,
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify that every `lumina_*` FFI symbol looked up in Dart exists in `crates/core-ffi`."""

from __future__ import annotations

import pathlib
import re
import sys
from collections import defaultdict

DART_COMMENT_OR_STRING_RE = re.compile(
    r'r?"""[\s\S]*?"""'
    r"|r?'''[\s\S]*?'''"
    r'|r"[^"\n]*"'
    r"|r'[^'\n]*'"
    r'|"(?:\\.|[^"\\\n])*"'
    r"|'(?:\\.|[^'\\\n])*'"
    r"|//[^\n]*"
    r"|/\*[\s\S]*?\*/"
)

RUST_COMMENT_OR_STRING_RE = re.compile(
    r'b?r(#*)"[\s\S]*?"\1'
    r'|b?"(?:\\.|[^"\\])*"'
    r"|b?'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^'\\\n])'"
    r"|//[^\n]*"
    r"|/\*[\s\S]*?\*/"
)


def _blank_preserving_newlines(text: str) -> str:
    return "".join("\n" if ch == "\n" else " " for ch in text)


def strip_dart_comments(source: str) -> str:
    """Strip Dart `//` and `/* ... */` comments while preserving strings and line numbers."""
    return DART_COMMENT_OR_STRING_RE.sub(
        lambda m: _blank_preserving_newlines(m.group(0))
        if m.group(0).startswith(("//", "/*"))
        else m.group(0),
        source,
    )


def strip_rust_comments(source: str) -> str:
    """Strip Rust `//` and `/* ... */` comments while preserving strings, lifetimes, and line numbers."""
    return RUST_COMMENT_OR_STRING_RE.sub(
        lambda m: _blank_preserving_newlines(m.group(0))
        if m.group(0).startswith(("//", "/*"))
        else m.group(0),
        source,
    )


def find_dart_lookups(dart_root: pathlib.Path, repo_root: pathlib.Path) -> dict[str, list[str]]:
    """Scan `app/lib/**/*.dart` for `lookup<...>('lumina_...')` and `lookupFunction<..., ...>('lumina_...')`."""
    lookups: dict[str, list[str]] = defaultdict(list)
    pattern = re.compile(r"\blookup(?:Function)?\b")
    arg_pattern = re.compile(r"\s*\(\s*(['\"])(lumina_[A-Za-z0-9_]+)\1")

    for path in sorted(dart_root.rglob("*.dart")):
        raw = path.read_text(encoding="utf-8", errors="replace")
        cleaned = strip_dart_comments(raw)
        rel = path.relative_to(repo_root).as_posix()

        for match in pattern.finditer(cleaned):
            pos = match.end()
            while pos < len(cleaned) and cleaned[pos].isspace():
                pos += 1

            # Optional balanced generic type arguments `<...>` (handles nested generics)
            if pos < len(cleaned) and cleaned[pos] == "<":
                depth = 0
                while pos < len(cleaned):
                    c = cleaned[pos]
                    if c == "<":
                        depth += 1
                    elif c == ">":
                        depth -= 1
                        if depth == 0:
                            pos += 1
                            break
                    pos += 1

            arg_match = arg_pattern.match(cleaned, pos)
            if arg_match:
                symbol = arg_match.group(2)
                line_no = cleaned.count("\n", 0, match.start()) + 1
                lookups[symbol].append(f"{rel}:{line_no}")

    return lookups


def find_rust_exports(ffi_root: pathlib.Path, repo_root: pathlib.Path) -> dict[str, list[str]]:
    """Scan `crates/core-ffi/src/**/*.rs` for `#[unsafe(no_mangle)]` / `#[no_mangle]` `pub extern \"C\" fn lumina_*`."""
    exports: dict[str, list[str]] = defaultdict(list)
    export_pattern = re.compile(
        r"#\[\s*(?:unsafe\s*\(\s*)?no_mangle\s*(?:\)\s*)?\]"
        r"(?:\s*#\[[^\]]*\])*"
        r"\s*pub\s+(?:unsafe\s+)?extern\s+\"C\"\s+fn\s+(lumina_[A-Za-z0-9_]+)\b"
    )

    for path in sorted(ffi_root.rglob("*.rs")):
        raw = path.read_text(encoding="utf-8", errors="replace")
        cleaned = strip_rust_comments(raw)
        rel = path.relative_to(repo_root).as_posix()

        for match in export_pattern.finditer(cleaned):
            symbol = match.group(1)
            line_no = cleaned.count("\n", 0, match.start()) + 1
            exports[symbol].append(f"{rel}:{line_no}")

    return exports


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    dart_root = repo_root / "app" / "lib"
    ffi_root = repo_root / "crates" / "core-ffi" / "src"

    if not dart_root.is_dir():
        print(f"ERROR: Dart source directory not found: {dart_root}", file=sys.stderr)
        return 2
    if not ffi_root.is_dir():
        print(f"ERROR: Rust core-ffi source directory not found: {ffi_root}", file=sys.stderr)
        return 2

    dart_lookups = find_dart_lookups(dart_root, repo_root)
    rust_exports = find_rust_exports(ffi_root, repo_root)

    total_lookup_sites = sum(len(locs) for locs in dart_lookups.values())
    total_export_sites = sum(len(locs) for locs in rust_exports.values())
    unique_dart = set(dart_lookups.keys())
    unique_rust = set(rust_exports.keys())

    missing = sorted(unique_dart - unique_rust)
    unused_in_dart = sorted(unique_rust - unique_dart)

    print(
        f"FFI symbol check: "
        f"Dart lookups = {len(unique_dart)} unique ({total_lookup_sites} call sites), "
        f"Rust core-ffi exports = {len(unique_rust)} unique ({total_export_sites} definitions)"
    )

    if not unique_dart or not unique_rust:
        print("ERROR: Unexpected empty FFI symbol set; check scanner patterns.", file=sys.stderr)
        return 1

    if missing:
        print(f"ERROR: {len(missing)} Dart FFI symbol(s) missing in crates/core-ffi/src:", file=sys.stderr)
        for sym in missing:
            locs = ", ".join(dart_lookups[sym])
            print(f"  - {sym} (referenced at {locs})", file=sys.stderr)
        return 1

    if unused_in_dart:
        print(
            f"Note: {len(unused_in_dart)} Rust export(s) not directly looked up in app/lib "
            f"(e.g., E2E/FFI-only): {', '.join(unused_in_dart)}"
        )

    print("OK: All Dart FFI symbol lookups resolve to core-ffi exports.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

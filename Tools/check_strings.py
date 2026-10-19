#!/usr/bin/env python3
"""Consistency checker for YTKACE localization tables.

Parses every ``<lang>.lproj/Localizable.strings`` below the resource bundle and
compares each language against ``en`` (the source of truth):

* keys missing from a language,
* extra keys that ``en`` does not have,
* format placeholder mismatches (``%@``, ``%d``, ``%ld``, ``%lu``, ``%1$@`` ...).
  Positional reordering is fine as long as the multiset of placeholder
  types matches the one in ``en``.

Exit status is 0 when everything is consistent and 1 otherwise.

Usage: Tools/check_strings.py [--bundle Resources/YTKACE.bundle] [--quiet]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BUNDLE = os.path.join(REPO_ROOT, "Resources", "YTKACE.bundle")
BASE_LANGUAGE = "en"


class StringsParseError(ValueError):
    pass


_SIMPLE_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    '"': '"',
    "'": "'",
    "\\": "\\",
    "0": "\0",
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "v": "\v",
}


def _skip_ws_and_comments(text: str, i: int, path: str) -> int:
    n = len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n﻿":
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise StringsParseError(f"{path}: unterminated comment at offset {i}")
            i = j + 2
        else:
            break
    return i


def _line_of(text: str, i: int) -> int:
    return text.count("\n", 0, i) + 1


def _read_quoted(text: str, i: int, path: str) -> Tuple[str, int]:
    """Read a double-quoted string starting at text[i] == '"'."""
    if i >= len(text) or text[i] != '"':
        raise StringsParseError(f"{path}:{_line_of(text, i)}: expected '\"'")
    i += 1
    out: List[str] = []
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            if i + 1 >= n:
                break
            e = text[i + 1]
            if e in ("u", "U"):
                m = re.match(r"[0-9a-fA-F]{4}", text[i + 2:i + 6])
                if not m:
                    raise StringsParseError(f"{path}:{_line_of(text, i)}: bad \\u escape")
                out.append(chr(int(m.group(0), 16)))
                i += 6
                continue
            if e in "01234567" and re.match(r"[0-7]{3}", text[i + 1:i + 4]):
                out.append(chr(int(text[i + 1:i + 4], 8)))
                i += 4
                continue
            out.append(_SIMPLE_ESCAPES.get(e, e))
            i += 2
            continue
        out.append(c)
        i += 1
    raise StringsParseError(f"{path}: unterminated string literal")


@dataclass
class StringsTable:
    path: str
    entries: Dict[str, str] = field(default_factory=dict)
    duplicates: List[str] = field(default_factory=list)


def parse_strings_text(text: str, path: str = "<string>") -> StringsTable:
    table = StringsTable(path=path)
    i = 0
    n = len(text)
    while True:
        i = _skip_ws_and_comments(text, i, path)
        if i >= n:
            break
        key, i = _read_quoted(text, i, path)
        i = _skip_ws_and_comments(text, i, path)
        if i < n and text[i] == "=":
            i = _skip_ws_and_comments(text, i + 1, path)
            value, i = _read_quoted(text, i, path)
            i = _skip_ws_and_comments(text, i, path)
        else:
            value = key  # "key"; shorthand
        if i >= n or text[i] != ";":
            raise StringsParseError(f"{path}:{_line_of(text, i)}: expected ';' after {key!r}")
        i += 1
        if key in table.entries:
            table.duplicates.append(key)
        table.entries[key] = value
    return table


def parse_strings_file(path: str) -> StringsTable:
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16")
    else:
        text = raw.decode("utf-8-sig")
    return parse_strings_text(text, path)


# printf-style placeholders used by NSString formatting.
_PLACEHOLDER_RE = re.compile(
    r"%(?:(?P<pos>\d+)\$)?"
    r"[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|L|z|t|j)?"
    r"(?P<conv>[@dDiuUxXoOfFeEgGcCsSpaA%])"
)


def placeholders(value: str) -> Counter:
    """Return a multiset of placeholder types (length modifier + conversion)."""
    found: Counter = Counter()
    for m in _PLACEHOLDER_RE.finditer(value):
        conv = m.group("conv")
        if conv == "%":
            continue
        found[(m.group("len") or "") + conv] += 1
    return found


def load_bundle(bundle: str) -> Dict[str, StringsTable]:
    tables: Dict[str, StringsTable] = {}
    for name in sorted(os.listdir(bundle)):
        if not name.endswith(".lproj"):
            continue
        path = os.path.join(bundle, name, "Localizable.strings")
        if os.path.isfile(path):
            tables[name[: -len(".lproj")]] = parse_strings_file(path)
    return tables


@dataclass
class Report:
    missing: Dict[str, List[str]] = field(default_factory=dict)
    extra: Dict[str, List[str]] = field(default_factory=dict)
    placeholder_mismatches: Dict[str, List[Tuple[str, str, str]]] = field(default_factory=dict)
    duplicates: Dict[str, List[str]] = field(default_factory=dict)
    base_placeholder_issues: List[Tuple[str, str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not (
            any(self.missing.values())
            or any(self.extra.values())
            or any(self.placeholder_mismatches.values())
            or any(self.duplicates.values())
            or self.base_placeholder_issues
        )


def check(tables: Dict[str, StringsTable], base: str = BASE_LANGUAGE) -> Report:
    if base not in tables:
        raise SystemExit(f"base language {base!r} not found")
    report = Report()
    base_entries = tables[base].entries
    base_keys = set(base_entries)
    for key, value in base_entries.items():
        # In the base table the key is the English text; its value must use
        # the same placeholders, since YTKACELocalized falls back to the key.
        if placeholders(key) != placeholders(value):
            report.base_placeholder_issues.append((key, value))
    for lang, table in tables.items():
        if table.duplicates:
            report.duplicates[lang] = sorted(set(table.duplicates))
        if lang == base:
            continue
        keys = set(table.entries)
        report.missing[lang] = sorted(base_keys - keys)
        report.extra[lang] = sorted(keys - base_keys)
        mism = []
        for key in sorted(base_keys & keys):
            want = placeholders(base_entries[key])
            got = placeholders(table.entries[key])
            if want != got:
                mism.append((key, base_entries[key], table.entries[key]))
        report.placeholder_mismatches[lang] = mism
    return report


def format_report(report: Report, quiet: bool = False) -> str:
    lines: List[str] = []
    for key, value in report.base_placeholder_issues:
        lines.append(f"[{BASE_LANGUAGE}] placeholder mismatch between key and value: {key!r} = {value!r}")
    for lang in sorted(set(report.missing) | set(report.extra) | set(report.placeholder_mismatches) | set(report.duplicates)):
        missing = report.missing.get(lang, [])
        extra = report.extra.get(lang, [])
        mism = report.placeholder_mismatches.get(lang, [])
        dups = report.duplicates.get(lang, [])
        if not (missing or extra or mism or dups):
            if not quiet:
                lines.append(f"[{lang}] OK")
            continue
        lines.append(f"[{lang}] {len(missing)} missing, {len(extra)} extra, "
                     f"{len(mism)} placeholder mismatches, {len(dups)} duplicates")
        for k in missing:
            lines.append(f"  missing: {k!r}")
        for k in extra:
            lines.append(f"  extra:   {k!r}")
        for k, want, got in mism:
            lines.append(f"  placeholders: {k!r}: en={sorted(placeholders(want).elements())} "
                         f"{lang}={sorted(placeholders(got).elements())} ({got!r})")
        for k in dups:
            lines.append(f"  duplicate: {k!r}")
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bundle", default=DEFAULT_BUNDLE, help="path to YTKACE.bundle")
    ap.add_argument("--quiet", action="store_true", help="only print problems")
    args = ap.parse_args(argv)
    tables = load_bundle(args.bundle)
    report = check(tables)
    out = format_report(report, quiet=args.quiet)
    if out:
        print(out)
    if report.ok:
        print(f"{len(tables)} languages, {len(tables[BASE_LANGUAGE].entries)} keys: OK")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())

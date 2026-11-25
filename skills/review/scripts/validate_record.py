#!/usr/bin/env python3
"""Validate a review record (schema review-record/1).

Usage: python3 -I validate_record.py RECORD.json [--schema SCHEMA.json]
Exit 0: valid. Exit 1: invalid (one error per line, each naming a JSON pointer, never a matched
value). Exit 2: usage or read error.

Standard library only. The schema checker implements the subset of JSON Schema that
record.schema.json uses: type, const, enum, required, properties, additionalProperties: false,
items, minItems, minimum, minLength, maxLength, pattern. The semantic rules below cover what JSON
Schema cannot state: unique ids, references between sections, verdict rules from review SKILL.md
section 4, timing, the content limits (no credentials, no diff text, no home-directory paths), and
finding classes that are bare area words. Each rule is one function in RULES.
"""
import calendar
import datetime
import decimal
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCHEMA = os.path.join(HERE, "record.schema.json")
USAGE = "usage: validate_record.py RECORD.json [--schema SCHEMA.json]"

_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}
_SUPPORTED = {"$schema", "$id", "title", "description", "type", "const", "enum", "required", "properties",
              "additionalProperties", "items", "minItems", "minimum", "minLength", "maxLength", "pattern"}

# Credential shapes. A match is reported by location and pattern name only, never by value.
SECRET_PATTERNS = [
    ("aws-access-key", re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("github-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("api-key-sk", re.compile(r"\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b")),
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("stripe-key", re.compile(r"\b[rs]k_(live|test)_[A-Za-z0-9]{16,}\b")),
    ("npm-token", re.compile(r"\bnpm_[A-Za-z0-9]{36}\b")),
    # A quoted literal assigned to a secret-named key, also in JSON form ("password": "..."); placeholders
    # such as "<redacted>", "$VAR" or "***" pass.
    ("password-assignment", re.compile(
        r"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\b[\"']?\s*[:=]\s*"
        r"[\"'](?![<$*{])[^\"'\s]{4,}[\"']")),
    ("url-password", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@")),
    ("http-url-userinfo", re.compile(r"\bhttps?://[^\s/@]+@")),
]
# A diff body line: a sign, then code (not a space and not another sign, which a "---"/"+++" header has)
# or an indent of two or more blanks. One space after the sign is a Markdown bullet, not code.
DIFF_BODY_LINE = r"^[+-](?:[^\s+-]|[ \t]{2,})"
DIFF_PATTERNS = [
    ("diff-header", re.compile(r"(?m)^diff --git ")),
    ("hunk-header", re.compile(r"@@ -\d+(,\d+)? \+\d+(,\d+)? @@")),
    ("file-header", re.compile(r"(?m)^(\+\+\+|---) (a|b)/")),
    ("diff-body", re.compile(DIFF_BODY_LINE + r"[^\n]*\n" + DIFF_BODY_LINE, re.M)),
]
# A report path under a home directory names the operator's account; write it repository-relative.
# A sandbox temporary directory can flatten a home path into one segment, as the macOS scratchpad
# /private/tmp/claude-<uid>/-Users-<name>-... does, so a -Users- or -home- segment and that prefix count too.
HOME_PATH = re.compile(
    r"^(~(/|$)|/Users/|/home/|/root(/|$)|[A-Za-z]:[\\/]Users[\\/])"
    r"|^(/private)?/tmp/claude-\d+/-"
    r"|(^|[\\/])[^\\/]*-(Users|home)-")
# wall_s may differ from ended_at - started_at by the larger of these: clock rounding and setup outside the run.
WALL_TOLERANCE_S = decimal.Decimal(5)
WALL_TOLERANCE_REL = decimal.Decimal("0.01")
STAMP_FIELDS = (("created_at",), ("metrics", "started_at"), ("metrics", "ended_at"))
# Area or severity words too broad to be a finding class alone (review/references/finding-classes.md lists the
# same words; the tests compare the two). Most of them fail the schema's two-word pattern already.
BARE_CLASS_WORDS = frozenset((
    "bug", "logic", "logic-error", "omission", "correctness", "contract", "security", "docs", "documentation",
    "error-handling", "robustness", "edge-case", "test", "tests", "validation", "input-validation", "race",
    "performance",
))


def ptr(parts):
    return "/" + "/".join(str(p) for p in parts) if parts else "/"


# --- JSON Schema subset ---------------------------------------------------------------------------

def _ecma_pattern(pattern):
    """JSON Schema patterns are ECMA-262 regexes, where `$` matches only at the end of the input. Python's `$`
    also matches before a final newline, so an unescaped `$` becomes `\\Z`."""
    return re.sub(r"(?<!\\)\$", r"\\Z", pattern)


def check_schema(value, schema, path=(), errors=None):
    """Check value against the supported JSON Schema subset; append (pointer, message) to errors."""
    if errors is None:
        errors = []
    unknown = set(schema) - _SUPPORTED
    if unknown:
        raise ValueError(f"schema at {ptr(path)} uses unsupported keywords {sorted(unknown)}")
    if "const" in schema and value != schema["const"]:
        errors.append((ptr(path), f"must equal {schema['const']!r}"))
        return errors
    if "enum" in schema and value not in schema["enum"]:
        errors.append((ptr(path), f"must be one of {schema['enum']}"))
        return errors
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_TYPES[t](value) for t in types):
            errors.append((ptr(path), f"must be of type {'/'.join(types)}"))
            return errors
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append((ptr(path + (key,)), "is required"))
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key in props:
                check_schema(sub, props[key], path + (key,), errors)
            elif schema.get("additionalProperties") is False:
                errors.append((ptr(path + (key,)), "is not an allowed property"))
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append((ptr(path), f"must have at least {schema['minItems']} items"))
        if "items" in schema:
            for i, item in enumerate(value):
                check_schema(item, schema["items"], path + (i,), errors)
    if _TYPES["number"](value) and "minimum" in schema and value < schema["minimum"]:
        errors.append((ptr(path), f"must be >= {schema['minimum']}"))
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append((ptr(path), f"must have at least {schema['minLength']} characters"))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append((ptr(path), f"must have at most {schema['maxLength']} characters"))
        if "pattern" in schema and not re.search(_ecma_pattern(schema["pattern"]), value):
            errors.append((ptr(path), "does not match the required pattern"))
    return errors


# --- helpers --------------------------------------------------------------------------------------

def _strings(value, path=()):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from _strings(v, path + (k,))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from _strings(v, path + (i,))


def _get(rec, parts):
    for p in parts:
        rec = rec[p]
    return rec


def _seconds(stamp):
    """Seconds since the epoch as a Decimal for a schema-valid UTC stamp, or None for an impossible date.
    Fractional seconds are optional, so string order is not time order."""
    whole, _, frac = stamp[:-1].partition(".")
    try:
        dt = datetime.datetime.strptime(whole, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return decimal.Decimal(calendar.timegm(dt.timetuple())) + decimal.Decimal("0." + (frac or "0"))


def _span(rec):
    """ended_at - started_at in seconds, or None when either stamp is not a real time."""
    start, end = _seconds(rec["metrics"]["started_at"]), _seconds(rec["metrics"]["ended_at"])
    return None if start is None or end is None else end - start


def _open_confirmed_p1(rec):
    """Confirmed P1 findings that remain at head_sha: those without fixed_in."""
    return [f for f in rec["findings"]
            if f["severity"] == "P1" and f["confidence"] == "confirmed" and "fixed_in" not in f]


# --- semantic rules: each takes a schema-valid record and returns [(pointer, message)] -------------

def rule_unique_ids(rec):
    errors = []
    for section in ("sources", "findings", "discarded"):
        seen = set()
        for i, item in enumerate(rec[section]):
            if item["id"] in seen:
                errors.append((ptr((section, i, "id")), "duplicates an earlier id"))
            seen.add(item["id"])
    return errors


def rule_one_self_source(rec):
    n = sum(1 for s in rec["sources"] if s["kind"] == "self")
    return [] if n == 1 else [("/sources", f"must contain exactly one source of kind 'self', found {n}")]


def rule_at_most_two_rereviews(rec):
    # Review section 7 runs the bounded re-review twice; each run is its own source.
    n = sum(1 for s in rec["sources"] if s["kind"] == "bounded-re-review")
    return [] if n <= 2 else [("/sources", f"must contain at most two sources of kind 'bounded-re-review', found {n}")]


def rule_source_reason(rec):
    return [(ptr(("sources", i, "reason")), "is required when status is not 'completed'")
            for i, s in enumerate(rec["sources"]) if s["status"] != "completed" and not s["reason"]]


def rule_report_paths_not_home(rec):
    fields = [(("report_path",), rec["report_path"])]
    fields += [(("sources", i, "report_path"), s["report_path"]) for i, s in enumerate(rec["sources"])]
    errors = []
    for where, value in fields:
        if value is not None and HOME_PATH.search(value):
            errors.append((ptr(where), "is under a home directory; write it repository-relative"))
    return errors


def rule_finding_paths_relative(rec):
    errors = []
    for i, f in enumerate(rec["findings"]):
        p = f["path"]
        if p.startswith("/") or "\\" in p or ".." in p.split("/") or p.startswith("~"):
            errors.append((ptr(("findings", i, "path")), "must be repository-relative"))
    return errors


def rule_file_level_line(rec):
    return [(ptr(("findings", i, "line")), "must be 1 when file_level is true")
            for i, f in enumerate(rec["findings"]) if f["file_level"] and f["line"] != 1]


def rule_finding_source(rec):
    status = {s["id"]: s["status"] for s in rec["sources"]}
    errors = []
    for i, f in enumerate(rec["findings"]):
        if f["source"] not in status:
            errors.append((ptr(("findings", i, "source")), "names no entry in /sources"))
        elif status[f["source"]] != "completed":
            errors.append((ptr(("findings", i, "source")),
                           "names a source whose status is not 'completed'; an excluded or failed pass is not merged in"))
    return errors


def rule_confirmed_p1_route(rec):
    errors = []
    for i, f in enumerate(rec["findings"]):
        if f["severity"] == "P1" and f["confidence"] == "confirmed" and f["route"] != "fix-before-merge":
            errors.append((ptr(("findings", i, "route")), "a confirmed P1 must route 'fix-before-merge'"))
    return errors


def rule_fixed_in_not_base(rec):
    # The fix lands after the reviewed state, so it is never the base. Ancestry needs Git; the helper checks it.
    base = rec["target"]["base_sha"]
    return [(ptr(("findings", i, "fixed_in")), "equals target.base_sha; name the commit that fixed it")
            for i, f in enumerate(rec["findings"]) if f.get("fixed_in") == base]


def rule_discarded_line_needs_path(rec):
    errors = []
    for i, d in enumerate(rec["discarded"]):
        if d["line"] is not None and d["path"] is None:
            errors.append((ptr(("discarded", i, "line")), "needs a path"))
    return errors


def rule_discarded_source(rec):
    ids = {s["id"] for s in rec["sources"]}
    errors = []
    for i, d in enumerate(rec["discarded"]):
        if "source" in d and d["source"] not in ids:
            errors.append((ptr(("discarded", i, "source")), "names no entry in /sources"))
    return errors


def rule_uncommitted_fingerprint(rec):
    t = rec["target"]
    if t["mode"] == "uncommitted" and t["tree_fingerprint"] is None:
        return [("/target/tree_fingerprint", "is required when mode is 'uncommitted'")]
    return []


def rule_head_differs_from_base(rec):
    t = rec["target"]
    if t["mode"] in ("branch", "commit") and t["head_sha"] == t["base_sha"]:
        return [("/target/head_sha", f"must differ from base_sha when mode is '{t['mode']}'")]
    return []


def rule_guide_commit(rec):
    g = rec["guide"]
    if g["status"] in ("used", "absent") and g["commit"] is None:
        return [("/guide/commit", f"is required when status is '{g['status']}'")]
    return []


def rule_guide_reason(rec):
    g = rec["guide"]
    if g["status"] == "unavailable" and not g["reason"]:
        return [("/guide/reason", "is required when status is 'unavailable'")]
    return []


def rule_coverage_gaps(rec):
    cov = rec["coverage"]
    if cov["complete"] and cov["gaps"]:
        return [("/coverage/gaps", "must be empty when complete is true")]
    if not cov["complete"] and not cov["gaps"]:
        return [("/coverage/gaps", "must name each gap when complete is false")]
    return []


def rule_verdict(rec):
    """Review SKILL.md section 4: the verdict agrees with the findings and the coverage."""
    v, complete, open_p1 = rec["verdict"], rec["coverage"]["complete"], _open_confirmed_p1(rec)
    errors = []
    if open_p1 and v != "does-not-pass":
        errors.append(("/verdict", "a confirmed P1 without fixed_in requires 'does-not-pass', "
                                   "even when coverage is incomplete"))
    if v == "does-not-pass" and not open_p1:
        errors.append(("/verdict", "'does-not-pass' requires a confirmed P1 without fixed_in; "
                                   "an unconfirmed or fixed finding does not block alone"))
    if v == "passes-clean" and (rec["findings"] or not complete):
        errors.append(("/verdict", "'passes-clean' requires no findings and complete coverage"))
    if v == "passes-with-findings" and (not rec["findings"] or not complete):
        errors.append(("/verdict", "'passes-with-findings' requires at least one finding and complete coverage"))
    if v == "incomplete" and complete:
        errors.append(("/verdict", "'incomplete' requires coverage.complete false"))
    return errors


def rule_stamps_are_times(rec):
    errors = []
    for parts in STAMP_FIELDS:
        if _seconds(_get(rec, parts)) is None:
            errors.append((ptr(parts), "is not a valid UTC time"))
    return errors


def rule_end_not_before_start(rec):
    span = _span(rec)
    if span is not None and span < 0:
        return [("/metrics/ended_at", "is earlier than started_at")]
    return []


def rule_wall_s_matches_stamps(rec):
    m, span = rec["metrics"], _span(rec)
    if not decimal.Decimal(str(m["wall_s"])).is_finite():  # json.load accepts NaN and Infinity
        return [("/metrics/wall_s", "is not a finite number")]
    if span is None or span < 0:
        return []  # reported by the two rules above
    allowed = max(WALL_TOLERANCE_S, WALL_TOLERANCE_REL * span)
    if abs(decimal.Decimal(str(m["wall_s"])) - span) > allowed:
        return [("/metrics/wall_s", f"differs from ended_at - started_at by more than {allowed} s")]
    return []


def rule_tokens_source(rec):
    m = rec["metrics"]
    toks = [m["tokens"]["input"], m["tokens"]["output"]]
    if m["tokens_source"] == "unavailable" and any(x is not None for x in toks):
        return [("/metrics/tokens", "must be null when tokens_source is 'unavailable'; never estimate")]
    if m["tokens_source"] == "runtime" and any(x is None for x in toks):
        return [("/metrics/tokens", "must be integers when tokens_source is 'runtime'")]
    return []


def rule_class_not_bare_word(rec):
    return [(ptr(("findings", i, "class")), "is a bare area word; name the defect mechanism")
            for i, f in enumerate(rec["findings"]) if f.get("class") in BARE_CLASS_WORDS]


def rule_no_credentials(rec):
    return [(ptr(path), f"contains a credential-shaped value ({name}); name file, line and class only")
            for path, s in _strings(rec) for name, rx in SECRET_PATTERNS if rx.search(s)]


def rule_no_diff_text(rec):
    return [(ptr(path), f"contains raw diff text ({name})")
            for path, s in _strings(rec) for name, rx in DIFF_PATTERNS if rx.search(s)]


RULES = (
    rule_unique_ids, rule_one_self_source, rule_at_most_two_rereviews, rule_source_reason,
    rule_report_paths_not_home, rule_finding_paths_relative, rule_file_level_line, rule_finding_source,
    rule_confirmed_p1_route, rule_fixed_in_not_base, rule_discarded_line_needs_path, rule_discarded_source,
    rule_uncommitted_fingerprint, rule_head_differs_from_base, rule_guide_commit, rule_guide_reason,
    rule_coverage_gaps, rule_verdict, rule_stamps_are_times, rule_end_not_before_start,
    rule_wall_s_matches_stamps, rule_tokens_source, rule_class_not_bare_word, rule_no_credentials,
    rule_no_diff_text,
)


def check_semantics(rec):
    """Rules JSON Schema cannot state. Assumes check_schema passed."""
    errors = []
    for rule in RULES:
        errors += rule(rec)
    return errors


def validate(rec, schema):
    errors = check_schema(rec, schema)
    if errors:
        return errors
    return check_semantics(rec)


# --- projection to the grader input ---------------------------------------------------------------

# --- command line ---------------------------------------------------------------------------------

def _parse(argv):
    """Return (record path, schema path) or None on a usage error."""
    args = list(argv)
    schema_path = DEFAULT_SCHEMA
    if "--schema" in args:
        i = args.index("--schema")
        if i + 1 >= len(args):
            return None
        schema_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1 or args[0].startswith("-"):
        return None
    return args[0], schema_path


def _load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv):
    parsed = _parse(argv)
    if parsed is None:
        print(USAGE, file=sys.stderr)
        return 2
    record_path, schema_path = parsed
    try:
        rec, schema = _load(record_path), _load(schema_path)
    except (OSError, ValueError) as exc:
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    errors = validate(rec, schema)
    if errors:
        for where, msg in errors:
            print(f"{where}: {msg}")
        return 1
    print("valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

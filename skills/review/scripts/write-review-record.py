#!/usr/bin/env python3
"""Validate one review record and write it where the review skill keeps records.

The rules are in ../references/tooling.md, "The review record". The helper
validates the record with validate_record.py and record.schema.json in this
directory. An invalid record is never written.

The file name is <UTC yyyymmddThhmmssZ>-<slug>.review.json, taken from the
record's created_at, so a rerun gives the same name. The directory is, in
this order:
  1. --location, when the caller names one;
  2. <main worktree>/.reviews/, when both checks of the Location rule hold:
     `git check-ignore -q .reviews/<name>` in the checkout, and the main
     worktree's root .gitignore byte-identical to the checkout's (a root
     .gitignore that is absent in both counts as identical);
  3. --fallback-dir otherwise, with the reason on stderr.
An explicit --checkout must be an existing directory; the helper checks it
before it applies these rules.
Before it writes, the helper checks in the checkout (--checkout, default the
current directory) that each finding's fixed_in is an ancestor of the
record's head_sha and not of its base_sha (`git merge-base --is-ancestor`).
--print-only runs no Git and does not check it.
The helper never overwrites a file and never follows a symbolic link at the
final path or at .reviews. It refuses a .reviews of another account or one
that group or others can write, creates a missing .reviews with mode 0700, and
writes the file with mode 0600. Git runs
without the global and system configuration and without inherited GIT_*
variables.

Usage:
    write-review-record.py --record RECORD.json --slug SLUG --fallback-dir DIR
                           [--checkout DIR] [--location DIR]
    write-review-record.py --record RECORD.json --print-only

--record - reads the record from stdin, for a request that forbids writing a
file even in the scratchpad.

Exit status:
    0  written (stdout: the path, alone) or, with --print-only, printed
    1  the record is invalid: it fails validation, is not JSON, holds NaN,
       Infinity or an unpaired surrogate escape, has a created_at with
       digits that are not ASCII, or has a fixed_in that the checkout does
       not show to be an ancestor of head_sha and not of base_sha
    2  usage error, a bad slug, an unreadable record, or a --checkout,
       --location or --fallback-dir that is not an existing directory
    3  permission denied at the chosen directory. In a command sandbox,
       rerun the same command outside it.
    4  an entry that is not a symbolic link already exists at the record
       path; it is left unchanged
    5  the destination is unsafe (a symbolic link at .reviews or at the
       record path, or a .reviews of another account or one that group or
       others can write), .reviews or the record file could not be created
       or opened, or the write failed
On a non-zero exit no record file is left, with one exception: when exit 5
reports a failed write and the helper cannot remove the partial file, the
message names that file. An empty .reviews that the helper created can
remain after exit 3 or 5.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

# Loading the validator must not write a bytecode cache beside it: a read-only
# request forbids every write, and the skill folder is not this run's to change.
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
VALIDATOR = HERE / "validate_record.py"
SCHEMA = HERE / "record.schema.json"

INVALID, USAGE, PERMISSION, EXISTS, UNSAFE = 1, 2, 3, 4, 5
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*", re.ASCII)
SLUG_MAX = 100
STAMP = re.compile(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z", re.ASCII)
RECORD_MAX_BYTES = 8 * 1024 * 1024
GITIGNORE_MAX_BYTES = 1024 * 1024
GIT_TIMEOUT_S = 20


class Failure(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


def say(message: str) -> None:
    print(f"write-review-record: {message}", file=sys.stderr)


# --- reading ----------------------------------------------------------------------------------

def read_regular(path: Path, limit: int) -> bytes:
    """Read a regular file of at most `limit` bytes. A FIFO or device is refused before any read."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(f"{path} is not a regular file")
        if info.st_size > limit:
            raise OSError(f"{path} is larger than {limit} bytes")
        with os.fdopen(os.dup(fd), "rb") as handle:
            data = handle.read(limit + 1)
    finally:
        os.close(fd)
    if len(data) > limit:
        raise OSError(f"{path} is larger than {limit} bytes")
    return data


def load_validator():
    spec = importlib.util.spec_from_file_location("review_record_validator", VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def checked_record(path: str) -> tuple[dict, bytes]:
    """Return the record and its canonical JSON text, or raise Failure."""
    try:
        if path == "-":
            raw = sys.stdin.buffer.read(RECORD_MAX_BYTES + 1)
            if len(raw) > RECORD_MAX_BYTES:
                raise OSError(f"stdin holds more than {RECORD_MAX_BYTES} bytes")
        else:
            raw = read_regular(Path(path), RECORD_MAX_BYTES)
    except OSError as exc:
        raise Failure(USAGE, f"cannot read the record: {exc}") from None
    try:
        record = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise Failure(INVALID, f"the record is not valid JSON ({type(exc).__name__}); nothing written") from None
    validator = load_validator()
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    errors = validator.validate(record, schema)
    if errors:
        lines = "\n".join(f"  {where}: {message}" for where, message in errors)
        raise Failure(INVALID, f"the record is invalid; nothing written:\n{lines}")
    try:
        text = json.dumps(record, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    except ValueError:
        raise Failure(INVALID, "the record holds NaN or Infinity; nothing written") from None
    try:
        data = text.encode("utf-8")
    except UnicodeEncodeError:  # json.loads accepts an escape such as "\ud800"; UTF-8 cannot hold it.
        raise Failure(INVALID, "the record holds an unpaired surrogate escape; nothing written") from None
    return record, data


def stamp(record: dict) -> str:
    """Return the file name's UTC stamp; created_at passed the schema pattern and the validator."""
    match = STAMP.fullmatch(record["created_at"])
    if not match:  # The schema's \d also accepts non-ASCII digits; a file name takes ASCII only.
        raise Failure(INVALID, "created_at must use ASCII digits; nothing written")
    y, mo, d, h, mi, s = match.groups()
    return f"{y}{mo}{d}T{h}{mi}{s}Z"


# --- choosing the directory -------------------------------------------------------------------

def git(cwd: Path, *args: str) -> subprocess.CompletedProcess:
    """Run git without the caller's GIT_* variables and without global or system configuration."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
               GIT_OPTIONAL_LOCKS="0")
    return subprocess.run(["git", "-c", "core.fsmonitor=false", *args], cwd=cwd, env=env,
                          stdin=subprocess.DEVNULL, capture_output=True, timeout=GIT_TIMEOUT_S, check=False)


def read_gitignore(worktree: Path) -> bytes | None:
    """Return the root .gitignore, or None when no entry exists at that path."""
    path = worktree / ".gitignore"
    try:
        return read_regular(path, GITIGNORE_MAX_BYTES)
    except FileNotFoundError:
        if os.path.lexists(path):  # A dangling symbolic link is not an absent file.
            raise
        return None


def main_worktree_reviews(checkout: Path, name: str) -> tuple[Path | None, str]:
    """Return (<main worktree>/.reviews, "") when both checks hold, else (None, reason)."""
    try:
        top = git(checkout, "rev-parse", "--show-toplevel")
        if top.returncode != 0:
            return None, f"{checkout} is not inside a Git work tree"
        root = Path(top.stdout.decode("utf-8", "surrogateescape").rstrip("\n"))
        listing = git(root, "worktree", "list", "--porcelain", "-z")
        if listing.returncode != 0:
            return None, "git worktree list failed"
        first = listing.stdout.decode("utf-8", "surrogateescape").split("\0\0", 1)[0].split("\0")
        if "bare" in first[1:]:
            return None, "the first worktree entry is bare, so no main worktree exists"
        if not first[0].startswith("worktree "):
            return None, "git worktree list printed no worktree entry"
        main = Path(first[0][len("worktree "):])
        ignored = git(root, "check-ignore", "-q", "--", f".reviews/{name}")
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"git did not run ({type(exc).__name__})"
    if ignored.returncode == 1:
        return None, f".reviews/{name} is not ignored in {root}"
    if ignored.returncode != 0:
        return None, f"git check-ignore failed with status {ignored.returncode}"
    try:
        same = read_gitignore(main) == read_gitignore(root)
    except OSError as exc:
        return None, f"cannot compare the two .gitignore files: {exc}"
    if not same:
        return None, f"the .gitignore of the main worktree {main} differs from the one in {root}"
    return main / ".reviews", ""


def is_ancestor(checkout: Path, sha: str, of: str, name: str) -> tuple[bool | None, str]:
    """(True or False, "") when git answers whether sha is an ancestor of `of`, else (None, reason)."""
    try:
        done = git(checkout, "merge-base", "--is-ancestor", sha, of)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"cannot check fixed_in {sha} against {name} in {checkout}: git did not run ({type(exc).__name__})"
    if done.returncode in (0, 1):
        return done.returncode == 0, ""
    detail = done.stderr.decode("utf-8", "replace").strip().splitlines()
    return None, (f"cannot check fixed_in {sha} against {name} in {checkout}: "
                  f"git exited {done.returncode}{': ' + detail[0] if detail else ''}")


def check_fixed_in(record: dict, checkout: Path) -> None:
    """Refuse a fixed_in that is not an ancestor of head_sha, or that base_sha already contains, in the
    checkout. The schema pattern makes the values full hexadecimal SHAs, so none can be read as a Git option."""
    target, errors = record["target"], []
    for i, finding in enumerate(record["findings"]):
        sha = finding.get("fixed_in")
        if sha is None:
            continue
        where = f"/findings/{i}/fixed_in: "
        in_head, reason = is_ancestor(checkout, sha, target["head_sha"], "head_sha")
        if in_head is None:
            errors.append(where + reason)
            continue
        if not in_head:
            errors.append(f"{where}fixed_in {sha} is not an ancestor of head_sha in {checkout}")
            continue
        in_base, reason = is_ancestor(checkout, sha, target["base_sha"], "base_sha")
        if in_base is None:
            errors.append(where + reason)
        elif in_base:
            errors.append(f"{where}fixed_in {sha} is already in base_sha in {checkout}; "
                          "name the commit that fixed the finding after the review")
    if errors:
        lines = "\n".join(f"  {error}" for error in errors)
        raise Failure(INVALID, f"the record is invalid; nothing written:\n{lines}")


# --- writing ----------------------------------------------------------------------------------

def permission_failure(path: Path, exc: OSError) -> Failure:
    return Failure(PERMISSION, f"cannot write {path}: {exc.strerror}. Nothing was written. If a command "
                               "sandbox runs this helper, rerun the same command outside the sandbox.")


def open_reviews_dir(path: Path) -> int:
    """Create .reviews owner-only if needed; refuse a symbolic link, another owner, or a shared write bit."""
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    except PermissionError as exc:
        raise permission_failure(path, exc) from None
    except OSError as exc:
        raise Failure(UNSAFE, f"cannot create {path}: {exc.strerror}; nothing written") from None
    if os.path.islink(path):
        raise Failure(UNSAFE, f"{path} is a symbolic link; refusing to follow it; nothing written")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except PermissionError as exc:
        raise permission_failure(path, exc) from None
    except OSError as exc:
        raise Failure(UNSAFE, f"cannot open {path} as a directory: {exc.strerror}; nothing written") from None
    info = os.fstat(fd)
    if info.st_uid != os.geteuid() or info.st_mode & 0o022:
        os.close(fd)
        raise Failure(UNSAFE, f"{path} belongs to another account or others can write it; nothing written")
    return fd


def open_named_dir(path: Path) -> int:
    try:
        return os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    except PermissionError as exc:
        raise permission_failure(path, exc) from None
    except OSError as exc:
        raise Failure(USAGE, f"{path} is not an existing directory ({exc.strerror}); nothing written") from None


def write_new(dir_fd: int, directory: Path, name: str, data: bytes) -> Path:
    path = directory / name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, 0o600, dir_fd=dir_fd)
    except FileExistsError:
        try:
            existing = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except OSError:
            existing = None
        if existing is not None and stat.S_ISLNK(existing.st_mode):
            raise Failure(UNSAFE, f"{path} is a symbolic link; refusing to follow it; nothing written") from None
        raise Failure(EXISTS, f"{path} already exists; left unchanged; nothing written") from None
    except PermissionError as exc:
        raise permission_failure(directory, exc) from None
    except OSError as exc:
        raise Failure(UNSAFE, f"cannot create {path}: {exc.strerror}; nothing written") from None
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
    except OSError as exc:
        try:
            os.unlink(name, dir_fd=dir_fd)
        except OSError:
            raise Failure(UNSAFE, f"writing {path} failed: {exc.strerror}; remove the partial file") from None
        raise Failure(UNSAFE, f"writing {path} failed: {exc.strerror}; the partial file was removed") from None
    return path


def write_record(args: argparse.Namespace, data: bytes, name: str) -> Path:
    if args.location:
        directory = Path(args.location).absolute()
        dir_fd = open_named_dir(directory)
    else:
        reviews, reason = main_worktree_reviews(Path(args.checkout or ".").absolute(), name)
        if reviews is not None:
            directory, dir_fd = reviews, open_reviews_dir(reviews)
        else:
            directory = Path(args.fallback_dir).absolute()
            say(f"writing to the fallback directory {directory}: {reason}")
            dir_fd = open_named_dir(directory)
    try:
        return write_new(dir_fd, directory, name, data)
    finally:
        os.close(dir_fd)


# --- command line -----------------------------------------------------------------------------

def parse(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="write-review-record.py", allow_abbrev=False,
                                     description="Validate a review record and write it.")
    parser.add_argument("--record", required=True, help="the record JSON, kept in the scratchpad; - reads stdin")
    parser.add_argument("--slug", help="the target slug: lowercase letters, digits and hyphens")
    parser.add_argument("--fallback-dir", help="the directory used when .reviews/ does not qualify")
    parser.add_argument("--checkout", help="the reviewed checkout (default: the current directory)")
    parser.add_argument("--location", help="a directory the caller named; it wins over .reviews/")
    parser.add_argument("--print-only", action="store_true",
                        help="a read-only request: validate and print a fenced json block; write nothing")
    args = parser.parse_args(argv)
    if args.print_only:
        extra = [flag for flag, value in (("--slug", args.slug), ("--fallback-dir", args.fallback_dir),
                                          ("--location", args.location), ("--checkout", args.checkout))
                 if value is not None]
        if extra:
            parser.error(f"--print-only takes only --record, not {' '.join(extra)}")
    elif args.slug is None or args.fallback_dir is None:
        parser.error("--slug and --fallback-dir are required unless --print-only is given")
    elif len(args.slug) > SLUG_MAX or not SLUG.fullmatch(args.slug):
        parser.error(f"--slug must be 1 to {SLUG_MAX} lowercase letters and digits, with single hyphens "
                     "between them")
    elif args.checkout is not None and not os.path.isdir(args.checkout):
        # Checked here, before the Location rule: otherwise git cannot start and the record falls back.
        parser.error(f"--checkout {args.checkout} is not an existing directory")
    return args


def main(argv: list[str]) -> int:
    args = parse(argv)
    try:
        record, data = checked_record(args.record)
        when = stamp(record)  # Before --print-only, so both modes check created_at.
        if args.print_only:
            # A backtick occurs only inside JSON strings; escaping it keeps the fence closed.
            sys.stdout.write("```json\n" + data.decode("utf-8").replace("`", "\\u0060") + "```\n")
            return 0
        check_fixed_in(record, Path(args.checkout or ".").absolute())
        path = write_record(args, data, f"{when}-{args.slug}.review.json")
    except Failure as failure:
        say(str(failure))
        return failure.status
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

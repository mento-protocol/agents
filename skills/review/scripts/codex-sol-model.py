#!/usr/bin/env python3
"""Print the newest Codex Sol model that the local model catalog lists.

Codex keeps the account's model catalog in $CODEX_HOME/models_cache.json
(CODEX_HOME defaults to ~/.codex). A candidate is a model whose visibility is
"list" and whose slug is exactly gpt-<version>-sol, where <version> is one or
more dot-separated decimal numbers of at most 9 digits each. The highest
version wins by numeric comparison, so 6.10 is newer than 6.9 and 6.1 is newer
than 6.

The lookup never reads the Codex default model or config.toml, so a model
chosen for interactive sessions does not change the result. On any failure it
prints nothing on stdout, one line on stderr, and exits 2. The caller must
then not run Codex: neither with its default model nor with a guessed name.

Usage:
    codex-sol-model.py [--catalog PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# At most 9 digits per number: a longer one is no real version, and int()
# refuses a string of more than 4300 digits.
SOL_SLUG = re.compile(r"gpt-(\d{1,9}(?:\.\d{1,9})*)-sol", re.ASCII)
FAILURE_STATUS = 2


def catalog_path(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    codex_home = os.environ.get("CODEX_HOME")
    root = Path(codex_home).expanduser() if codex_home else Path.home() / ".codex"
    return root / "models_cache.json"


def newest_sol(models: list) -> str | None:
    """Return the listed Sol slug with the highest version, or None."""
    best: tuple[tuple[int, ...], str] | None = None
    for model in models:
        if not isinstance(model, dict) or model.get("visibility") != "list":
            continue
        slug = model.get("slug")
        match = SOL_SLUG.fullmatch(slug) if isinstance(slug, str) else None
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("."))
        if best is None or version > best[0]:
            best = (version, slug)
    return best[1] if best else None


def fail(path: Path, cause: str) -> None:
    print(
        f"codex-sol-model: {path}: {cause}; do not run Codex with its default model or a guessed name",
        file=sys.stderr,
    )
    sys.exit(FAILURE_STATUS)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--catalog", help="model catalog (default: $CODEX_HOME/models_cache.json)")
    explicit = parser.parse_args().catalog
    try:
        path = catalog_path(explicit)
    except RuntimeError as exc:  # no home directory, for example for a ~user path
        fail(Path(explicit or os.environ.get("CODEX_HOME") or "~/.codex"), f"cannot resolve the catalog path ({exc})")
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        fail(path, f"cannot read the catalog ({exc.strerror or exc})")
    except (ValueError, RecursionError) as exc:  # RecursionError: nesting too deep to parse
        fail(path, f"the catalog is not valid JSON ({exc})")
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, list):
        fail(path, 'the catalog has no "models" list')
    slug = newest_sol(models)
    if slug is None:
        fail(path, 'the catalog lists no visible gpt-<version>-sol model')
    print(slug)


if __name__ == "__main__":
    main()

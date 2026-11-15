"""Fails unless pyproject.toml sets the coverage floor and the package it counts.

python.yml and `task shared:python:test` run it before pytest, since pytest-cov holds a
floor only when coverage's config sets one, and passes quietly when none is set:

    python shared/test/python/coverage_floor.py [path/to/pyproject.toml]

The floor is `fail_under` under `[tool.coverage.report]`, above zero; the package is
`source` under `[tool.coverage.run]`. It prints both when they are set.
"""

import sys
import tomllib
from pathlib import Path
from typing import Any


def table(config: dict[str, Any], *keys: str) -> dict[str, Any]:
    """The nested table at keys, or an empty one when any part is missing."""
    found: Any = config
    for key in keys:
        found = found.get(key) if isinstance(found, dict) else None
    return found if isinstance(found, dict) else {}


def main(argv: list[str]) -> int:
    path = Path(argv[1] if len(argv) > 1 else "pyproject.toml")
    if not path.is_file():
        print(f"No {path}, so there is no coverage floor.", file=sys.stderr)
        return 1
    with path.open("rb") as file:
        config = tomllib.load(file)
    floor = table(config, "tool", "coverage", "report").get("fail_under")
    source = table(config, "tool", "coverage", "run").get("source")
    packages = [s for s in source if isinstance(s, str) and s] if isinstance(source, list) else []
    problems = []
    if isinstance(floor, bool) or not isinstance(floor, int | float) or floor <= 0:
        problems.append("fail_under, above zero, under [tool.coverage.report]: the coverage floor")
    if not packages or len(packages) != len(source or []):
        problems.append('source under [tool.coverage.run]: the packages counted, such as ["example"]')
    if problems:
        print(f"{path} must set " + "; and ".join(problems) + ".", file=sys.stderr)
        return 1
    print(f"Coverage floor: {floor}% of the lines in {', '.join(packages)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

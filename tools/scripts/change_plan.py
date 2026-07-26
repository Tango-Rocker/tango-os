#!/usr/bin/env python3
"""Plan EngineOS package work from committed Git ranges."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


ZERO_OID = "0" * 40


def run_git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def package_for_path(path: str, known: set[str]) -> str | None:
    if path.startswith("packages/"):
        package = path.split("/", 2)[1]
        return package if package in known else None
    rules = (
        (("apps/chatgpt-wpe/",), "engineos-chatgpt"),
		(("mux/",), "engineos-mux"),
        (("shell/",), "engineos-shell"),
        (("engines/quakespasm/",), "engineos-quakespasm"),
        (("tools/level-agent/",), "engineos-level-agent"),
        (("tools/game/",), "engineos-quakespasm"),
        (("archiso/",), "engineos-config"),
        (("tools/", "docs/", ".agents/", ".codex/"), "engineos-tools"),
    )
    if path in {"AGENTS.md", "agentd.md", "BACKLOG.md", "CURRENT_STATUS.md", "ROADMAP.md"}:
        return "engineos-tools"
    for prefixes, package in rules:
        if path.startswith(prefixes) and package in known:
            return package
    return None


def package_dependencies(root: Path, package: str, known: set[str]) -> set[str]:
    text = (root / "packages" / package / "PKGBUILD").read_text()
    match = re.search(r"(?ms)^depends=\((.*?)^\)", text)
    if not match:
        match = re.search(r"(?m)^depends=\(([^)]*)\)", text)
    if not match:
        return set()
    values = re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))
    return {re.split(r"[<>=]", value, maxsplit=1)[0] for value in values} & known


def dependency_closure(root: Path, selected: set[str], known: set[str]) -> set[str]:
    closure = set(selected)
    pending = list(selected)
    while pending:
        package = pending.pop()
        for dependency in package_dependencies(root, package, known):
            if dependency not in closure:
                closure.add(dependency)
                pending.append(dependency)
    return closure


def dependency_order(root: Path, packages: set[str], known: set[str]) -> list[str]:
    ordered: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(package: str) -> None:
        if package in visited:
            return
        if package in visiting:
            raise RuntimeError(f"local package dependency cycle includes {package}")
        visiting.add(package)
        for dependency in sorted(package_dependencies(root, package, known) & packages):
            visit(dependency)
        visiting.remove(package)
        visited.add(package)
        ordered.append(package)

    for package in sorted(packages):
        visit(package)
    return ordered


def default_base(root: Path, local_oid: str) -> str:
    candidates = ["@{upstream}", "origin/main", "main"]
    for candidate in candidates:
        resolved = run_git(root, "rev-parse", "--verify", candidate, check=False).strip()
        if not resolved:
            continue
        merge_base = run_git(root, "merge-base", local_oid, resolved, check=False).strip()
        if merge_base:
            return merge_base
    return run_git(root, "hash-object", "-t", "tree", "/dev/null").strip()


def changed_files(root: Path, ranges: list[tuple[str, str]]) -> set[str]:
    paths: set[str] = set()
    for old_oid, new_oid in ranges:
        base = default_base(root, new_oid) if old_oid == ZERO_OID else old_oid
        output = run_git(root, "diff", "--name-only", f"{base}..{new_oid}", "--")
        paths.update(line for line in output.splitlines() if line)
    return paths


def dirty_paths(root: Path) -> set[str]:
    paths: set[str] = set()
    commands = (
        ("diff", "--name-only", "--no-renames", "-z", "--"),
        ("diff", "--cached", "--name-only", "--no-renames", "-z", "--"),
        ("ls-files", "--others", "--exclude-standard", "-z"),
    )
    for command in commands:
        output = run_git(root, *command)
        paths.update(path for path in output.split("\0") if path)
    return paths


def tests_for(packages: set[str]) -> list[str]:
    tests: list[str] = []
    mapping = {
        "engineos-tools": "agent",
        "engineos-shell": "shell-actions",
		"engineos-mux": "mux",
        "engineos-config": "app",
        "engineos-chatgpt": "app",
        "engineos-level-agent": "level-agent",
        "engineos-quakespasm": "engine",
        "engineos-dgen": "level-agent",
    }
    for package in sorted(packages):
        test = mapping.get(package)
        if test and test not in tests:
            tests.append(test)
    return tests or ["smoke"]


def make_plan(root: Path, ranges: list[tuple[str, str]], check_dirty: bool) -> dict[str, object]:
    known = {path.parent.name for path in (root / "packages").glob("*/PKGBUILD")}
    paths = changed_files(root, ranges)
    direct = {package_for_path(path, known) for path in paths}
    direct.discard(None)
    packages = dependency_closure(root, direct, known)
    if not packages:
        raise RuntimeError("the committed range does not select an EngineOS package")
    relevant_dirty = sorted(
        path for path in dirty_paths(root) if package_for_path(path, known) in packages
    )
    if check_dirty and relevant_dirty:
        raise RuntimeError(
            "relevant working-tree files differ from the pushed commits: "
            + ", ".join(relevant_dirty)
        )
    return {
        "schema": "engineos-change-plan/v1",
        "ranges": [{"old": old, "new": new} for old, new in ranges],
        "files": sorted(paths),
        "direct_packages": sorted(direct),
        "packages": dependency_order(root, packages, known),
        "tests": tests_for(packages),
        "dirty_paths": relevant_dirty,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--range", action="append", default=[])
    parser.add_argument("--ref-update", nargs=4, action="append", default=[])
    parser.add_argument("--check-dirty", action="store_true")
    parser.add_argument("--field", choices=("packages", "tests", "files"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ranges: list[tuple[str, str]] = []
    for value in args.range:
        if ".." not in value:
            raise RuntimeError(f"range must be OLD..NEW: {value}")
        ranges.append(tuple(value.split("..", 1)))
    for _local_ref, local_oid, _remote_ref, remote_oid in args.ref_update:
        if local_oid != ZERO_OID:
            ranges.append((remote_oid, local_oid))
    if not ranges:
        raise RuntimeError("at least one --range or branch --ref-update is required")
    plan = make_plan(args.root.resolve(), ranges, args.check_dirty)
    if args.field:
        print("\n".join(plan[args.field]))
    else:
        json.dump(plan, sys.stdout, indent=2)
        print()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"engineos change plan: {error}", file=sys.stderr)
        raise SystemExit(1)

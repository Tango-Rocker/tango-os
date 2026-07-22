#!/usr/bin/env python3
"""Bounded EngineOS session supervisor and token-usage ledger."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any


SCHEMA = "engineos-agent-supervisor-v1"
METRICS_SCHEMA = "engineos-supervisor-token-metrics-v1"
TOKEN_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def append_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    path.chmod(0o600)


def read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def within_root(cwd: str | None, root: Path) -> bool:
    if not cwd:
        return False
    try:
        candidate = Path(cwd).resolve()
        return candidate == root or root in candidate.parents
    except OSError:
        return False


def session_key(session_id: str) -> str:
    return hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:16]


def load_config(root: Path, override: str | None) -> tuple[dict[str, Any], Path]:
    path = Path(override).expanduser().resolve() if override else root / ".agents/supervisor.toml"
    try:
        with path.open("rb") as handle:
            config = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeError(f"cannot read supervisor config {path}: {exc}") from exc
    if config.get("schema") != SCHEMA:
        raise RuntimeError(f"supervisor config schema must be {SCHEMA}")
    return config, path


def state_dir(root: Path, config: dict[str, Any]) -> Path:
    configured = Path(str(config.get("state_dir", ".agent-insights/out/supervisor")))
    return configured if configured.is_absolute() else root / configured


def codex_home(config: dict[str, Any]) -> Path:
    configured = config.get("codex_home") or os.environ.get("CODEX_HOME") or Path.home() / ".codex"
    return Path(configured).expanduser().resolve()


def scan_sessions(root: Path, config: dict[str, Any]) -> list[dict[str, Any]]:
    home = codex_home(config)
    sessions_root = home / "sessions"
    if not sessions_root.is_dir():
        raise RuntimeError(f"Codex sessions directory is missing: {sessions_root}")
    now = utc_now()
    quiet_seconds = int(config.get("quiet_seconds", 300))
    since_days = int(config.get("since_days", 30))
    cutoff = now - dt.timedelta(days=since_days)
    records: list[dict[str, Any]] = []
    for path in sessions_root.rglob("*.jsonl"):
        modified = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc)
        if modified < cutoff or (now - modified).total_seconds() < quiet_seconds:
            continue
        session_id = ""
        started: dt.datetime | None = None
        cwd: str | None = None
        model = "unknown"
        usage: dict[str, int] | None = None
        compactions = 0
        try:
            with path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    kind = item.get("type")
                    payload = item.get("payload")
                    if kind == "session_meta" and isinstance(payload, dict):
                        session_id = str(payload.get("id") or payload.get("session_id") or "")
                        cwd = payload.get("cwd")
                        started = parse_time(payload.get("timestamp"))
                    elif kind == "turn_context" and isinstance(payload, dict) and payload.get("model"):
                        model = str(payload["model"])
                    elif kind == "compacted":
                        compactions += 1
                    elif kind == "event_msg" and isinstance(payload, dict) and payload.get("type") == "token_count":
                        info = payload.get("info")
                        total = info.get("total_token_usage") if isinstance(info, dict) else None
                        if isinstance(total, dict):
                            usage = {field: int(total.get(field, 0) or 0) for field in TOKEN_FIELDS}
        except OSError as exc:
            raise RuntimeError(f"cannot read Codex session {path}: {exc}") from exc
        if not session_id or not within_root(cwd, root):
            continue
        usage = usage or {field: 0 for field in TOKEN_FIELDS}
        usage["uncached_input_tokens"] = max(0, usage["input_tokens"] - usage["cached_input_tokens"])
        records.append(
            {
                "id": session_id,
                "key": session_key(session_id),
                "started_at": (started or modified).isoformat(),
                "modified_at": modified.isoformat(),
                "model": model,
                "compactions": compactions,
                **usage,
            }
        )
    return sorted(records, key=lambda item: (item["started_at"], item["key"]))


def percentile(values: list[int], fraction: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int((len(ordered) - 1) * fraction)))
    return ordered[index]


def aggregate(records: list[dict[str, Any]]) -> dict[str, Any]:
    fields = (*TOKEN_FIELDS, "uncached_input_tokens", "compactions")
    totals = {field: sum(int(item.get(field, 0)) for item in records) for field in fields}
    averages = {
        field: round(totals[field] / len(records)) if records else 0
        for field in fields
    }
    medians = {
        field: round(statistics.median([int(item.get(field, 0)) for item in records])) if records else 0
        for field in fields
    }
    return {
        "sessions": len(records),
        "totals": totals,
        "averages": averages,
        "medians": medians,
        "p90_total_tokens": percentile([int(item["total_tokens"]) for item in records], 0.90),
        "models": sorted({str(item["model"]) for item in records}),
    }


def percent_delta(current: int, previous: int) -> float | None:
    if previous <= 0:
        return None
    return round((current - previous) * 100.0 / previous, 2)


def build_metrics(root: Path, config: dict[str, Any], records: list[dict[str, Any]], state: dict[str, Any]) -> dict[str, Any]:
    budget = config.get("budget", {})
    window_size = int(budget.get("recent_sessions", 5))
    recent_records = records[-window_size:]
    previous_records = records[-2 * window_size : -window_size]
    recent = aggregate(recent_records)
    previous = aggregate(previous_records)
    initialized = parse_time(state.get("initialized_at"))
    post_baseline = [item for item in records if initialized and parse_time(item["started_at"]) and parse_time(item["started_at"]) >= initialized]
    tracked = {
        "total_tokens": int(budget.get("max_total_tokens_per_session", 0)),
        "uncached_input_tokens": int(budget.get("max_uncached_input_tokens_per_session", 0)),
        "output_tokens": int(budget.get("max_output_tokens_per_session", 0)),
        "compactions": int(budget.get("max_compactions_per_session", 0)),
    }
    violations = []
    for field, limit in tracked.items():
        value = int(recent["averages"].get(field, 0))
        if limit > 0 and value > limit:
            violations.append({"field": field, "average": value, "limit": limit})
    comparison_fields = ("total_tokens", "uncached_input_tokens", "output_tokens", "compactions")
    return {
        "schema": METRICS_SCHEMA,
        "generated_at": utc_now().isoformat(),
        "project": root.name,
        "window_size": window_size,
        "all": aggregate(records),
        "previous_window": previous,
        "recent_window": recent,
        "recent_vs_previous_percent": {
            field: percent_delta(recent["averages"][field], previous["averages"][field])
            for field in comparison_fields
        },
        "post_baseline": aggregate(post_baseline),
        "post_baseline_ready": len(post_baseline) >= window_size,
        "budget_status": "warn" if violations else "pass",
        "budget_violations": violations,
        "reviewer_tokens_used": reviewer_tokens(root, state_dir(root, config)),
        "privacy": "metadata-only; session identifiers are hashed and prompts/responses are omitted",
        "pricing": "not estimated; configure external model pricing before converting tokens to currency",
    }


def reviewer_tokens(root: Path, directory: Path) -> int:
    total = 0
    pattern = re.compile(r"tokens used\s*\n\s*([0-9][0-9,]*)", re.IGNORECASE)
    archives = {root / ".agent-insights/archive", directory / "archive"}
    for archive in archives:
        if not archive.is_dir():
            continue
        for path in archive.glob("**/analysis/**/codex-output.txt"):
            try:
                matches = pattern.findall(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            if matches:
                total += int(matches[-1].replace(",", ""))
    return total


def read_seen(path: Path) -> set[str]:
    try:
        return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}
    except OSError:
        return set()


def write_seen(path: Path, ids: set[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{item}\n" for item in sorted(ids)), encoding="utf-8")
    path.chmod(0o600)


def record_metrics(root: Path, config: dict[str, Any], records: list[dict[str, Any]], state: dict[str, Any], *, baseline: bool = False) -> dict[str, Any]:
    directory = state_dir(root, config)
    metrics = build_metrics(root, config, records, state)
    latest = directory / "token-metrics.json"
    prior = read_json(latest, {})
    write_json(latest, metrics)
    if baseline:
        write_json(directory / "token-baseline.json", metrics)
    fingerprint = json.dumps(metrics["all"], sort_keys=True)
    prior_fingerprint = json.dumps(prior.get("all", {}), sort_keys=True) if isinstance(prior, dict) else ""
    if baseline or fingerprint != prior_fingerprint:
        append_json(directory / "token-history.jsonl", metrics)
    return metrics


def extractor_path(config: dict[str, Any]) -> str:
    configured = os.environ.get("ENGINEOS_CODEX_INSIGHTS_BIN") or config.get("extractor") or "codex-insights"
    resolved = shutil.which(str(configured))
    if not resolved:
        raise RuntimeError(f"codex-insights is unavailable: {configured}")
    return resolved


def state_paths(root: Path, config: dict[str, Any]) -> dict[str, Path]:
    directory = state_dir(root, config)
    return {
        "directory": directory,
        "state": directory / "state.json",
        "seen": directory / "seen.txt",
        "log": directory / "last-run.log",
        "report": root / str(config.get("report_name", ".agent-insights/out/supervisor/latest-report.md")),
    }


def initialize(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    paths = state_paths(root, config)
    if paths["state"].exists():
        raise RuntimeError(f"supervisor is already initialized: {paths['state']}")
    paths["directory"].mkdir(parents=True, exist_ok=True)
    paths["directory"].chmod(0o700)
    records = scan_sessions(root, config)
    write_seen(paths["seen"], {item["id"] for item in records})
    now = utc_now().isoformat()
    state = {
        "schema": SCHEMA,
        "initialized_at": now,
        "baseline_sessions": len(records),
        "processed_after_baseline": 0,
        "review_runs": 0,
        "last_run_at": now,
        "last_result": "baseline-initialized",
        "last_error": None,
    }
    write_json(paths["state"], state)
    metrics = record_metrics(root, config, records, state, baseline=True)
    return {"result": "baseline-initialized", "state": state, "metrics": metrics}


def run_supervisor(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    paths = state_paths(root, config)
    if not paths["state"].exists():
        return initialize(root, config)
    state = read_json(paths["state"], {})
    if state.get("schema") != SCHEMA:
        raise RuntimeError(f"invalid supervisor state: {paths['state']}")
    records = scan_sessions(root, config)
    metrics = record_metrics(root, config, records, state)
    extractor = extractor_path(config)
    seen_before = read_seen(paths["seen"])
    finished_ids = {item["id"] for item in records}
    pending = finished_ids - seen_before
    now = utc_now().isoformat()
    if not pending:
        state.update({"last_run_at": now, "last_result": "no-new-sessions", "last_error": None})
        write_json(paths["state"], state)
        return {"result": "no-new-sessions", "pending_before": 0, "state": state, "metrics": metrics}
    report_mtime = paths["report"].stat().st_mtime_ns if paths["report"].exists() else 0
    reviewer_before = reviewer_tokens(root, paths["directory"])
    command = [
        extractor,
        "--out-dir",
        str(paths["directory"]),
        "watch",
        "--codex-home",
        str(codex_home(config)),
        "--since-days",
        str(int(config.get("since_days", 30))),
        "--project",
        str(config.get("project", root.name)),
        "--model",
        str(config.get("model", "gpt-5.6-luna")),
        "--reasoning-effort",
        str(config.get("reasoning_effort", "low")),
        "--seen-file",
        str(paths["seen"]),
        "--quiet-seconds",
        str(int(config.get("quiet_seconds", 300))),
        "--trigger-every",
        str(int(config.get("trigger_every", 5))),
        "--chunk-lines",
        str(int(config.get("chunk_lines", 160))),
        "--max-chunks",
        str(int(config.get("max_chunks", 1))),
        "--report-name",
        str(config.get("report_name", ".agent-insights/out/supervisor/latest-report.md")),
        "--no-archive-raw",
        "--once",
    ]
    completed = subprocess.run(
        command,
        cwd=root,
        env={**os.environ, "HOME": str(Path.home())},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    paths["log"].write_text(completed.stdout, encoding="utf-8")
    paths["log"].chmod(0o600)
    if completed.returncode:
        state.update(
            {
                "last_run_at": now,
                "last_result": "failed",
                "last_error": f"codex-insights exited {completed.returncode}; see {paths['log']}",
            }
        )
        write_json(paths["state"], state)
        raise RuntimeError(state["last_error"])
    seen_after = read_seen(paths["seen"])
    processed = len(seen_after - seen_before)
    report_changed = paths["report"].exists() and paths["report"].stat().st_mtime_ns != report_mtime
    reviewer_after = reviewer_tokens(root, paths["directory"])
    state.update(
        {
            "last_run_at": now,
            "last_result": "review-generated" if report_changed else "sessions-archived",
            "last_error": None,
            "processed_after_baseline": int(state.get("processed_after_baseline", 0)) + processed,
            "review_runs": int(state.get("review_runs", 0)) + (1 if report_changed else 0),
            "last_processed": processed,
            "last_reviewer_tokens": reviewer_after - reviewer_before,
        }
    )
    write_json(paths["state"], state)
    metrics = record_metrics(root, config, records, state)
    return {
        "result": state["last_result"],
        "pending_before": len(pending),
        "processed": processed,
        "report_changed": report_changed,
        "reviewer_tokens_used": reviewer_after - reviewer_before,
        "state": state,
        "metrics": metrics,
    }


def systemd_status() -> dict[str, str]:
    result = {}
    for action in ("is-enabled", "is-active"):
        try:
            completed = subprocess.run(
                ["systemctl", "--user", action, "engineos-agent-supervisor.timer"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            result[action.replace("is-", "")] = completed.stdout.strip() or "unknown"
        except OSError:
            result[action.replace("is-", "")] = "unavailable"
    return result


def supervisor_status(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    paths = state_paths(root, config)
    state = read_json(paths["state"], None)
    metrics = read_json(paths["directory"] / "token-metrics.json", None)
    return {
        "schema": SCHEMA,
        "configured": True,
        "initialized": isinstance(state, dict),
        "state": state,
        "metrics": metrics,
        "timer": systemd_status(),
        "paths": {
            "state": str(paths["state"]),
            "metrics": str(paths["directory"] / "token-metrics.json"),
            "report": str(paths["report"]),
            "log": str(paths["log"]),
        },
    }


def print_human(result: dict[str, Any]) -> None:
    state = result.get("state") or {}
    metrics = result.get("metrics") or {}
    print(f"result={result.get('result', state.get('last_result', 'status'))}")
    recent = metrics.get("recent_window", {}).get("averages", {})
    print(f"baseline_sessions={state.get('baseline_sessions', 0)}")
    print(f"processed_after_baseline={state.get('processed_after_baseline', 0)}")
    print(f"review_runs={state.get('review_runs', 0)}")
    print(f"recent_average_total_tokens={recent.get('total_tokens', 0)}")
    print(f"recent_average_uncached_input_tokens={recent.get('uncached_input_tokens', 0)}")
    print(f"reviewer_tokens_used={metrics.get('reviewer_tokens_used', 0)}")
    print(f"budget_status={metrics.get('budget_status', 'unknown')}")


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(prog="eos-agent supervisor")
    cli.add_argument("command", choices=("init", "run", "status"))
    cli.add_argument("--root", default=os.environ.get("ENGINEOS_SUPERVISOR_ROOT") or os.environ.get("ENGINEOS_ROOT") or os.getcwd())
    cli.add_argument("--config")
    cli.add_argument("--json", action="store_true")
    return cli


def main() -> int:
    os.umask(0o077)
    args = parser().parse_args()
    root = Path(args.root).expanduser().resolve()
    if not (root / ".git").exists():
        raise RuntimeError(f"supervisor root is not a Git checkout: {root}")
    config, _path = load_config(root, args.config)
    if args.command == "init":
        result = initialize(root, config)
    elif args.command == "run":
        result = run_supervisor(root, config)
    else:
        result = supervisor_status(root, config)
    if args.json:
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    else:
        print_human(result)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"eos-agent supervisor: {exc}", file=sys.stderr)
        raise SystemExit(1)

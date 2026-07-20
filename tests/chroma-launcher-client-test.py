#!/usr/bin/env python3
"""Contract proof for reconnecting the Chroma Qt adapter to worker state."""

import importlib.util
import tempfile
from dataclasses import dataclass
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "tools/engineos/chroma-launcher-client"


class Item:
    def __init__(self, text: str = "") -> None:
        self.text = text

    def setText(self, text: str) -> None:
        self.text = text


class Table:
    def __init__(self) -> None:
        self.rows: list[list[Item]] = []

    def setRowCount(self, count: int) -> None:
        assert count == 0
        self.rows.clear()

    def item(self, row: int, column: int) -> Item:
        return self.rows[row][column]


class Label:
    def __init__(self) -> None:
        self.text = ""

    def setText(self, text: str) -> None:
        self.text = text


@dataclass
class Job:
    job_id: int
    settings: dict
    prompt: str
    negative_prompt: str
    status: str = "queued"
    row: int = -1
    log_path: Path | None = None
    output_pattern: Path | None = None
    start_time: float | None = None
    attempt: int = 0
    error: str = ""


class Launcher:
    def __init__(self) -> None:
        self.queue_table = Table()
        self.status_label = Label()
        self.jobs: list[Job] = []
        self.current_job: Job | None = None
        self.panel: list[str] = []
        self.progress_updates = 0

    def _add_job_row(self, job: Job) -> None:
        job.row = len(self.queue_table.rows)
        self.queue_table.rows.append(
            [
                Item(job.status),
                Item(),
                Item(),
                Item(),
                Item(),
                Item(str(job.log_path) if job.log_path else ""),
                Item(str(job.output_pattern) if job.output_pattern else ""),
            ]
        )

    def _append_panel(self, text: str) -> None:
        self.panel.append(text)

    def _update_progress_bar(self) -> None:
        self.progress_updates += 1


def main() -> int:
    loader = SourceFileLoader("chroma_client_test", str(CLIENT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None and spec.loader is not None
    client = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client)

    with tempfile.TemporaryDirectory(prefix="engineos-chroma-client-") as raw:
        root = Path(raw)
        log_dir = root / "logs"
        log_dir.mkdir()
        server_log = log_dir / "sd-server-7862.log"
        server_log.write_text("server booted\nstep=1\n", encoding="utf-8")
        outputs = [root / "083.png", root / "084.png"]
        snapshot = {
            "ok": True,
            "protocol": client.PROTOCOL,
            "paused": False,
            "active_job": 8,
            "server_pid": 123,
            "log_dir": str(log_dir),
            "server_log": str(server_log),
            "jobs": [
                {
                    "id": 8,
                    "status": "running",
                    "payload": {
                        "settings": {"Width": 16, "Height": 16},
                        "prompt": "proof",
                        "negative_prompt": "",
                    },
                    "attempts": 1,
                    "outputs": [str(path) for path in outputs],
                    "server_log": str(server_log),
                    "updated_at": 123.0,
                    "error": "",
                }
            ],
        }
        opened: list[Path] = []
        module = SimpleNamespace(
            Launcher=Launcher,
            Job=Job,
            merged_settings=lambda settings: settings,
            open_folder=lambda path: opened.append(path),
        )
        client.request = lambda _operation: snapshot
        client.install_worker_client(module)

        launcher = Launcher()
        launcher._tick()
        assert launcher.current_job is not None
        assert launcher.current_job.job_id == 8
        assert launcher.current_job.log_path == server_log
        assert launcher.queue_table.item(0, 6).text == ", ".join(
            str(path) for path in outputs
        )
        assert any("server booted" in text for text in launcher.panel)

        server_log.write_text(
            server_log.read_text(encoding="utf-8") + "step=2\n",
            encoding="utf-8",
        )
        launcher._tick()
        assert sum("server booted" in text for text in launcher.panel) == 1
        assert sum("step=2" in text for text in launcher.panel) == 1
        launcher._open_log_dir()
        assert opened == [log_dir]

    print("Chroma launcher reconnect test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

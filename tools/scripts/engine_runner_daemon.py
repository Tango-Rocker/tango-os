#!/usr/bin/env python3
import argparse
import grp
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


def now_utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def wheel_gid():
    try:
        return grp.getgrnam("wheel").gr_gid
    except KeyError:
        return None


def apply_shared_permissions(path, mode):
    try:
        os.chmod(path, mode)
    except OSError:
        pass
    gid = wheel_gid()
    if gid is None or not hasattr(os, "chown"):
        return
    try:
        os.chown(path, -1, gid)
    except OSError:
        pass


class EngineRunner:
    def __init__(self):
        self.root = Path(os.environ.get("ENGINEOS_ROOT", ".")).resolve()
        self.state_dir = Path(os.environ.get("ENGINEOS_STATE_DIR", str(self.root / "artifacts" / "run")))
        self.log_dir = Path(os.environ.get("ENGINEOS_LOG_DIR", str(self.root / "artifacts" / "logs")))
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        apply_shared_permissions(self.state_dir, 0o2775)
        apply_shared_permissions(self.log_dir, 0o2775)
        self.pid_file = self.state_dir / "engine.pid"
        self.target_file = self.state_dir / "engine.target"
        self.args_file = self.state_dir / "engine.args.json"
        self.log_file = self.log_dir / "engine.log"
        self.log_file.touch(exist_ok=True)
        apply_shared_permissions(self.log_file, 0o664)
        self.process = None
        self.target = None
        self.args = []
        self.forwarded_env_keys = (
            "WAYLAND_DISPLAY",
            "DISPLAY",
            "XAUTHORITY",
            "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS",
            "XDG_CURRENT_DESKTOP",
            "XDG_SESSION_TYPE",
            "HOME",
            "USER",
            "LOGNAME",
            "PATH",
            "SDL_VIDEODRIVER",
            "SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR",
            "ENGINEOS_QUAKE_ID1",
            "ENGINEOS_QUAKE_ID1_DEFAULT",
            "ENGINEOS_QUAKE_ARGS",
            "ENGINEOS_QUAKE_SDL_AUDIODRIVER",
            "ENGINEOS_ROOT",
            "ENGINEOS_LOG_DIR",
            "ENGINEOS_STATE_DIR",
        )

    def _pid_alive(self, pid):
        if not pid:
            return False
        try:
            os.kill(int(pid), 0)
            return True
        except (OSError, ValueError):
            return False

    def _known_pid(self):
        try:
            return self.pid_file.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def _write_state(self, pid, target, args):
        self.pid_file.write_text(f"{pid}\n", encoding="utf-8")
        self.target_file.write_text(f"{target}\n", encoding="utf-8")
        self.args_file.write_text(json.dumps(args), encoding="utf-8")

    def _clear_state(self):
        for path in (self.pid_file, self.target_file, self.args_file):
            try:
                path.unlink()
            except OSError:
                pass

    def _read_previous(self):
        target = ""
        args = []
        try:
            target = self.target_file.read_text(encoding="utf-8").strip()
        except OSError:
            pass
        try:
            args = json.loads(self.args_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            args = []
        return target, args

    def _quake_runner(self):
        source_runner = self.root / "engines" / "quakespasm" / "engineos" / "run.sh"
        if source_runner.exists() and os.access(source_runner, os.X_OK):
            return str(source_runner)
        return "/usr/share/engineos/quake/run.sh"

    def status(self):
        pid = self._known_pid()
        target, args = self._read_previous()
        if self.process is not None and str(self.process.pid) == str(pid):
            running = self.process.poll() is None
        else:
            running = self._pid_alive(pid)
        if running:
            state = "running"
        elif pid:
            state = "exited"
        else:
            state = "stopped"
        return {
            "ok": True,
            "state": state,
            "pid": pid,
            "target": target,
            "args": args,
            "message": f"engine status: {state}",
        }

    def _filtered_client_env(self, values):
        if not isinstance(values, dict):
            return {}
        return {
            key: str(values[key])
            for key in self.forwarded_env_keys
            if key in values and values[key] not in (None, "")
        }

    def launch(self, target, args, client_env=None):
        current = self.status()
        if current["state"] == "running":
            return {
                "ok": False,
                "message": f"engine already running with pid {current['pid']}",
            }

        if target != "quake":
            return {"ok": False, "message": f"unknown engine target: {target}"}

        runner = self._quake_runner()
        if not os.path.exists(runner):
            return {"ok": False, "message": f"quake runner missing: {runner}"}

        forwarded_env = self._filtered_client_env(client_env or {})
        env = os.environ.copy()
        env.update(forwarded_env)
        env["ENGINEOS_LOG_TEE"] = "false"
        env.setdefault("ENGINEOS_ROOT", str(self.root))
        env.setdefault("ENGINEOS_LOG_DIR", str(self.log_dir))

        with self.log_file.open("ab") as log:
            display = forwarded_env.get("WAYLAND_DISPLAY") or forwarded_env.get("DISPLAY") or "(none)"
            log.write(
                f"\n[{now_utc()}] socket launch {target} {' '.join(args)} display={display}\n".encode()
            )
            process = subprocess.Popen(
                [runner, *args],
                stdout=log,
                stderr=subprocess.STDOUT,
                env=env,
                start_new_session=True,
            )
        self.process = process
        self.target = target
        self.args = args
        try:
            self._write_state(process.pid, target, args)
        except OSError as exc:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except OSError:
                try:
                    process.kill()
                except OSError:
                    pass
            process.wait()
            self.process = None
            self._clear_state()
            return {
                "ok": False,
                "message": f"launch failed to record engine state: {exc}",
            }
        return {
            "ok": True,
            "state": "running",
            "pid": str(process.pid),
            "target": target,
            "args": args,
            "message": f"engine launched: {target} pid={process.pid}",
        }

    def quit(self):
        pid = self._known_pid()
        if self.process is not None and str(self.process.pid) == str(pid) and self.process.poll() is not None:
            try:
                self.pid_file.unlink()
            except FileNotFoundError:
                pass
            return {"ok": True, "state": "stopped", "message": "engine already stopped"}

        if not self._pid_alive(pid):
            try:
                self.pid_file.unlink()
            except FileNotFoundError:
                pass
            return {"ok": True, "state": "stopped", "message": "engine already stopped"}

        try:
            os.killpg(os.getpgid(int(pid)), signal.SIGTERM)
        except OSError:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except OSError:
                pass

        for _ in range(20):
            if not self._pid_alive(pid):
                try:
                    self.pid_file.unlink()
                except FileNotFoundError:
                    pass
                return {"ok": True, "state": "stopped", "message": "engine stopped"}
            time.sleep(0.1)

        return {
            "ok": False,
            "state": "stopping",
            "pid": pid,
            "message": f"engine stop requested but pid is still running: {pid}",
        }

    def restart(self, target, args, client_env=None):
        if not target:
            target, args = self._read_previous()
        if not target:
            return {"ok": False, "message": "no previous engine target to restart"}
        stop = self.quit()
        if not stop.get("ok"):
            return {
                "ok": False,
                "state": stop.get("state"),
                "pid": stop.get("pid"),
                "message": f"engine restart aborted: {stop.get('message', 'previous engine did not stop')}",
            }
        return self.launch(target, args, client_env)

    def handle(self, request):
        method = request.get("method")
        if method == "engine.status":
            return self.status()
        if method == "engine.launch":
            return self.launch(request.get("target", ""), request.get("args", []), request.get("env", {}))
        if method == "engine.quit":
            return self.quit()
        if method == "engine.restart":
            return self.restart(request.get("target", ""), request.get("args", []), request.get("env", {}))
        if method == "engine.daemon.stop":
            stop = self.quit()
            if not stop.get("ok"):
                return {
                    "ok": False,
                    "state": stop.get("state"),
                    "pid": stop.get("pid"),
                    "message": f"engine runner daemon stop failed: {stop.get('message', 'engine did not stop')}",
                }
            return {"ok": True, "message": "engine runner daemon stopping", "_shutdown": True}
        return {"ok": False, "message": f"unknown method: {method}"}


def serve(socket_path):
    runner = EngineRunner()
    path = Path(socket_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    try:
        os.chmod(path, 0o775)
        os.chown(path, -1, grp.getgrnam("wheel").gr_gid)
    except (KeyError, OSError):
        pass
    server.listen(8)

    try:
        while True:
            conn, _ = server.accept()
            with conn:
                data = conn.recv(65536)
                try:
                    request = json.loads(data.decode("utf-8"))
                    response = runner.handle(request)
                except Exception as exc:  # Keep daemon alive and report failures to client.
                    response = {"ok": False, "message": f"daemon error: {exc}"}
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                if response.get("_shutdown"):
                    break
    finally:
        server.close()
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def client_env():
    keys = (
        "WAYLAND_DISPLAY",
        "DISPLAY",
        "XAUTHORITY",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
        "XDG_CURRENT_DESKTOP",
        "XDG_SESSION_TYPE",
        "HOME",
        "USER",
        "LOGNAME",
        "PATH",
        "SDL_VIDEODRIVER",
        "SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR",
        "ENGINEOS_QUAKE_ID1",
        "ENGINEOS_QUAKE_ID1_DEFAULT",
        "ENGINEOS_QUAKE_ARGS",
        "ENGINEOS_QUAKE_SDL_AUDIODRIVER",
        "ENGINEOS_ROOT",
        "ENGINEOS_LOG_DIR",
        "ENGINEOS_STATE_DIR",
    )
    return {key: os.environ[key] for key in keys if os.environ.get(key)}


def client(socket_path, method, target, args):
    request = {"method": method}
    if target:
        request["target"] = target
    if args:
        request["args"] = args
    if method in ("engine.launch", "engine.restart"):
        request["env"] = client_env()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    sock.sendall(json.dumps(request).encode("utf-8"))
    data = sock.recv(65536)
    sock.close()
    response = json.loads(data.decode("utf-8"))
    print(response.get("message", json.dumps(response)))
    for key in ("pid", "target"):
        if response.get(key):
            print(f"{key}: {response[key]}")
    if response.get("args"):
        print("args: " + " ".join(response["args"]))
    return 0 if response.get("ok") else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--daemon", action="store_true")
    parser.add_argument("--client", action="store_true")
    parser.add_argument("--socket", required=True)
    parser.add_argument("method", nargs="?")
    parser.add_argument("target", nargs="?")
    parser.add_argument("args", nargs=argparse.REMAINDER)
    ns = parser.parse_args()

    if ns.daemon:
        os.umask(0o002)
        serve(ns.socket)
        return 0
    if ns.client:
        if not ns.method:
            print("client method required", file=sys.stderr)
            return 2
        return client(ns.socket, ns.method, ns.target or "", ns.args)
    print("expected --daemon or --client", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

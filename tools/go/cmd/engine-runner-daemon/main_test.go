package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"engineos.local/tools/internal/engineos"
)

func testRunner(t *testing.T) *runner {
	t.Helper()
	tmpDir := t.TempDir()
	root := filepath.Join(tmpDir, "root")
	logDir := filepath.Join(tmpDir, "logs")
	stateDir := filepath.Join(tmpDir, "state")
	if err := os.MkdirAll(filepath.Join(root, "engines", "quakespasm", "engineos"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	runPath := filepath.Join(root, "engines", "quakespasm", "engineos", "run.sh")
	if err := os.WriteFile(runPath, []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &runner{
		paths: engineos.Paths{
			Root:     root,
			LogDir:   logDir,
			StateDir: stateDir,
		},
		pidFile:    filepath.Join(stateDir, "engine.pid"),
		targetFile: filepath.Join(stateDir, "engine.target"),
		argsFile:   filepath.Join(stateDir, "engine.args.json"),
		logFile:    filepath.Join(logDir, "engine.log"),
	}
}

func startTermIgnoringProcess(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("sh", "-c", "trap '' TERM; while :; do sleep 1; done")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_, _ = cmd.Process.Wait()
	})
	return cmd
}

func TestQuitFailsWhenProcessDoesNotStop(t *testing.T) {
	r := testRunner(t)
	cmd := startTermIgnoringProcess(t)
	r.writeState(cmd.Process.Pid, "quake", []string{"--smoke"})

	resp := r.quit()
	if resp.OK {
		t.Fatalf("quit returned ok for a process that ignored SIGTERM: %+v", resp)
	}
	if resp.State != "stopping" {
		t.Fatalf("quit state = %q, want stopping", resp.State)
	}
	if !strings.Contains(resp.Message, "still running") {
		t.Fatalf("quit message did not expose running pid: %q", resp.Message)
	}
}

func TestRestartAbortsWhenPreviousProcessDoesNotStop(t *testing.T) {
	r := testRunner(t)
	cmd := startTermIgnoringProcess(t)
	r.writeState(cmd.Process.Pid, "quake", []string{"--smoke"})

	resp := r.restart("", nil, nil)
	if resp.OK {
		t.Fatalf("restart returned ok when previous engine did not stop: %+v", resp)
	}
	if !strings.Contains(resp.Message, "restart aborted") {
		t.Fatalf("restart message did not explain stop failure: %q", resp.Message)
	}
}

func TestLaunchFailsWhenStateCannotBeRecorded(t *testing.T) {
	r := testRunner(t)
	if err := os.MkdirAll(r.pidFile, 0o755); err != nil {
		t.Fatal(err)
	}

	resp := r.launch("quake", []string{"--smoke"}, nil)
	if resp.OK {
		t.Fatalf("launch returned ok when state write failed: %+v", resp)
	}
	if !strings.Contains(resp.Message, "launch failed to record engine state") {
		t.Fatalf("launch failure did not expose state write error: %q", resp.Message)
	}
}

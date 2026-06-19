package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"engineos.local/tools/internal/engineos"
)

type request struct {
	Method string            `json:"method"`
	Target string            `json:"target,omitempty"`
	Args   []string          `json:"args,omitempty"`
	Env    map[string]string `json:"env,omitempty"`
}

type response struct {
	OK       bool     `json:"ok"`
	State    string   `json:"state,omitempty"`
	PID      string   `json:"pid,omitempty"`
	Target   string   `json:"target,omitempty"`
	Args     []string `json:"args,omitempty"`
	Message  string   `json:"message"`
	Shutdown bool     `json:"_shutdown,omitempty"`
}

type runner struct {
	paths      engineos.Paths
	pidFile    string
	targetFile string
	argsFile   string
	logFile    string
	process    *exec.Cmd
}

func newRunner() (*runner, error) {
	paths := engineos.DiscoverPaths()
	if err := os.MkdirAll(paths.StateDir, 0o2775); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(paths.LogDir, 0o2775); err != nil {
		return nil, err
	}
	return &runner{
		paths:      paths,
		pidFile:    filepath.Join(paths.StateDir, "engine.pid"),
		targetFile: filepath.Join(paths.StateDir, "engine.target"),
		argsFile:   filepath.Join(paths.StateDir, "engine.args.json"),
		logFile:    filepath.Join(paths.LogDir, "engine.log"),
	}, nil
}

func (r *runner) knownPID() string {
	data, err := os.ReadFile(r.pidFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func (r *runner) readPrevious() (string, []string) {
	targetData, _ := os.ReadFile(r.targetFile)
	argsData, _ := os.ReadFile(r.argsFile)
	var args []string
	_ = json.Unmarshal(argsData, &args)
	return strings.TrimSpace(string(targetData)), args
}

func (r *runner) writeState(pid int, target string, args []string) {
	_ = os.WriteFile(r.pidFile, []byte(fmt.Sprintf("%d\n", pid)), 0o664)
	_ = os.WriteFile(r.targetFile, []byte(target+"\n"), 0o664)
	data, _ := json.Marshal(args)
	_ = os.WriteFile(r.argsFile, data, 0o664)
}

func pidAlive(pidText string) bool {
	pid, err := strconv.Atoi(pidText)
	if err != nil || pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func (r *runner) status() response {
	pid := r.knownPID()
	target, args := r.readPrevious()
	running := false
	if r.process != nil && strconv.Itoa(r.process.Process.Pid) == pid {
		running = r.process.ProcessState == nil
	} else {
		running = pidAlive(pid)
	}
	state := "stopped"
	if running {
		state = "running"
	} else if pid != "" {
		state = "exited"
	}
	return response{OK: true, State: state, PID: pid, Target: target, Args: args, Message: "engine status: " + state}
}

func (r *runner) quakeRunner() string {
	source := filepath.Join(r.paths.Root, "engines", "quakespasm", "engineos", "run.sh")
	if st, err := os.Stat(source); err == nil && st.Mode()&0o111 != 0 {
		return source
	}
	return "/usr/share/engineos/quake/run.sh"
}

func (r *runner) launch(target string, args []string, clientEnv map[string]string) response {
	current := r.status()
	if current.State == "running" {
		return response{OK: false, Message: "engine already running with pid " + current.PID}
	}
	if target != "quake" {
		return response{OK: false, Message: "unknown engine target: " + target}
	}
	runnerPath := r.quakeRunner()
	if _, err := os.Stat(runnerPath); err != nil {
		return response{OK: false, Message: "quake runner missing: " + runnerPath}
	}
	logFile, err := os.OpenFile(r.logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o664)
	if err != nil {
		return response{OK: false, Message: "open log: " + err.Error()}
	}
	env := os.Environ()
	for _, key := range forwardedEnvKeys {
		if value := clientEnv[key]; value != "" {
			env = append(env, key+"="+value)
		}
	}
	env = append(env, "ENGINEOS_LOG_TEE=false")
	env = append(env, "ENGINEOS_ROOT="+r.paths.Root)
	env = append(env, "ENGINEOS_LOG_DIR="+r.paths.LogDir)
	cmd := exec.Command(runnerPath, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Env = env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	display := clientEnv["WAYLAND_DISPLAY"]
	if display == "" {
		display = clientEnv["DISPLAY"]
	}
	if display == "" {
		display = "(none)"
	}
	_, _ = fmt.Fprintf(logFile, "\n[%s] socket launch %s %s display=%s\n", time.Now().UTC().Format(time.RFC3339), target, strings.Join(args, " "), display)
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return response{OK: false, Message: "launch failed: " + err.Error()}
	}
	r.process = cmd
	r.writeState(cmd.Process.Pid, target, args)
	go func() {
		_ = cmd.Wait()
		_ = logFile.Close()
	}()
	return response{OK: true, State: "running", PID: strconv.Itoa(cmd.Process.Pid), Target: target, Args: args, Message: fmt.Sprintf("engine launched: %s pid=%d", target, cmd.Process.Pid)}
}

func (r *runner) quit() response {
	pidText := r.knownPID()
	if !pidAlive(pidText) {
		_ = os.Remove(r.pidFile)
		return response{OK: true, State: "stopped", Message: "engine already stopped"}
	}
	pid, _ := strconv.Atoi(pidText)
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	for i := 0; i < 20; i++ {
		if !pidAlive(pidText) {
			_ = os.Remove(r.pidFile)
			return response{OK: true, State: "stopped", Message: "engine stopped"}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return response{OK: true, State: "stopping", PID: pidText, Message: "engine stop requested; pid may still be exiting: " + pidText}
}

func (r *runner) restart(target string, args []string, env map[string]string) response {
	if target == "" {
		target, args = r.readPrevious()
	}
	if target == "" {
		return response{OK: false, Message: "no previous engine target to restart"}
	}
	r.quit()
	return r.launch(target, args, env)
}

func (r *runner) handle(req request) response {
	switch req.Method {
	case "engine.status":
		return r.status()
	case "engine.launch":
		return r.launch(req.Target, req.Args, req.Env)
	case "engine.quit":
		return r.quit()
	case "engine.restart":
		return r.restart(req.Target, req.Args, req.Env)
	case "engine.daemon.stop":
		r.quit()
		return response{OK: true, Message: "engine runner daemon stopping", Shutdown: true}
	default:
		return response{OK: false, Message: "unknown method: " + req.Method}
	}
}

var forwardedEnvKeys = []string{
	"WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
	"DBUS_SESSION_BUS_ADDRESS", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
	"HOME", "USER", "LOGNAME", "PATH", "SDL_VIDEODRIVER",
	"ENGINEOS_ROOT", "ENGINEOS_LOG_DIR", "ENGINEOS_STATE_DIR",
}

func serve(socketPath string) error {
	r, err := newRunner()
	if err != nil {
		return err
	}
	_ = os.Remove(socketPath)
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o2775); err != nil {
		return err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	_ = os.Chmod(socketPath, 0o775)
	defer listener.Close()
	defer os.Remove(socketPath)
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		shutdown := handleConn(conn, r)
		if shutdown {
			return nil
		}
	}
}

func handleConn(conn net.Conn, r *runner) bool {
	defer conn.Close()
	data, err := io.ReadAll(conn)
	if err != nil {
		writeResponse(conn, response{OK: false, Message: "read request: " + err.Error()})
		return false
	}
	var req request
	if err := json.Unmarshal(data, &req); err != nil {
		writeResponse(conn, response{OK: false, Message: "decode request: " + err.Error()})
		return false
	}
	resp := r.handle(req)
	writeResponse(conn, resp)
	return resp.Shutdown
}

func writeResponse(writer io.Writer, resp response) {
	data, _ := json.Marshal(resp)
	_, _ = writer.Write(append(data, '\n'))
}

func clientEnv() map[string]string {
	values := make(map[string]string)
	for _, key := range forwardedEnvKeys {
		if value := os.Getenv(key); value != "" {
			values[key] = value
		}
	}
	return values
}

func client(socketPath string, method string, target string, args []string) int {
	req := request{Method: method, Target: target, Args: args}
	if method == "engine.launch" || method == "engine.restart" {
		req.Env = clientEnv()
	}
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	data, _ := json.Marshal(req)
	if _, err := conn.Write(data); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	_ = conn.(*net.UnixConn).CloseWrite()
	respData, err := io.ReadAll(conn)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var resp response
	if err := json.Unmarshal(respData, &resp); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(resp.Message)
	if resp.PID != "" {
		fmt.Println("pid:", resp.PID)
	}
	if resp.Target != "" {
		fmt.Println("target:", resp.Target)
	}
	if len(resp.Args) > 0 {
		fmt.Println("args:", strings.Join(resp.Args, " "))
	}
	if !resp.OK {
		return 1
	}
	return 0
}

func main() {
	daemonMode := flag.Bool("daemon", false, "run daemon")
	clientMode := flag.Bool("client", false, "run client")
	socketPath := flag.String("socket", "", "Unix socket path")
	flag.Parse()
	if *socketPath == "" {
		fmt.Fprintln(os.Stderr, "--socket is required")
		os.Exit(2)
	}
	if *daemonMode {
		if err := serve(*socketPath); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if *clientMode {
		args := flag.Args()
		if len(args) == 0 {
			fmt.Fprintln(os.Stderr, "client method required")
			os.Exit(2)
		}
		method := args[0]
		target := ""
		rest := []string{}
		if len(args) > 1 {
			target = args[1]
		}
		if len(args) > 2 {
			rest = args[2:]
		}
		os.Exit(client(*socketPath, method, target, rest))
	}
	fmt.Fprintln(os.Stderr, "expected --daemon or --client")
	os.Exit(2)
}

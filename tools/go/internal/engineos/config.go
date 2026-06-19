package engineos

import (
	"os"
	"path/filepath"
)

type Paths struct {
	Root     string
	Scripts  string
	LogDir   string
	StateDir string
}

func DiscoverPaths() Paths {
	root := getenv("ENGINEOS_ROOT", "/usr")
	scripts := os.Getenv("ENGINEOS_SCRIPT_DIR")
	if scripts == "" {
		if _, err := os.Stat(filepath.Join(root, "tools", "scripts")); err == nil {
			scripts = filepath.Join(root, "tools", "scripts")
		} else {
			scripts = "/usr/lib/engineos/scripts"
		}
	}
	logDir := getenv("ENGINEOS_LOG_DIR", "/var/log/engineos")
	stateDir := getenv("ENGINEOS_STATE_DIR", filepath.Join(getenv("XDG_RUNTIME_DIR", "/tmp"), "engineos"))
	return Paths{Root: root, Scripts: scripts, LogDir: logDir, StateDir: stateDir}
}

func (p Paths) Script(name string) string {
	return filepath.Join(p.Scripts, name)
}

func getenv(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

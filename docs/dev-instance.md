# EngineDev Instance Bootstrap

This is the post-first-deploy path for a freshly booted EngineDev guest. It is
for making the live dev instance useful after the ISO has already booted and
SSH is reachable.

## Goal

The target dev instance should have:

- Codex CLI installed for the `dev` user
- tmux configured with mouse support and packaged tmux plugins
- zsh configured with packaged oh-my-zsh and packaged zsh plugins
- Docker installed, enabled, started, and usable by `dev`
- first-deploy logs under `/var/log/engineos/post-first-deploy.log`
- staged payload assets under `/tmp/engineos-post-first-deploy` during setup

Codex authentication is intentionally manual. After setup, run `codex` once in
the guest and sign in with the intended account.

## Command

From the Arch builder after `engineos vm boot enginedev --display none
--background --ssh-port 2222`:

```bash
cd /srv/engineos
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/engineos deploy first --host dev@127.0.0.1 --port 2222
```

For faster iteration before that boot step, rebuild EngineDev with the generated
fast-compression profile:

```bash
./tools/engineos/engineos build iso enginedev --fast --clean --archive-existing
```

Dry-run from any Linux shell:

```bash
./tools/engineos/engineos deploy first --dry-run --host dev@127.0.0.1 --port 2222
```

## Payload

The deploy command copies `tools/post-install-payload/` to the guest and runs:

```bash
bash /tmp/engineos-post-first-deploy/scripts/setup_dev_environment.sh --payload /tmp/engineos-post-first-deploy
```

Payload layout:

```text
tools/post-install-payload/
  scripts/setup_dev_environment.sh
  assets/tmux.conf
  assets/zshrc
  assets/docker/daemon.json
  assets/codex/engineos-dev-directives.md
```

Do not put commercial Quake assets, API keys, Codex credentials, SSH private
keys, or other secrets in this payload. It is repo-owned and packageable.

## Validation

Inside the guest:

```bash
tmux -V
tmux start-server \; show -g mouse \; show -g @plugin
zsh -ic 'echo $ZSH; echo $plugins'
docker info
id dev
codex --version
cat /var/log/engineos/post-first-deploy.log
```

If `docker` group membership was just added, a new login session may be needed
before `dev` can run Docker without sudo.

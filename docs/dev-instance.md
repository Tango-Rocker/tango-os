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

## GitHub Repositories

Use the `Tango-Rocker` account for the EngineOS follow-on repositories:

- `Tango-Rocker/tango-os` for this EngineOS checkout
- `Tango-Rocker/quake-os-integration` for Quake/EngineOS integration work
- `Tango-Rocker/engine-os` for EngineOS-focused runtime and appliance work

EngineDev autoinstall defaults to cloning:

```bash
https://github.com/Tango-Rocker/tango-os.git
```

For a private repo, do not bake a PAT into the ISO or post-install payload.
Create a fine-grained read-only token scoped to `Tango-Rocker/tango-os` with
Contents read permission only, place it on the live guest outside the repo, and
pass it at install time:

```bash
sudo engineos install dev \
  --device /dev/sdX \
  --repo-token-file /run/engineos-secrets/tango-os-readonly.token \
  --branch main \
  --yes-i-understand-this-wipes-device
```

The installer uses the token through a temporary `GIT_ASKPASS` helper and
removes the token copy from the target immediately after clone.

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

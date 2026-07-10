# EngineDev Instance Bootstrap

This is the post-first-deploy path for a freshly booted EngineDev guest. It is
for making the live dev instance useful after the ISO has already booted and
SSH is reachable.

## Goal

The target dev instance should have:

- Codex CLI installed for the `dev` user
- pinned `codex-insights 0.2.0` installed in an isolated user environment
- tmux configured with mouse support and packaged tmux plugins
- zsh configured with packaged oh-my-zsh and packaged zsh plugins
- Docker installed, enabled, started, and usable by `dev`
- dev conveniences installed from Arch packages: Neovim, fzf, zoxide, wl-clipboard,
  GitHub CLI, Git LFS, lazygit, btop, bat, eza, tldr, and local man pages
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

On the current bare-metal Windows lab, the no-`--device` installer default
targets the disk that is currently `F:` in Windows:

```text
/dev/disk/by-id/ata-WDC_WD10EZEX-00WN4A0_WD-WCC6Y1ZP5EAX
```

The installer repartitions that disk as GPT with a 1 GiB EFI partition, ext4
root, ext4 `/var`, and persistent ext4 `/srv`. It also mounts the existing
Windows `E:` NTFS volume labeled `Tango` at `/home` by default. Override with
`--device`, `ENGINEOS_INSTALL_DEFAULT_DEVICE`, `--home-ntfs-source`, or
`--no-home-ntfs` for VM proofs or different hardware.

For a private repo, do not bake a PAT into the ISO or post-install payload.
Create a fine-grained read-only token scoped to `Tango-Rocker/tango-os` with
Contents read permission only, place it on the live guest outside the repo, and
pass it at install time:

```bash
sudo eos-install dev \
  --repo-token-file /run/engineos-secrets/tango-os-readonly.token \
  --branch main \
  --yes-i-understand-this-wipes-device
```

The installer uses the token through a temporary `GIT_ASKPASS` helper and
removes the token copy from the target immediately after clone.

## Command

From the Arch builder after `eos-vm boot enginedev --display none
--background --ssh-port 2222`:

```bash
cd /srv/engineos
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/eos-deploy first --host dev@127.0.0.1 --port 2222
```

For faster iteration before that boot step, rebuild EngineDev with the generated
fast-compression profile:

```bash
./tools/engineos/eos-build iso enginedev --fast --clean --archive-existing
```

Dry-run from any Linux shell:

```bash
./tools/engineos/eos-deploy first --dry-run --host dev@127.0.0.1 --port 2222
```

## Payload

The deploy command copies `tools/post-install-payload/` to the guest and runs:

```bash
bash /tmp/engineos-post-first-deploy/scripts/setup_dev_environment.sh --payload /tmp/engineos-post-first-deploy
```

The destructive `eos-install dev` path uses the packaged payload from
`/usr/share/engineos/post-install-payload` when the installed `engineos-tools`
package provides it, with `/srv/engineos/tools/post-install-payload` as the
fallback. Rebuild the EngineDev ISO after payload changes so autoinstall uses
the intended first-boot setup.

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
codex-insights --version
cat /var/log/engineos/post-first-deploy.log
```

If `docker` group membership was just added, a new login session may be needed
before `dev` can run Docker without sudo.

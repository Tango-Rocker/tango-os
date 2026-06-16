#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: installation_guide.sh

Print the EngineDev bare-metal installation guide.
HELP
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

cat <<'GUIDE'
EngineDev installation guide

1. Prove the live ISO is healthy

   engineos doctor --bare-metal
   engineos installation-guide
   codex --version

   On the live EngineDev ISO, the codex command installs the official Codex CLI
   into /home/dev/.local/bin on first use if it is not already present. If the
   first run fails because networking was not ready, retry it directly:

   sudo /usr/local/bin/engineos-live-codex-setup
   codex --version

   Live Codex setup logs:

   /var/log/engineos/live-codex-setup.log

2. Prepare GitHub auth for the private Tang-OS repo

   The installer runs git with prompts disabled. For a private repo, create a
   fine-grained GitHub token with read-only access to Tango-Rocker/tango-os,
   then put only the token text on the live ISO:

   sudo install -d -m 0700 /run/engineos-secrets
   sudo tee /run/engineos-secrets/tango-os-readonly.token >/dev/null
   sudo chmod 0600 /run/engineos-secrets/tango-os-readonly.token

   Paste the token, press Enter, then press Ctrl+D. Do not put quotes around it.

3. Check the destructive install plan

   engineos install dev --dry-run \
     --repo-url https://github.com/Tango-Rocker/tango-os.git \
     --branch main \
     --repo-token-file /run/engineos-secrets/tango-os-readonly.token

   Confirm the target disk is the disk you intend to wipe.

4. Run the install

   sudo engineos install dev \
     --repo-url https://github.com/Tango-Rocker/tango-os.git \
     --branch main \
     --repo-token-file /run/engineos-secrets/tango-os-readonly.token \
     --yes-i-understand-this-wipes-device

   The token is copied into the target only as a root-only temporary clone
   secret, used through GIT_ASKPASS, then removed after clone.

5. If clone failed with "prompts are disabled"

   That means git needed credentials and no token file was supplied. Rebooting is
   not required just to inspect the guide; rerun the dry-run with --repo-token-file
   and then rerun the installer. If the target was partially installed, the
   guarded install command will repartition and reinstall the target disk.

6. If fstab was the only failed step

   Mount the target root at /mnt/engineos, then rewrite fstab as root:

   sudo mkdir -p /mnt/engineos
   sudo mount <root-partition> /mnt/engineos
   sudo mount <efi-partition> /mnt/engineos/boot
   sudo mount <var-partition> /mnt/engineos/var
   sudo mount <srv-partition> /mnt/engineos/srv
   sudo genfstab -U /mnt/engineos | sudo tee /mnt/engineos/etc/fstab >/dev/null

   Replace the bracketed partition names with the actual target partitions from:

   lsblk -f

7. After first boot from the installed disk

   cd /srv/engineos
   engineos doctor --bare-metal
   tmux -V
   docker info
   codex --version
   cat /var/log/engineos/post-first-deploy.log

   Start Codex from /srv/engineos after network is up:

   codex
GUIDE

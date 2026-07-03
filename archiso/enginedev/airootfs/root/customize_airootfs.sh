#!/usr/bin/env bash
set -euo pipefail

best_effort() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok: %s\n' "$label"
    return 0
  fi
  printf 'WARN best-effort failed: %s:' "$label" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

for group in wheel input audio video render; do
  groupadd -f "$group"
done

useradd -m -G wheel,input,audio,video,render -s /usr/bin/zsh dev
usermod -aG wheel,input,audio,video,render dev
usermod -s /usr/bin/zsh dev
printf 'dev:dev\n' | chpasswd

install -d -m 2775 -o root -g wheel /var/log/engineos
install -d -m 2775 -o root -g wheel /var/lib/engineos
install -d -m 0755 /etc/engineos
chown root:wheel /var/log/engineos /var/lib/engineos
chmod 2775 /var/log/engineos /var/lib/engineos

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
printf 'LANG=C.UTF-8\n' >/etc/locale.conf
printf 'KEYMAP=us\n' >/etc/vconsole.conf
printf 'enginedev\n' >/etc/hostname
systemctl mask systemd-firstboot.service

cat >/etc/engineos/version <<EOF
ENGINEOS_NAME=EngineDev OS
ENGINEOS_PROFILE=enginedev
ENGINEOS_BUILD_ID=$(date -u +%Y.%m.%d)
ENGINEOS_BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

cat >/etc/engineos/profile.conf <<'EOF'
ENGINEOS_PROFILE=enginedev
ENGINEOS_LOG_DIR=/var/log/engineos
EOF

cat >/etc/issue <<EOF
EngineDev OS $(date -u +%Y.%m.%d) \r (\l)
Profile: enginedev

Run: eos-doctor --vm
SSH: dev / dev
EOF

printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/10-engineos-wheel
chmod 0440 /etc/sudoers.d/10-engineos-wheel

systemctl enable NetworkManager.service
systemctl enable sshd.service
systemctl enable docker.service
systemctl enable engineos-live-setup.service
systemctl enable engineos-live-codex-setup.service
systemctl enable engineos-dev-shell.service
systemctl enable engineos-observe-exporter.service
best_effort "global PipeWire user units" systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
best_effort "dev user linger" loginctl enable-linger dev

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-engineos-live.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
EOF

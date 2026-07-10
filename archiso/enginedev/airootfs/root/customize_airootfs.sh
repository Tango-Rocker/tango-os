#!/usr/bin/env bash
set -euo pipefail

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

sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime
printf 'LANG=en_US.UTF-8\n' >/etc/locale.conf
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
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
install -d -m 0755 /var/lib/systemd/linger
: >/var/lib/systemd/linger/dev

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-engineos-live.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
EOF

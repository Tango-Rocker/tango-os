#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="EngineDevOS"
iso_label="ENGINEDEV_$(date +%Y%m)"
iso_publisher="EngineOS"
iso_application="EngineDev OS"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=("iso")
bootmodes=(
  "uefi.systemd-boot"
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=("-comp" "xz" "-Xbcj" "x86" "-b" "1M" "-Xdict-size" "1M" "-processors" "4")
file_permissions=(
  ["/root/customize_airootfs.sh"]="0:0:755"
  ["/usr/local/bin/engineos-firstboot"]="0:0:755"
  ["/usr/local/bin/engineos-live-setup"]="0:0:755"
  ["/usr/local/bin/engineos-dev-shell-start"]="0:0:755"
)

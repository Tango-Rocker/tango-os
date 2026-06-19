param(
  [int]$DiskNumber = 3,
  [string]$Repo = "E:\dev\Tang-OS"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogDir = Join-Path $Repo "artifacts\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "deploy-real-install-windows.log"
Start-Transcript -Path $Log -Force | Out-Null

$physical = "\\.\PHYSICALDRIVE$DiskNumber"
$mounted = $false

try {
  $admin = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This deployment must run from an elevated PowerShell process."
  }

  $disk = Get-Disk -Number $DiskNumber
  Write-Host "Disk ${DiskNumber}: $($disk.FriendlyName) size=$($disk.Size) IsSystem=$($disk.IsSystem) IsBoot=$($disk.IsBoot)"
  if ($disk.FriendlyName -notlike "*WDC WD10EZEX*") {
    throw "Refusing to touch Disk ${DiskNumber}; unexpected model: $($disk.FriendlyName)"
  }
  if ($disk.IsBoot) {
    throw "Refusing to touch Disk ${DiskNumber} because Windows reports it as the active boot disk."
  }

  $parts = Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber
  foreach ($p in $parts) {
    Write-Host "Partition $($p.PartitionNumber): type=$($p.Type) gpt=$($p.GptType) size=$($p.Size)"
  }
  if (($parts | Measure-Object).Count -lt 4) {
    throw "Refusing to deploy: Disk ${DiskNumber} does not have the expected EngineDev four-partition layout."
  }

  $rootPart = $parts | Where-Object PartitionNumber -eq 2
  $varPart = $parts | Where-Object PartitionNumber -eq 3
  $srvPart = $parts | Where-Object PartitionNumber -eq 4
  if ($rootPart.Size -lt 60GB -or $rootPart.Size -gt 70GB) {
    throw "Partition 2 does not look like the 64 GiB EngineDev root partition."
  }
  if ($varPart.Size -lt 120GB -or $varPart.Size -gt 140GB) {
    throw "Partition 3 does not look like the 128 GiB EngineDev /var partition."
  }
  if ($srvPart.Size -lt 700GB) {
    throw "Partition 4 does not look like the persistent EngineDev /srv partition."
  }

  Write-Host "Unmounting any stale WSL mount for Disk ${DiskNumber}."
  & wsl.exe --unmount $physical 2>$null

  Write-Host "Mounting EngineDev root partition through WSL."
  & wsl.exe --mount $physical --partition 2 --type ext4 --name EngineDevRoot
  if ($LASTEXITCODE -ne 0) {
    throw "wsl --mount failed with exit code $LASTEXITCODE"
  }
  $mounted = $true

  $linux = @'
set -euo pipefail
src=/mnt/e/dev/Tang-OS
root=/mnt/wsl/EngineDevRoot
srv_mount=/mnt/engineos-srv
printf 'WSL deploy source: %s\n' "$src"
printf 'WSL deploy root: %s\n' "$root"
test -d "$src/tools/scripts"
test -d "$root/etc"
test -d "$root/usr"
install -Dm755 "$src/tools/engineos/engineos" "$root/usr/bin/engineos"
install -Dm755 "$src/tools/engineos/eos" "$root/usr/bin/eos"
install -Dm755 "$src/tools/engineos/eos-wrapper" "$root/usr/bin/eos-update"
install -Dm755 "$src/tools/scripts/common.sh" "$root/usr/lib/engineos/scripts/common.sh"
install -Dm755 "$src/tools/scripts/update_check.sh" "$root/usr/lib/engineos/scripts/update_check.sh"
install -Dm0644 "$src/tools/post-install-payload/assets/zprofile" "$root/usr/share/engineos/post-install-payload/assets/zprofile"
if [ -d /mnt/e/dev ]; then
  install -Dm0644 "$src/tools/post-install-payload/assets/zprofile" /mnt/e/dev/.zprofile
fi
mkdir -p "$srv_mount"
if ! mountpoint -q "$srv_mount"; then
  mount LABEL=ENGINEOS_DEV_SRV "$srv_mount" || true
fi
if mountpoint -q "$srv_mount" && [ -d "$srv_mount/engineos" ]; then
  install -Dm755 "$src/tools/engineos/engineos" "$srv_mount/engineos/tools/engineos/engineos"
  install -Dm755 "$src/tools/engineos/eos" "$srv_mount/engineos/tools/engineos/eos"
  install -Dm755 "$src/tools/engineos/eos-wrapper" "$srv_mount/engineos/tools/engineos/eos-update"
  install -Dm755 "$src/tools/scripts/common.sh" "$srv_mount/engineos/tools/scripts/common.sh"
  install -Dm755 "$src/tools/scripts/update_check.sh" "$srv_mount/engineos/tools/scripts/update_check.sh"
  install -Dm0644 "$src/tools/post-install-payload/assets/zprofile" "$srv_mount/engineos/tools/post-install-payload/assets/zprofile"
  printf 'Updated /srv/engineos checkout files.\n'
else
  printf 'WARN /srv EngineOS checkout was not mounted or not present; installed /usr files were updated.\n' >&2
fi
grep -F 'update check' "$root/usr/bin/engineos"
grep -F 'eos-update check --init' "$root/usr/share/engineos/post-install-payload/assets/zprofile"
if [ -f /mnt/e/dev/.zprofile ]; then
  grep -F 'eos-update check --init' /mnt/e/dev/.zprofile
fi
if mountpoint -q "$srv_mount"; then
  umount "$srv_mount"
fi
printf 'EngineDev real install update hook deployed.\n'
'@
  & wsl.exe -d Ubuntu --user root --exec bash -lc $linux
  if ($LASTEXITCODE -ne 0) {
    throw "WSL deployment failed with exit code $LASTEXITCODE"
  }
}
finally {
  if ($mounted) {
    Write-Host "Unmounting EngineDev root partition from WSL."
    & wsl.exe --unmount $physical
  }
  Stop-Transcript | Out-Null
}

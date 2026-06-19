<#
.SYNOPSIS
Create a Hyper-V VM for booting an EngineOS ISO directly.

.DESCRIPTION
This host-side helper creates a Generation 2 Hyper-V VM for a generated
EngineDev or EngineRuntime ISO. It is dry-run by default. Run from an elevated
PowerShell session with -Execute to create the VM, and add -Start to boot it.

Hyper-V basic VMConnect/console sessions do not expose an emulated ALSA sound
card to Linux guests. This VM is useful for boot, input, display, and Quake
smoke validation, but real audio needs bare metal, a VM path with emulated audio,
or an RDP/enhanced-session audio redirection setup inside the guest.
#>
[CmdletBinding()]
param(
    [string]$Name = "EngineOS-EngineDev-Test",
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,
    [string]$VmRoot = "$env:PUBLIC\Documents\Hyper-V\EngineOS",
    [string]$SwitchName = "Default Switch",
    [int]$MemoryGB = 4,
    [int]$CpuCount = 4,
    [int]$DiskGB = 32,
    [switch]$Replace,
    [switch]$Execute,
    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [string]$Preview
    )

    Write-Host "==> $Label"
    if ($Preview) {
        Write-Host "    $Preview"
    }
    if ($Execute) {
        & $Action
    }
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $Name. Enable Hyper-V and run this from an elevated PowerShell session."
    }
}

Require-Command Get-VM
Require-Command New-VM
Require-Command New-VHD
Require-Command Set-VM
Require-Command Set-VMMemory
Require-Command Set-VMProcessor
Require-Command Set-VMFirmware
Require-Command Add-VMDvdDrive
Require-Command Get-VMDvdDrive
Require-Command Get-VMSwitch
Require-Command Start-VM
Require-Command Stop-VM
Require-Command Remove-VM

$resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
if (-not $resolvedIso.EndsWith(".iso", [StringComparison]::OrdinalIgnoreCase)) {
    throw "IsoPath must point to an .iso file: $resolvedIso"
}

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    $available = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    $availableText = if ($available) { $available -join ", " } else { "(none visible)" }
    if ($Execute) {
        throw "Hyper-V switch not found: '$SwitchName'. Available switches: $availableText. Create or choose a switch before running this helper."
    }
    Write-Warning "Hyper-V switch not found: '$SwitchName'. Available switches: $availableText. Dry-run will continue, but -Execute requires a valid switch."
}

$vmPath = Join-Path $VmRoot $Name
$vhdPath = Join-Path $vmPath "$Name.vhdx"
$memoryBytes = [int64]$MemoryGB * 1GB
$minimumBytes = [int64]([math]::Max(1, [math]::Floor($MemoryGB / 2))) * 1GB
$maximumBytes = [int64]$MemoryGB * 1GB
$diskBytes = [int64]$DiskGB * 1GB
$existingVm = Get-VM -Name $Name -ErrorAction SilentlyContinue

if ($existingVm -and -not $Replace) {
    throw "VM already exists: $Name. Re-run with -Replace to remove and recreate it, or choose a different -Name."
}

Write-Host "EngineOS Hyper-V ISO test VM"
Write-Host "  name:      $Name"
Write-Host "  iso:       $resolvedIso"
Write-Host "  root:      $VmRoot"
Write-Host "  switch:    $SwitchName"
Write-Host "  memory:    ${MemoryGB}GB"
Write-Host "  cpus:      $CpuCount"
Write-Host "  disk:      ${DiskGB}GB"
Write-Host "  audio:     no basic Hyper-V Linux sound device; use hardware/RDP/audio-capable VM for real output"
Write-Host "  replace:   $Replace"
Write-Host "  execute:   $Execute"
Write-Host "  start:     $Start"
Write-Host ""

if ($existingVm -and $Replace) {
    Invoke-Step "stop existing VM if needed" {
        if ((Get-VM -Name $Name).State -ne "Off") {
            Stop-VM -Name $Name -Force
        }
    } "if ((Get-VM -Name '$Name').State -ne 'Off') { Stop-VM -Name '$Name' -Force }"

    Invoke-Step "remove existing VM" {
        Remove-VM -Name $Name -Force
    } "Remove-VM -Name '$Name' -Force"
}

if ($Replace) {
    Invoke-Step "remove existing VM storage" {
        if (Test-Path -LiteralPath $vmPath) {
            Remove-Item -LiteralPath $vmPath -Recurse -Force
        }
    } "if (Test-Path -LiteralPath '$vmPath') { Remove-Item -LiteralPath '$vmPath' -Recurse -Force }"
}

Invoke-Step "create VM root" {
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
} "New-Item -ItemType Directory -Path '$vmPath' -Force"

Invoke-Step "create dynamic VHDX" {
    New-VHD -Path $vhdPath -SizeBytes $diskBytes -Dynamic | Out-Null
} "New-VHD -Path '$vhdPath' -SizeBytes $diskBytes -Dynamic"

Invoke-Step "create Generation 2 VM" {
    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath $vhdPath -Path $VmRoot -SwitchName $SwitchName | Out-Null
} "New-VM -Name '$Name' -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath '$vhdPath' -Path '$VmRoot' -SwitchName '$SwitchName'"

Invoke-Step "set dynamic memory" {
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes $minimumBytes -StartupBytes $memoryBytes -MaximumBytes $maximumBytes
} "Set-VMMemory -VMName '$Name' -DynamicMemoryEnabled `$true -MinimumBytes $minimumBytes -StartupBytes $memoryBytes -MaximumBytes $maximumBytes"

Invoke-Step "set CPU count" {
    Set-VMProcessor -VMName $Name -Count $CpuCount
} "Set-VMProcessor -VMName '$Name' -Count $CpuCount"

Invoke-Step "disable Secure Boot for EngineOS ISO" {
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off
} "Set-VMFirmware -VMName '$Name' -EnableSecureBoot Off"

Invoke-Step "attach EngineOS ISO" {
    Add-VMDvdDrive -VMName $Name -Path $resolvedIso
} "Add-VMDvdDrive -VMName '$Name' -Path '$resolvedIso'"

Invoke-Step "prefer DVD boot first" {
    $dvd = Get-VMDvdDrive -VMName $Name
    Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
} "Set-VMFirmware -VMName '$Name' -FirstBootDevice (Get-VMDvdDrive -VMName '$Name')"

if ($Start) {
    Invoke-Step "start VM" {
        Start-VM -Name $Name
    } "Start-VM -Name '$Name'"
}

Write-Host ""
if ($Execute) {
    Write-Host "ISO test VM is ready."
    Write-Host "Next: open Hyper-V Manager and connect to '$Name'."
    Write-Host "Audio note: Hyper-V basic sessions do not provide a Linux ALSA sound card; expect PipeWire/Pulse dummy output unless using an RDP/enhanced-session audio path."
} else {
    Write-Host "Dry-run completed. Re-run from elevated PowerShell with -Execute to create the VM."
}
Write-Host "  powershell -ExecutionPolicy Bypass -File .\tools\scripts\create_iso_test_vm_hyperv.ps1 -IsoPath `"$resolvedIso`" -Execute -Start"

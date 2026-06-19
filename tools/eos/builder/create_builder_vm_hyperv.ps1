<# 
.SYNOPSIS
Create the EngineOS Arch builder VM in Hyper-V.

.DESCRIPTION
This host-side helper creates a Generation 2 Hyper-V VM for the Arch builder.
It is intentionally dry-run by default. Pass -Execute to create the VM.

The VM still needs a normal Arch install from the attached ISO. After install,
create the dev user, enable sshd, and run the EngineOS builder handoff from
the Windows/WSL host.
#>
[CmdletBinding()]
param(
    [string]$Name = "EngineOS-Builder",
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,
    [string]$VmRoot = "$env:PUBLIC\Documents\Hyper-V\EngineOS",
    [string]$SwitchName = "Default Switch",
    [int]$MemoryGB = 8,
    [int]$CpuCount = 4,
    [int]$DiskGB = 160,
    [switch]$Execute,
    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [string]$Preview
    )

    Write-Step $Label
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

Require-Command New-VM
Require-Command New-VHD
Require-Command Set-VM
Require-Command Set-VMProcessor
Require-Command Set-VMFirmware
Require-Command Add-VMDvdDrive
Require-Command Get-VMSwitch

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

$existingVm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($existingVm) {
    throw "VM already exists: $Name. Use Hyper-V Manager to inspect it or choose a different -Name."
}

$vmPath = Join-Path $VmRoot $Name
$vhdPath = Join-Path $vmPath "$Name.vhdx"
$memoryBytes = [int64]$MemoryGB * 1GB
$diskBytes = [int64]$DiskGB * 1GB

Write-Host "EngineOS Hyper-V builder VM"
Write-Host "  name:      $Name"
Write-Host "  iso:       $resolvedIso"
Write-Host "  root:      $VmRoot"
Write-Host "  switch:    $SwitchName"
Write-Host "  memory:    ${MemoryGB}GB"
Write-Host "  cpus:      $CpuCount"
Write-Host "  disk:      ${DiskGB}GB"
Write-Host "  execute:   $Execute"
Write-Host "  start:     $Start"
Write-Host ""

Invoke-Step "create VM root" {
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
} "New-Item -ItemType Directory -Path '$vmPath' -Force"

Invoke-Step "create dynamic VHDX" {
    New-VHD -Path $vhdPath -SizeBytes $diskBytes -Dynamic | Out-Null
} "New-VHD -Path '$vhdPath' -SizeBytes $diskBytes -Dynamic"

Invoke-Step "create Generation 2 VM" {
    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath $vhdPath -Path $VmRoot -SwitchName $SwitchName | Out-Null
} "New-VM -Name '$Name' -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath '$vhdPath' -Path '$VmRoot' -SwitchName '$SwitchName'"

Invoke-Step "set CPU count" {
    Set-VMProcessor -VMName $Name -Count $CpuCount
} "Set-VMProcessor -VMName '$Name' -Count $CpuCount"

Invoke-Step "disable Secure Boot for Arch ISO" {
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off
} "Set-VMFirmware -VMName '$Name' -EnableSecureBoot Off"

Invoke-Step "attach Arch installer ISO" {
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
    Write-Host "Builder VM creation completed."
    Write-Host "Next: connect to '$Name' in Hyper-V Manager, install Arch, enable sshd, then run:"
} else {
    Write-Host "Dry-run completed. Re-run with -Execute to create the VM:"
}
Write-Host "  powershell -ExecutionPolicy Bypass -File .\tools\scripts\create_builder_vm_hyperv.ps1 -IsoPath `"$resolvedIso`" -Execute -Start"

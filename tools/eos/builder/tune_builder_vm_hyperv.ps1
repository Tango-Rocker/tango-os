<#
.SYNOPSIS
Tune the EngineOS Hyper-V builder VM for reliable ISO builds.

.DESCRIPTION
This host-side helper is dry-run by default. Run from an elevated PowerShell
session with -Execute to apply resource settings. With -Restart, the helper
will stop a running VM before changing memory/CPU settings and start it again.
#>
[CmdletBinding()]
param(
    [string]$Name = "EngineOS-Builder",
    [int]$MinimumGB = 4,
    [int]$StartupGB = 0,
    [int]$MaximumGB = 0,
    [int]$CpuCount = 0,
    [switch]$Execute,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $Name. Enable Hyper-V and run this from an elevated PowerShell session."
    }
}

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [string]$Preview
    )

    Write-Host "==> $Label"
    Write-Host "    $Preview"
    if ($Execute) {
        & $Action
    }
}

Require-Command Get-VM
Require-Command Set-VMMemory
Require-Command Set-VMProcessor
Require-Command Stop-VM
Require-Command Start-VM

$hostSystem = Get-CimInstance Win32_ComputerSystem
$hostMemoryGB = [math]::Floor([int64]$hostSystem.TotalPhysicalMemory / 1GB)
$hostCpuCount = [int]$hostSystem.NumberOfLogicalProcessors

if ($MaximumGB -le 0) {
    $MaximumGB = [math]::Min(16, [math]::Max(8, [math]::Floor($hostMemoryGB * 0.40)))
}
if ($StartupGB -le 0) {
    $StartupGB = [math]::Min(8, $MaximumGB)
}
if ($CpuCount -le 0) {
    $CpuCount = [math]::Min(6, [math]::Max(4, [math]::Floor($hostCpuCount / 2)))
}

if ($MinimumGB -gt $StartupGB) {
    throw "MinimumGB ($MinimumGB) must be <= StartupGB ($StartupGB)."
}
if ($StartupGB -gt $MaximumGB) {
    throw "StartupGB ($StartupGB) must be <= MaximumGB ($MaximumGB)."
}
if ($CpuCount -gt $hostCpuCount) {
    throw "CpuCount ($CpuCount) cannot exceed host logical CPU count ($hostCpuCount)."
}

$vm = Get-VM -Name $Name -ErrorAction Stop
$wasRunning = $vm.State -eq "Running"

Write-Host "EngineOS Hyper-V builder tuning"
Write-Host "  vm:        $Name"
Write-Host "  host ram:  ${hostMemoryGB}GB"
Write-Host "  host cpus: $hostCpuCount"
Write-Host "  min ram:   ${MinimumGB}GB"
Write-Host "  startup:   ${StartupGB}GB"
Write-Host "  max ram:   ${MaximumGB}GB"
Write-Host "  cpus:      $CpuCount"
Write-Host "  running:   $wasRunning"
Write-Host "  execute:   $Execute"
Write-Host "  restart:   $Restart"
Write-Host ""

if ($wasRunning -and -not $Restart) {
    Write-Warning "VM is running. Re-run with -Restart to stop, tune, and start it, or stop it manually first."
    if ($Execute) {
        throw "Refusing to tune a running VM without -Restart."
    }
}

if ($wasRunning -and $Restart) {
    Invoke-Step "stop VM" {
        Stop-VM -Name $Name
    } "Stop-VM -Name '$Name'"
}

$minimumBytes = [int64]$MinimumGB * 1GB
$startupBytes = [int64]$StartupGB * 1GB
$maximumBytes = [int64]$MaximumGB * 1GB

Invoke-Step "set dynamic memory" {
    Set-VMMemory -VMName $Name `
        -DynamicMemoryEnabled $true `
        -MinimumBytes $minimumBytes `
        -StartupBytes $startupBytes `
        -MaximumBytes $maximumBytes
} "Set-VMMemory -VMName '$Name' -DynamicMemoryEnabled `$true -MinimumBytes $minimumBytes -StartupBytes $startupBytes -MaximumBytes $maximumBytes"

Invoke-Step "set CPU count" {
    Set-VMProcessor -VMName $Name -Count $CpuCount
} "Set-VMProcessor -VMName '$Name' -Count $CpuCount"

if ($wasRunning -and $Restart) {
    Invoke-Step "start VM" {
        Start-VM -Name $Name
    } "Start-VM -Name '$Name'"
}

Write-Host ""
if ($Execute) {
    Write-Host "Builder VM tuning completed."
} else {
    Write-Host "Dry-run completed. Re-run from elevated PowerShell with -Execute"
    Write-Host "Add -Restart if the VM is currently running."
}

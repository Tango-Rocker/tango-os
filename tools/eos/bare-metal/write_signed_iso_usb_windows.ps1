<#
.SYNOPSIS
Write a signed EngineOS ISO directly to a USB disk on Windows.

.DESCRIPTION
This script is intentionally guarded. It defaults to dry-run and refuses to run
unless the target disk matches the expected removable USB identity.
#>

[CmdletBinding()]
param(
    [string]$IsoPath = "E:\dev\Tang-OS\out\EngineDevOS-2026.06.15-x86_64-secureboot-enroll.iso",
    [int]$DiskNumber = 4,
    [string]$ExpectedFriendlyName = "USB DISK 2.0",
    [string]$ExpectedSerialNumber = "2773030620C0",
    [UInt64]$MinSizeBytes = 30000000000,
    [UInt64]$MaxSizeBytes = 33000000000,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Bytes([UInt64]$Bytes) {
    return "{0:N2} GiB" -f ($Bytes / 1GB)
}

function Invoke-DiskpartScript([string[]]$Lines) {
    $scriptPath = Join-Path $env:TEMP "engineos-diskpart-$PID.txt"
    try {
        Set-Content -LiteralPath $scriptPath -Encoding ASCII -Value ($Lines -join "`r`n")
        & diskpart.exe /s $scriptPath
        if ($LASTEXITCODE -ne 0) {
            throw "diskpart failed with exit code $LASTEXITCODE"
        }
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-PhysicalDriveReady([int]$TargetDiskNumber, [int]$TimeoutSeconds = 30) {
    $targetPath = "\\.\PhysicalDrive$TargetDiskNumber"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            Update-HostStorageCache -ErrorAction SilentlyContinue
            $null = Get-Disk -Number $TargetDiskNumber -ErrorAction Stop
            $probe = [System.IO.File]::Open(
                $targetPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::ReadWrite
            )
            $probe.Dispose()
            return
        } catch {
            $lastError = $_
            Start-Sleep -Seconds 2
        }
    }

    throw "Timed out waiting for $targetPath to become writable after rescan. Last error: $lastError"
}

function Write-IsoToPhysicalDrive([string]$SourceIso, [int]$TargetDiskNumber) {
    $source = [System.IO.File]::Open(
        $SourceIso,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $targetPath = "\\.\PhysicalDrive$TargetDiskNumber"
        $target = [System.IO.File]::Open(
            $targetPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $buffer = New-Object byte[] (4MB)
            $total = [UInt64]0
            $lastPercent = -1
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $target.Write($buffer, 0, $read)
                $total += [UInt64]$read
                $percent = [int](($total * 100) / $source.Length)
                if ($percent -ne $lastPercent) {
                    Write-Progress -Activity "Writing EngineOS ISO to USB" -Status "$percent% ($([Math]::Round($total / 1MB)) MiB)" -PercentComplete $percent
                    $lastPercent = $percent
                }
            }
            $target.Flush($true)
            Write-Progress -Activity "Writing EngineOS ISO to USB" -Completed
        } finally {
            $target.Dispose()
        }
    } finally {
        $source.Dispose()
    }
}

function Write-IsoToPhysicalDriveWithRetry([string]$SourceIso, [int]$TargetDiskNumber, [int]$Attempts = 3) {
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Wait-PhysicalDriveReady -TargetDiskNumber $TargetDiskNumber
            Write-IsoToPhysicalDrive -SourceIso $SourceIso -TargetDiskNumber $TargetDiskNumber
            return
        } catch {
            if ($attempt -ge $Attempts) {
                throw
            }
            Write-Warning "USB write attempt $attempt failed: $($_.Exception.Message)"
            Write-Warning "Rescanning disk and retrying from the beginning."
            Invoke-DiskpartScript @(
                "rescan"
            )
            Start-Sleep -Seconds 3
        }
    }
}

$resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
if (-not $resolvedIso.EndsWith(".iso", [StringComparison]::OrdinalIgnoreCase)) {
    throw "IsoPath must point to an .iso file: $resolvedIso"
}

$isoItem = Get-Item -LiteralPath $resolvedIso
$disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
$partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
$diskFriendlyName = "$($disk.FriendlyName)".Trim()
$diskSerialNumber = "$($disk.SerialNumber)".Trim()

Write-Host "EngineOS signed ISO USB writer"
Write-Host "  iso:      $resolvedIso"
Write-Host "  iso size: $(Format-Bytes $isoItem.Length)"
Write-Host "  disk:     $DiskNumber"
Write-Host "  name:     $diskFriendlyName"
Write-Host "  serial:   $diskSerialNumber"
Write-Host "  bus:      $($disk.BusType)"
Write-Host "  size:     $(Format-Bytes $disk.Size)"
Write-Host "  execute:  $Execute"

if (-not (Test-Admin)) {
    throw "This script must run from an elevated PowerShell session."
}
if ($disk.BusType -ne "USB") {
    throw "Refusing target: disk $DiskNumber is not USB (BusType=$($disk.BusType))."
}
if ($diskFriendlyName -ne $ExpectedFriendlyName) {
    throw "Refusing target: expected FriendlyName '$ExpectedFriendlyName', got '$diskFriendlyName'."
}
if ($diskSerialNumber -ne $ExpectedSerialNumber) {
    throw "Refusing target: expected SerialNumber '$ExpectedSerialNumber', got '$diskSerialNumber'."
}
if ($disk.Size -lt $MinSizeBytes -or $disk.Size -gt $MaxSizeBytes) {
    throw "Refusing target: disk size $(Format-Bytes $disk.Size) is outside expected range."
}
if ($isoItem.Length -gt $disk.Size) {
    throw "Refusing target: ISO is larger than disk."
}

if ($partitions) {
    Write-Host "  current partitions:"
    $partitions | Format-Table -AutoSize DiskNumber,PartitionNumber,DriveLetter,Type,Size | Out-Host
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "Dry-run only. Re-run with -Execute to overwrite disk $DiskNumber."
    exit 0
}

Write-Host ""
Write-Host "About to overwrite disk $DiskNumber with $resolvedIso"
Write-Host "This destroys all existing data on that USB disk."

Invoke-DiskpartScript @(
    "select disk $DiskNumber",
    "attributes disk clear readonly",
    "clean",
    "online disk noerr"
)

Invoke-DiskpartScript @(
    "rescan"
)

Write-IsoToPhysicalDriveWithRetry -SourceIso $resolvedIso -TargetDiskNumber $DiskNumber

Invoke-DiskpartScript @(
    "rescan"
)

Write-Host "EngineOS USB write complete."
Write-Host "Boot the USB UEFI entry. If Secure Boot blocks it, enroll EngineOS-SecureBoot-db.cer from the USB first."

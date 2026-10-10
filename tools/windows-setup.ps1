param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('pre', 'post')]
    [string]$Stage
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: run this stage from an elevated PowerShell (Run as Administrator)." -ForegroundColor Red
        exit 1
    }
}

switch ($Stage) {

    'pre' {
        Assert-Admin
        Write-Host "[1/2] Enabling Microsoft-Windows-Subsystem-Linux..." -ForegroundColor Cyan
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        Write-Host "[2/2] Enabling VirtualMachinePlatform..." -ForegroundColor Cyan
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        Write-Host ""
        Write-Host "DONE. REBOOT NOW, then continue with:  .\windows-setup.ps1 -Stage post" -ForegroundColor Yellow
        $answer = Read-Host "Reboot this machine now? (y/N)"
        if ($answer -eq 'y') { Restart-Computer -Confirm:$false }
    }

    'post' {
        Write-Host "[1/3] Converting Ubuntu to WSL2 (several minutes)..." -ForegroundColor Cyan
        wsl --set-version Ubuntu 2
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: conversion failed." -ForegroundColor Red; exit 1 }

        Write-Host "[2/3] Installing build/boot toolchain inside Ubuntu (qemu, cross-gcc, kernel deps)..." -ForegroundColor Cyan
        wsl -d Ubuntu -u root -- bash -c "apt-get update -qq && apt-get install -y -qq qemu-system-arm qemu-utils gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev cpio rsync erofs-utils cryptsetup-bin squashfs-tools busybox-static s6 python3 openssl"

        Write-Host "[3/3] Running Ox OS self-test suite..." -ForegroundColor Cyan
        wsl -d Ubuntu -- bash -c "bash '/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/selftest.sh'"

        Write-Host ""
        Write-Host "WSL2 READY. Next session: kernel cross-build + first QEMU boot." -ForegroundColor Green
    }
}

# assemble.ps1 — Build bootloader + kernel, output timestamped .img to .\ass\
# Run with: powershell -ExecutionPolicy Bypass -File assemble.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  assemble.ps1" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

try {
    # ---------- find nasm ---------------------------------------------------
    Write-Host "[1/5] Checking tools..."

    $nasm = Get-Command nasm -ErrorAction SilentlyContinue
    if (-not $nasm) {
        Write-Host ""
        Write-Host "  ERROR: nasm not found." -ForegroundColor Red
        Write-Host "  Install from https://nasm.us/ and add to PATH."
        Write-Host ""
        exit 1
    }
    Write-Host "  nasm ... OK  [$($nasm.Source)]" -ForegroundColor Green

    # ---------- find dd -----------------------------------------------------
    $ddPath = $null
    $candidates = @(
        (Join-Path $ScriptDir "tools\dd.exe"),
        "C:\Program Files\Git\usr\bin\dd.exe",
        "C:\Program Files (x86)\Git\usr\bin\dd.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $ddPath = $c; break }
    }
    if (-not $ddPath) {
        $found = Get-Command dd -ErrorAction SilentlyContinue
        if ($found) { $ddPath = $found.Source }
    }
    if (-not $ddPath) {
        Write-Host ""
        Write-Host "  ERROR: dd not found." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Options:"
        Write-Host "    A) Install Git for Windows - https://git-scm.com/download/win"
        Write-Host "       (ships dd.exe, auto-detected automatically)"
        Write-Host "    B) Drop dd.exe into a .\tools\ folder next to this script"
        Write-Host "       Download: http://www.chrysocome.net/dd"
        Write-Host ""
        exit 1
    }
    Write-Host "  dd   ... OK  [$ddPath]" -ForegroundColor Green

    # ---------- assemble bootloader -----------------------------------------
    Write-Host ""
    Write-Host "[2/5] Assembling bootloader..."
    & nasm -f bin -o bootloader.bin bootloader.asm
    if ($LASTEXITCODE -ne 0) { throw "bootloader.asm assembly failed." }
    Write-Host "  bootloader.bin  $((Get-Item bootloader.bin).Length) bytes" -ForegroundColor Green

    # ---------- assemble kernel ---------------------------------------------
    Write-Host ""
    Write-Host "[3/5] Assembling kernel..."
    & nasm -f bin -o kernel.bin kernel.asm
    if ($LASTEXITCODE -ne 0) { throw "kernel.asm assembly failed." }
    Write-Host "  kernel.bin      $((Get-Item kernel.bin).Length) bytes" -ForegroundColor Green

    # ---------- build disk image --------------------------------------------
    Write-Host ""
    Write-Host "[4/5] Building disk image..."

    $ts  = Get-Date -Format "yyyyMMdd_HHmmss"
    $out = "ass"
    if (-not (Test-Path $out)) { New-Item -ItemType Directory $out | Out-Null }
    $img = "$out\os_$ts.img"

    $ErrorActionPreference = 'Continue'
    & $ddPath if=/dev/zero      of="$img" bs=512 count=2880            2>&1 | Out-Null
    & $ddPath if=bootloader.bin of="$img" bs=512 count=1 conv=notrunc  2>&1 | Out-Null
    & $ddPath if=kernel.bin     of="$img" bs=512 seek=1  conv=notrunc  2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'

    Write-Host "  $((Get-Item $img).Length) bytes  -->  $img" -ForegroundColor Green

    # ---------- done --------------------------------------------------------
    Write-Host ""
    Write-Host "[5/5] Done!" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Image : $img"
    Write-Host ""
    Write-Host "  To run:  qemu-system-x86_64 -drive format=raw,file=$img"
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan

} catch {
    Write-Host ""
    Write-Host "  ERROR: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
} finally {
    # Always clean up intermediates, whether we succeeded or failed
    Remove-Item bootloader.bin, kernel.bin -ErrorAction SilentlyContinue
}

Read-Host "  Press Enter to close"
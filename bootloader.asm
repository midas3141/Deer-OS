; =============================================================================
; bootloader.asm — Stage 1 bootloader (fits in the 512-byte MBR)
;
; The BIOS loads this code to 0x7C00 and jumps to it.
; Our job here:
;   1. Set up a sane segment/stack environment
;   2. Print a "Booting..." message using BIOS INT 10h
;   3. Load the kernel (sector 2 onward) from disk using BIOS INT 13h
;   4. Jump to the kernel at 0x1000:0x0000
; =============================================================================

[BITS 16]               ; We start in 16-bit real mode
[ORG 0x7C00]            ; BIOS loads us here

; ---------- entry point ----------
start:
    ; Disable interrupts while we set up segments/stack
    cli

    ; Zero all segment registers so addressing is flat from 0
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Stack grows downward from just below us (0x7C00)
    mov sp, 0x7C00

    ; Save the boot drive number the BIOS left in DL
    mov [boot_drive], dl

    sti                 ; Interrupts back on

    ; Print "Booting..." via BIOS teletype (INT 10h, AH=0Eh)
    mov si, msg_boot
    call print_string

    ; ------------------------------------------------------------------
    ; Load kernel from disk
    ;   We'll read KERNEL_SECTORS sectors starting at LBA sector 1
    ;   (sector 2 on disk, because sectors are 1-indexed in CHS).
    ;   Destination: 0x1000:0000 = linear 0x10000
    ; ------------------------------------------------------------------
    mov ax, 0x1000      ; destination segment
    mov es, ax
    xor bx, bx          ; destination offset = 0  → ES:BX = 0x10000

    mov ah, 0x02        ; INT 13h function: read sectors
    mov al, KERNEL_SECTORS
    mov ch, 0           ; cylinder 0
    mov cl, 2           ; sector 2 (1-indexed; sector 1 is the MBR)
    mov dh, 0           ; head 0
    mov dl, [boot_drive]
    int 0x13
    jc  disk_error      ; carry flag set → error

    ; Print "OK" and jump to kernel
    mov si, msg_ok
    call print_string

    ; Far-jump to kernel: CS=0x1000, IP=0x0000
    jmp 0x1000:0x0000

; ---------- error handler ----------
disk_error:
    mov si, msg_err
    call print_string
.hang:
    hlt
    jmp .hang

; ---------- print_string ----------
; SI → pointer to null-terminated string
print_string:
    mov ah, 0x0E        ; BIOS teletype mode
    mov bh, 0           ; page 0
.loop:
    lodsb               ; AL = *SI++
    test al, al
    jz   .done
    int  0x10
    jmp  .loop
.done:
    ret

; ---------- data ----------
boot_drive      db 0
msg_boot        db "Booting...", 0x0D, 0x0A, 0
msg_ok          db "Kernel loaded. Jumping...", 0x0D, 0x0A, 0
msg_err         db "Disk read error!", 0x0D, 0x0A, 0

KERNEL_SECTORS  equ 9   ; How many 512-byte sectors to load for the kernel

; ---------- MBR signature ----------
; Pad to exactly 510 bytes, then append the 0xAA55 boot signature
times 510 - ($ - $$) db 0
dw 0xAA55
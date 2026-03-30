; =============================================================================
; kernel.asm — dees os kernel with whitetail filesystem + dish shell
;
; Memory map (all in real mode):
;   0x1000:0000  kernel (this code)
;   0x2000:0000  FS node table  (4 KB)
;   0x3000:0000  File data heap (8 KB)
;   0x4000:0000  Shell input buffer (256 bytes)
;
; Filesystem node (64 bytes):
;   [0]  type     db   0=file 1=dir
;   [1]  pad      db
;   [2]  parent   dw   parent node index (0xFFFF = root-parent)
;   [4]  name     db   32 bytes null-padded
;  [36]  size     dw   data size in bytes
;  [38]  data_off dw   offset into heap (segment 0x3000), 0 if empty
;  [40]  reserved 24 bytes
;
; Shell state (in kernel DS segment, after code):
;   cwd_idx  dw   current directory node index (0xFFFF = root)
; =============================================================================

[BITS 16]
[ORG 0x0000]

; ---- segment constants -----------------------------------------------------
FS_SEG      equ 0x2000      ; node table
HEAP_SEG    equ 0x3000      ; file data
IBUF_SEG    equ 0x4000      ; input buffer
NODE_SIZE   equ 64
FS_HDR      equ 16
MAX_NODES   equ 32          ; room for user-created files
HEAP_SIZE   equ 0x2000      ; 8 KB heap

; ---- node field offsets ----------------------------------------------------
N_TYPE      equ 0
N_PAD       equ 1
N_PARENT    equ 2
N_NAME      equ 4
N_SIZE      equ 36
N_DATA      equ 38

; ===========================================================================
; ENTRY POINT
; ===========================================================================
kernel_start:
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFF0

    ; clear screen
    mov ah, 0x00
    mov al, 0x03
    int 0x10

    ; cursor row 1
    mov ah, 0x02
    xor bh, bh
    mov dh, 1
    xor dl, dl
    int 0x10

    mov si, msg_logo
    call print_cyan

    call fs_init
    call shell_run

.idle:
    hlt
    jmp .idle


; ===========================================================================
; FS_INIT — zero memory, build initial node table
; ===========================================================================
fs_init:
    pusha

    ; zero FS node table (4 KB)
    mov ax, FS_SEG
    mov es, ax
    xor di, di
    mov cx, 0x0800
    xor ax, ax
    rep stosw

    ; zero heap (8 KB)
    mov ax, HEAP_SEG
    mov es, ax
    xor di, di
    mov cx, 0x1000
    xor ax, ax
    rep stosw

    ; FS header: magic "WHTF", version 1
    mov ax, FS_SEG
    mov es, ax
    mov word [es:0], 0x4857
    mov word [es:2], 0x4654
    mov word [es:4], 1
    mov word [es:6], 0          ; node count starts at 0, incremented by mk_node

    ; ---- initial directory structure ----------------------------------------
    ; node 0: dir  Users   parent=FFFFh
    mov ax, 0xFFFF
    mov si, s_Users
    mov bl, 1
    call mk_node                ; returns node index in AX

    ; node 1: dir  usr     parent=0
    mov ax, 0
    mov si, s_usr
    mov bl, 1
    call mk_node

    ; node 2: file home    parent=1
    mov ax, 1
    mov si, s_home
    mov bl, 0
    call mk_node

    ; node 3: file documents  parent=1
    mov ax, 1
    mov si, s_documents
    mov bl, 0
    call mk_node

    ; node 4: dir  Root    parent=FFFFh
    mov ax, 0xFFFF
    mov si, s_Root
    mov bl, 1
    call mk_node

    ; node 5: dir  source  parent=4
    mov ax, 4
    mov si, s_source
    mov bl, 1
    call mk_node

    ; node 6: file kernel-backup.bin   parent=5
    mov ax, 5
    mov si, s_kbak
    mov bl, 0
    call mk_node

    ; node 7: file bootloader-backup.bin  parent=5
    mov ax, 5
    mov si, s_bbak
    mov bl, 0
    call mk_node

    ; node 8: file copyright.txt  parent=5
    mov ax, 5
    mov si, s_copy
    mov bl, 0
    call mk_node

    ; node 9: file log.log  parent=5
    mov ax, 5
    mov si, s_log
    mov bl, 0
    call mk_node

    ; node 10: dir  bin     parent=5  (whitetail/Root/source/bin.dish)
    mov ax, 5
    mov si, s_bin_dish
    mov bl, 1
    call mk_node

    ; initialise current working directory to root (0xFFFF)
    mov word [cs:cwd_idx], 0xFFFF

    popa
    ret


; ---------------------------------------------------------------------------
; mk_node — create a new node
;   IN:  AX = parent index, SI = name string (CS-relative), BL = type
;   OUT: AX = new node index
; ---------------------------------------------------------------------------
mk_node:
    push bx
    push cx
    push si
    push di
    push es

    mov cx, FS_SEG
    mov es, cx

    ; get current count → new index
    mov cx, [es:6]
    push cx                     ; save new node index

    ; compute node offset = FS_HDR + index*NODE_SIZE
    mov di, cx
    mov cx, NODE_SIZE
    mul_di:
    ; DI * 64: shift left 6
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    add di, FS_HDR

    ; write fields
    mov [es:di + N_TYPE],   bl
    mov [es:di + N_PARENT], ax
    mov word [es:di + N_SIZE],   0
    mov word [es:di + N_DATA],   0

    ; copy name
    push di
    add di, N_NAME
.name_lp:
    mov cl, [cs:si]
    mov [es:di], cl
    inc si
    inc di
    test cl, cl
    jnz .name_lp
    pop di

    ; increment node count
    inc word [es:6]

    pop ax                      ; return new node index
    pop es
    pop di
    pop si
    pop cx
    pop bx
    ret


; ===========================================================================
; SHELL_RUN — main shell loop
; ===========================================================================
shell_run:
    ; print welcome
    mov si, msg_welcome
    call print_white

    mov si, msg_help_hint
    call print_white

.loop:
    call shell_prompt
    call shell_readline
    call shell_parse
    jmp .loop


; ---------------------------------------------------------------------------
; shell_prompt — print "cwd> "
; ---------------------------------------------------------------------------
shell_prompt:
    push ax
    push bx
    push si

    mov si, msg_crlf
    call print_white

    ; print current path
    mov ax, [cs:cwd_idx]
    cmp ax, 0xFFFF
    jne .not_root

    mov si, s_whitetail
    call print_cyan
    jmp .arrow

.not_root:
    ; print parent path recursively then this dir name
    call print_path

.arrow:
    mov si, msg_prompt_arrow
    call print_cyan

    pop si
    pop bx
    pop ax
    ret


; ---------------------------------------------------------------------------
; print_path — recursively print path of node AX
; ---------------------------------------------------------------------------
print_path:
    push ax
    push bx
    push si
    push ds

    ; get parent
    push ax
    mov bx, NODE_SIZE
    xor dx, dx
    mul bx
    add ax, FS_HDR + N_PARENT
    mov si, ax
    mov ax, FS_SEG
    mov ds, ax
    mov ax, [ds:si]             ; parent index
    pop bx                      ; BX = original node index
    pop ds

    push bx
    cmp ax, 0xFFFF
    je .base
    push ax
    call print_path
    pop ax
.base:
    pop bx

    ; print "/" then this node's name
    push bx
    mov si, msg_slash
    call print_cyan
    pop bx

    ; print name
    push ax
    push bx
    push ds
    mov ax, bx
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR + N_NAME
    mov si, ax
    mov ax, FS_SEG
    mov ds, ax
.name_lp:
    mov al, [ds:si]
    test al, al
    jz .name_done
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
    int 0x10
    inc si
    jmp .name_lp
.name_done:
    pop ds
    pop bx
    pop ax

    pop si
    pop bx
    pop ax
    ret


; ---------------------------------------------------------------------------
; shell_readline — read a line into IBUF_SEG:0, null-terminated
; ---------------------------------------------------------------------------
shell_readline:
    push ax
    push bx
    push es

    mov ax, IBUF_SEG
    mov es, ax
    xor bx, bx                  ; BX = current position in buffer

.key:
    mov ah, 0x00
    int 0x16                    ; wait for keypress → AL=char, AH=scancode

    cmp al, 0x0D                ; Enter
    je .enter

    cmp al, 0x08                ; Backspace
    je .backspace

    cmp bx, 254                 ; buffer full?
    jge .key

    ; echo and store
    mov ah, 0x0E
    mov [cs:bl_save], bl
    mov bl, 0x0F
    xor bh, bh
    int 0x10
    mov bl, [cs:bl_save]

    mov [es:bx], al
    inc bx
    jmp .key

.backspace:
    test bx, bx
    jz .key
    dec bx
    ; erase from screen
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
    mov al, 0x08
    int 0x10
    mov al, ' '
    int 0x10
    mov al, 0x08
    int 0x10
    jmp .key

.enter:
    mov byte [es:bx], 0         ; null-terminate
    ; print newline
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
    mov al, 0x0D
    int 0x10
    mov al, 0x0A
    int 0x10

    pop es
    pop bx
    pop ax
    ret

bl_save db 0


; ---------------------------------------------------------------------------
; shell_parse — parse and dispatch command in IBUF_SEG:0
; ---------------------------------------------------------------------------
shell_parse:
    pusha
    push ds
    push es

    ; point DS at input buffer
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si                  ; SI = start of input

    ; skip leading spaces
.skip_sp:
    mov al, [ds:si]
    cmp al, ' '
    jne .no_sp
    inc si
    jmp .skip_sp
.no_sp:

    ; empty line?
    mov al, [ds:si]
    test al, al
    jz .done

    ; ---- compare against known commands (CS-relative strings) ---------------
    push si
    mov di, si                  ; DI = start of command token in input
    pop si

    ; "help"
    mov cx, cs
    mov es, cx
    mov di, cmd_help
    call str_match
    jc .do_help

    mov di, cmd_cd
    call str_match
    jc .do_cd

    mov di, cmd_crt
    call str_match
    jc .do_crt

    mov di, cmd_cat
    call str_match
    jc .do_cat

    mov di, cmd_ls
    call str_match
    jc .do_ls

    mov di, cmd_quit
    call str_match
    jc .do_quit

    mov di, cmd_mkdir
    call str_match
    jc .do_mkdir

    mov di, cmd_crtusr
    call str_match
    jc .do_crtusr

    mov di, cmd_tree
    call str_match
    jc .do_tree

    mov di, cmd_wrt
    call str_match
    jc .do_wrt

    ; unknown command
    mov ax, cs
    mov ds, ax
    mov si, msg_unknown
    call print_white
    jmp .done

.do_help:
    mov ax, cs
    mov ds, ax
    mov si, msg_help_text
    call print_white
    jmp .done

.do_ls:
    call cmd_do_ls
    jmp .done

.do_cd:
    ; advance SI past "cd "
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si
    add si, 3                   ; skip "cd "
    call cmd_do_cd
    jmp .done

.do_crt:
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si
    add si, 4                   ; skip "crt "
    call cmd_do_crt
    jmp .done

.do_cat:
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si
    add si, 4                   ; skip "cat "
    call cmd_do_cat
    jmp .done

.do_quit:
    call cmd_do_quit
    jmp .done

.do_mkdir:
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si
    add si, 6                   ; skip "mkdir "
    call cmd_do_mkdir
    jmp .done

.do_crtusr:
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si
    add si, 7                   ; skip "crtusr "
    call cmd_do_crtusr
    jmp .done

.do_tree:
    call cmd_do_tree
    jmp .done

.do_wrt:
    mov ax, IBUF_SEG
    mov ds, ax
    xor si, si
    add si, 4                   ; skip "wrt "
    call cmd_do_wrt
    jmp .done

.done:
    pop es
    pop ds
    popa
    ret


; ---------------------------------------------------------------------------
; str_match — check if DS:SI starts with CS:DI (space or null terminates match)
;   IN:  DS:SI = input, CS:DI = command string
;   OUT: carry set = match
; ---------------------------------------------------------------------------
str_match:
    push ax
    push bx
    push si
    push di
.lp:
    mov al, [cs:di]
    test al, al
    jz .matched                 ; reached end of command string
    mov bl, [ds:si]
    cmp al, bl
    jne .no_match
    inc si
    inc di
    jmp .lp
.matched:
    ; next char in input must be space or null
    mov bl, [ds:si]
    cmp bl, ' '
    je .ok
    cmp bl, 0
    je .ok
.no_match:
    pop di
    pop si
    pop bx
    pop ax
    clc
    ret
.ok:
    pop di
    pop si
    pop bx
    pop ax
    stc
    ret


; ---------------------------------------------------------------------------
; get_arg — copy argument from DS:SI into CS:arg_buf (null-terminated, trimmed)
; ---------------------------------------------------------------------------
get_arg:
    push ax
    push si
    push di
    push es

    ; skip spaces
.skip:
    mov al, [ds:si]
    cmp al, ' '
    jne .copy
    inc si
    jmp .skip

.copy:
    mov ax, cs
    mov es, ax
    mov di, arg_buf
.lp:
    mov al, [ds:si]
    cmp al, 0x0D
    je .end
    test al, al
    je .end
    mov [es:di], al
    inc si
    inc di
    jmp .lp
.end:
    mov byte [es:di], 0

    pop es
    pop di
    pop si
    pop ax
    ret

arg_buf times 64 db 0


; ---------------------------------------------------------------------------
; find_child — find node with name CS:arg_buf that is child of AX
;   IN:  AX = parent index (0xFFFF for root-level)
;   OUT: AX = node index, or 0xFFFF if not found
;        BL = node type
; Uses ES=FS_SEG throughout; ES is saved/restored.
; ---------------------------------------------------------------------------
find_child:
    push cx
    push si
    push di
    push ds
    push es

    mov cx, FS_SEG
    mov es, cx                  ; ES = FS_SEG for node reads
    mov cx, [es:6]              ; total node count
    xor di, di                  ; node index iterator

.loop:
    cmp di, cx
    jge .notfound

    ; compute node base offset in FS_SEG
    push ax
    push cx
    push di
    mov ax, di
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR
    mov si, ax                  ; SI = node base in ES (FS_SEG)
    pop di
    pop cx
    pop ax

    ; check parent matches
    mov dx, [es:si + N_PARENT]
    cmp dx, ax
    jne .next

    ; compare name [es:si+N_NAME] vs [cs:arg_buf]
    push si
    push di
    push ax
    add si, N_NAME
    mov di, arg_buf
.cmp_lp:
    mov al, [es:si]             ; byte from FS node name
    mov ah, [cs:di]             ; byte from arg_buf
    cmp al, ah
    jne .cmp_fail
    test al, al                 ; both zero = match
    jz .cmp_match
    inc si
    inc di
    jmp .cmp_lp

.cmp_match:
    pop ax
    pop di
    pop si
    ; return this node index and type
    mov ax, di
    push ax
    mov ax, di
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR
    mov si, ax
    mov bl, [es:si + N_TYPE]
    pop ax
    jmp .found

.cmp_fail:
    pop ax
    pop di
    pop si

.next:
    inc di
    jmp .loop

.notfound:
    mov ax, 0xFFFF
    mov bl, 0xFF

.found:
    pop es
    pop ds
    pop di
    pop si
    pop cx
    ret


; ---------------------------------------------------------------------------
; CMD_DO_LS — list children of cwd
; ---------------------------------------------------------------------------
cmd_do_ls:
    pusha
    push ds

    mov ax, FS_SEG
    mov ds, ax
    mov cx, [ds:6]              ; node count

    push cx
    mov ax, cs
    mov ds, ax
    mov si, msg_crlf
    call print_white
    pop cx

    xor di, di
.ls_loop:
    cmp di, cx
    jge .ls_done

    ; get node offset
    push ax
    push cx
    mov ax, di
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR
    mov si, ax
    pop cx
    pop ax

    ; check parent == cwd_idx
    push ds
    mov dx, FS_SEG
    mov ds, dx
    mov dx, [ds:si + N_PARENT]
    pop ds

    push ax
    mov ax, cs
    mov es, ax
    mov ax, [es:cwd_idx]
    cmp dx, ax
    pop ax
    jne .ls_next

    ; print name
    push ds
    push cx
    push di
    push si
    mov dx, FS_SEG
    mov ds, dx
    add si, N_NAME
.ls_name_lp:
    mov al, [ds:si]
    test al, al
    jz .ls_name_done
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
    int 0x10
    inc si
    jmp .ls_name_lp
.ls_name_done:
    ; if dir, print "/"
    pop si
    push si
    mov al, [ds:si + N_TYPE]
    cmp al, 1
    jne .ls_no_slash
    push ds
    mov dx, cs
    mov ds, dx
    mov si, msg_slash
    call print_white
    pop ds
.ls_no_slash:
    push ds
    mov dx, cs
    mov ds, dx
    mov si, msg_crlf
    call print_white
    pop ds

    pop si
    pop di
    pop cx
    pop ds

.ls_next:
    inc di
    jmp .ls_loop

.ls_done:
    pop ds
    popa
    ret


; ---------------------------------------------------------------------------
; CMD_DO_CD — change directory
;   DS:SI = argument string
; ---------------------------------------------------------------------------
cmd_do_cd:
    pusha
    push ds

    call get_arg

    ; handle ".."
    push cs
    pop es
    mov di, arg_buf
    mov al, [es:di]
    cmp al, '.'
    jne .not_dotdot
    mov al, [es:di+1]
    cmp al, '.'
    jne .not_dotdot

    ; go to parent
    mov ax, [cs:cwd_idx]
    cmp ax, 0xFFFF
    je .already_root

    ; get parent of current node
    push ax
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR + N_PARENT
    mov si, ax
    push ds
    mov dx, FS_SEG
    mov ds, dx
    mov ax, [ds:si]
    pop ds
    pop dx                      ; discard old cwd
    mov [cs:cwd_idx], ax
    jmp .cd_done

.already_root:
    jmp .cd_done

.not_dotdot:
    ; find child named arg_buf under cwd
    mov ax, [cs:cwd_idx]
    call find_child
    cmp ax, 0xFFFF
    je .cd_notfound

    ; must be a directory
    cmp bl, 1
    jne .cd_notdir

    mov [cs:cwd_idx], ax
    jmp .cd_done

.cd_notfound:
    push cs
    pop ds
    mov si, msg_notfound
    call print_white
    jmp .cd_done

.cd_notdir:
    push cs
    pop ds
    mov si, msg_notdir
    call print_white

.cd_done:
    pop ds
    popa
    ret


; ---------------------------------------------------------------------------
; CMD_DO_CRT — create file in cwd, log command to bin.dish
;   DS:SI = argument (filename)
; ---------------------------------------------------------------------------
cmd_do_crt:
    pusha
    push ds

    call get_arg

    ; check arg not empty
    push cs
    pop es
    mov al, [es:arg_buf]
    test al, al
    jz .crt_usage

    ; create the node
    mov ax, [cs:cwd_idx]        ; parent = cwd
    push cs
    pop ds
    mov si, arg_buf
    mov bl, 0                   ; type = file
    call mk_node
    ; AX = new node index (unused for now)

    ; log "crt <filename>" to bin.dish node (node 10)
    push cs
    pop ds
    mov si, msg_crt_cmd
    call log_to_bin_dish

    push cs
    pop ds
    mov si, arg_buf
    call log_to_bin_dish

    push cs
    pop ds
    mov si, msg_log_newline
    call log_to_bin_dish

    push cs
    pop ds
    mov si, msg_created
    call print_white
    push cs
    pop ds
    mov si, arg_buf
    call print_white_ds
    push cs
    pop ds
    mov si, msg_crlf
    call print_white
    jmp .crt_done

.crt_usage:
    push cs
    pop ds
    mov si, msg_crt_usage
    call print_white

.crt_done:
    pop ds
    popa
    ret


; ---------------------------------------------------------------------------
; CMD_DO_CAT — print contents of file
;   DS:SI = argument (filename)
; ---------------------------------------------------------------------------
cmd_do_cat:
    pusha
    push ds

    call get_arg

    push cs
    pop es
    mov al, [es:arg_buf]
    test al, al
    jz .cat_usage

    ; find file under cwd
    mov ax, [cs:cwd_idx]
    call find_child
    cmp ax, 0xFFFF
    je .cat_notfound

    ; check it's a file
    cmp bl, 1
    je .cat_isdir

    ; get data offset and size
    push ax
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR
    mov si, ax
    push ds
    mov dx, FS_SEG
    mov ds, dx
    mov bx, [ds:si + N_DATA]    ; heap offset
    mov cx, [ds:si + N_SIZE]    ; size
    pop ds
    pop ax

    test cx, cx
    jz .cat_empty

    ; print from HEAP_SEG:BX, CX bytes
    push ds
    mov dx, HEAP_SEG
    mov ds, dx
    mov si, bx
.cat_lp:
    test cx, cx
    jz .cat_lp_done
    mov al, [ds:si]
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
    int 0x10
    inc si
    dec cx
    jmp .cat_lp
.cat_lp_done:
    pop ds
    push cs
    pop ds
    mov si, msg_crlf
    call print_white
    jmp .cat_done

.cat_empty:
    push cs
    pop ds
    mov si, msg_empty_file
    call print_white
    jmp .cat_done

.cat_notfound:
    push cs
    pop ds
    mov si, msg_notfound
    call print_white
    jmp .cat_done

.cat_isdir:
    push cs
    pop ds
    mov si, msg_isdir
    call print_white
    jmp .cat_done

.cat_usage:
    push cs
    pop ds
    mov si, msg_cat_usage
    call print_white

.cat_done:
    pop ds
    popa
    ret


; ---------------------------------------------------------------------------
; CMD_DO_WRT — write (append) text to a file
;   Usage: wrt <filename> <text...>
;   DS:SI points to the part of the input buffer after "wrt "
;
;   Parses the first word as the filename, everything after as content.
;   Finds the file under cwd, allocates heap space if needed, appends the
;   text followed by CR+LF so multiple writes stack as separate lines.
;   Only works on files (type=0); will reject directories.
; ---------------------------------------------------------------------------
cmd_do_wrt:
    pusha
    push ds

    ; ---- parse filename (first word) into arg_buf --------------------------
    call get_arg                ; DS:SI → arg_buf in CS

    push cs
    pop es
    mov al, [es:arg_buf]
    test al, al
    jz .wrt_usage

    ; ---- find the file under cwd -------------------------------------------
    mov ax, [cs:cwd_idx]
    call find_child             ; AX=node index, BL=type
    cmp ax, 0xFFFF
    je .wrt_notfound
    cmp bl, 1
    je .wrt_isdir               ; can't write to a directory

    mov [cs:wrt_node], ax       ; save node index

    ; ---- locate content start in input buffer ------------------------------
    ; Input buffer still at IBUF_SEG. Content starts after "wrt <filename> "
    ; We need to skip past the filename in the raw buffer.
    ; Easiest: scan IBUF_SEG from offset 4 (after "wrt ") past the filename
    ; word, then skip one space, to get to the content.
    push es
    mov ax, IBUF_SEG
    mov es, ax
    mov si, 4                   ; skip "wrt "

.skip_fname:
    mov al, [es:si]
    test al, al
    jz .wrt_no_content
    cmp al, ' '
    je .skip_spaces
    inc si
    jmp .skip_fname

.skip_spaces:
    mov al, [es:si]
    cmp al, ' '
    jne .content_start
    inc si
    jmp .skip_spaces

.content_start:
    ; ES:SI now points at the content text in IBUF_SEG
    ; Check it's not empty
    mov al, [es:si]
    test al, al
    jz .wrt_no_content

    ; ---- write content to heap for this node --------------------------------
    ; We need to call log_to_bin_dish style logic but for an arbitrary node.
    ; We'll do it inline: find the node's heap slot, append ES:SI there.

    mov bx, [cs:wrt_node]      ; node index
    push bx
    mov cx, NODE_SIZE
    xor dx, dx
    mov ax, bx
    mul cx
    add ax, FS_HDR
    mov bx, ax                  ; BX = node base offset in FS_SEG

    push ds
    mov ax, FS_SEG
    mov ds, ax

    mov dx, [ds:bx + N_DATA]    ; heap offset (0 = not yet allocated)
    mov cx, [ds:bx + N_SIZE]    ; current size

    ; allocate heap space if first write
    test dx, dx
    jnz .wrt_has_base
    test cx, cx
    jnz .wrt_has_base
    push cs
    pop ds
    mov dx, [cs:heap_top]
    mov ax, FS_SEG
    mov ds, ax
    mov [ds:bx + N_DATA], dx

.wrt_has_base:
    ; write position = dx + cx
    mov ax, dx
    add ax, cx                  ; AX = write offset in heap

    ; switch to HEAP_SEG for writing — save ES (points to IBUF_SEG)
    push es
    push si
    push cx

    mov di, ax                  ; DI = write position in heap
    push ds
    mov ax, HEAP_SEG
    mov es, ax                  ; ES = heap
    pop ds                      ; DS still = FS_SEG — we need IBUF_SEG for src
    ; restore DS to IBUF_SEG for reading source
    pop cx
    pop si
    pop es                      ; ES = IBUF_SEG again

    ; now: ES:SI = source (IBUF_SEG), need HEAP_SEG:DI for dest
    ; use a second segment: put HEAP_SEG in DS temporarily
    push ds
    mov ax, HEAP_SEG
    mov ds, ax                  ; DS = HEAP_SEG (dest)
    ; read from ES:SI (IBUF_SEG), write to DS:DI (HEAP_SEG)
    push cx                     ; save current size

.wrt_copy:
    mov al, [es:si]
    test al, al
    jz .wrt_copy_done
    cmp al, 0x0D
    je .wrt_copy_done
    mov [ds:di], al
    inc si
    inc di
    inc cx
    jmp .wrt_copy

.wrt_copy_done:
    ; append CR LF
    mov byte [ds:di],   0x0D
    mov byte [ds:di+1], 0x0A
    add di, 2
    add cx, 2

    pop dx                      ; old size (we don't need it separately now)
    pop ds                      ; restore DS = FS_SEG

    ; update node size
    mov [ds:bx + N_SIZE], cx

    ; update heap_top
    push cs
    pop es
    mov ax, [cs:wrt_node]
    push ax
    mov ax, FS_SEG
    mov ds, ax
    pop ax
    ; recompute: new heap top = N_DATA + N_SIZE
    push bx
    mov bx, [cs:wrt_node]
    mov ax, bx
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR
    mov bx, ax
    mov ax, FS_SEG
    mov ds, ax
    mov ax, [ds:bx + N_DATA]
    add ax, [ds:bx + N_SIZE]
    pop bx
    mov bx, [cs:heap_top]
    cmp ax, bx
    jle .no_htop_update
    mov [cs:heap_top], ax
.no_htop_update:

    pop ds
    pop bx                      ; restore wrt_node saved bx

    ; ---- log to bin.dish ---------------------------------------------------
    push cs
    pop ds
    mov si, msg_wrt_cmd
    call log_to_bin_dish
    push cs
    pop ds
    mov si, arg_buf
    call log_to_bin_dish
    push cs
    pop ds
    mov si, msg_log_newline
    call log_to_bin_dish

    ; ---- confirm -----------------------------------------------------------
    push cs
    pop ds
    mov si, msg_wrt_ok
    call print_white
    push cs
    pop ds
    mov si, arg_buf
    call print_white
    push cs
    pop ds
    mov si, msg_crlf
    call print_white
    jmp .wrt_done

.wrt_no_content:
    pop es
    push cs
    pop ds
    mov si, msg_wrt_usage
    call print_white
    jmp .wrt_done

.wrt_notfound:
    push cs
    pop ds
    mov si, msg_notfound
    call print_white
    jmp .wrt_done

.wrt_isdir:
    push cs
    pop ds
    mov si, msg_isdir
    call print_white
    jmp .wrt_done

.wrt_usage:
    push cs
    pop ds
    mov si, msg_wrt_usage
    call print_white

.wrt_done:
    pop ds
    popa
    ret

wrt_node    dw 0                ; scratch: node index being written to


; ---------------------------------------------------------------------------
; CMD_DO_TREE — print full filesystem tree from root
;
; Strategy: two nested passes.
;   Outer pass: iterate node indices 0..N-1.
;   For each node, compute its depth by chasing parent pointers.
;   Build the line prefix by examining each ancestor level:
;     - for indent columns (level < depth): print "│   " if that ancestor
;       is NOT the last sibling, else "    "
;     - for the branch column (level == depth): print "├── " or "└── "
;
; get_depth(node)  → walks parent chain, returns count in AX, fills
;                    anc_chain[] with the ancestor node indices
; is_last(node)    → scans all nodes for a sibling with same parent and
;                    higher index; returns ZF=1 if last
; ---------------------------------------------------------------------------
cmd_do_tree:
    pusha

    mov si, msg_tree_root
    call print_cyan

    ; load total node count into tree_count
    push es
    mov ax, FS_SEG
    mov es, ax
    mov ax, [es:6]
    pop es
    mov [cs:tree_count], ax

    xor bx, bx                  ; BX = current node index

.each_node:
    mov ax, [cs:tree_count]
    cmp bx, ax
    jge .tree_done

    ; ---- get depth and ancestor chain for node BX --------------------------
    ; anc_chain[0] = BX, anc_chain[1] = parent(BX), ...
    ; anc_depth = number of entries - 1  (root-level nodes have depth 0)
    push bx
    xor di, di                  ; DI = chain length
    mov ax, bx

.anc_loop:
    cmp di, 16
    jge .anc_done
    mov si, di
    shl si, 1
    mov [cs:anc_chain + si], ax  ; store this node in chain
    inc di

    ; get parent: offset = ax*64 + FS_HDR + N_PARENT
    push di
    push es
    mov si, NODE_SIZE
    xor dx, dx
    mul si
    add ax, FS_HDR + N_PARENT
    mov si, ax
    mov dx, FS_SEG
    mov es, dx
    mov ax, [es:si]              ; AX = parent index
    pop es
    pop di

    cmp ax, 0xFFFF
    jne .anc_loop

.anc_done:
    ; DI = depth+1  (chain length)
    ; anc_chain[0]=this node, anc_chain[di-1]=topmost (root-level) node
    ; depth = di - 1
    mov [cs:anc_depth], di
    pop bx

    ; ---- print indent prefix for each column --------------------------------
    ; columns 0 .. depth-2: vertical bar or space
    ; column  depth-1: branch char (├── or └──)
    ; root-level nodes (depth=0): no prefix at all

    mov di, [cs:anc_depth]
    dec di                      ; DI = depth (0 = root-level)
    jz .branch_col              ; depth 0: skip indent columns

    ; indent columns: iterate level 0 .. depth-2
    ; at column level L, the ancestor is anc_chain[depth-1-L]
    xor si, si                  ; SI = column level (0 = leftmost)

.col_loop:
    mov ax, di
    dec ax                      ; ax = depth-1
    cmp si, ax
    jge .col_done               ; stop before branch column

    ; ancestor index for this column = anc_chain[depth-1-si]
    push ax
    sub ax, si                  ; ax = depth-1-si
    shl ax, 1
    mov bx, ax
    mov ax, [cs:anc_chain + bx] ; AX = ancestor node index
    pop dx                      ; discard

    push bx
    push cx
    push di
    push si
    call node_is_last           ; ZF=1 if AX is last child
    pop si
    pop di
    pop cx
    pop bx

    jz .col_space               ; last child at this level → space column
    push si
    mov si, p_vbar_gap
    call print_white
    pop si
    jmp .col_next
.col_space:
    push si
    mov si, p_gap
    call print_white
    pop si
.col_next:
    inc si
    jmp .col_loop

.col_done:
.branch_col:
    ; branch column: ├── or └──  (only for depth > 0)
    test di, di
    jz .print_name

    push bx
    push cx
    push di
    mov ax, bx
    call node_is_last           ; ZF=1 if BX is last child
    pop di
    pop cx
    pop bx

    jz .branch_last
    mov si, p_mid               ; ├──
    jmp .branch_print
.branch_last:
    mov si, p_last              ; └──
.branch_print:
    call print_white

.print_name:
    ; print name from FS_SEG
    push bx
    push es
    mov ax, bx
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR + N_NAME
    mov si, ax
    mov ax, FS_SEG
    mov es, ax
.name_lp:
    mov al, [es:si]
    test al, al
    jz .name_end
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
    int 0x10
    inc si
    jmp .name_lp
.name_end:
    pop es
    pop bx

    ; print "/" suffix for directories
    push bx
    push es
    mov ax, bx
    mov cx, NODE_SIZE
    xor dx, dx
    mul cx
    add ax, FS_HDR + N_TYPE
    mov si, ax
    mov ax, FS_SEG
    mov es, ax
    mov al, [es:si]
    pop es
    pop bx
    cmp al, 1
    jne .no_slash
    push si
    mov si, p_slash
    call print_white
    pop si
.no_slash:
    mov si, p_crlf
    call print_white

    inc bx
    jmp .each_node

.tree_done:
    popa
    ret


; ---------------------------------------------------------------------------
; node_is_last — is node AX the last sibling among children of its parent?
;   IN:  AX = node index
;   OUT: ZF=1 → yes (last or only child)
;        ZF=0 → no  (a sibling with higher index exists)
;   Preserves: BX CX DX SI DI ES
; ---------------------------------------------------------------------------
node_is_last:
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; get parent of AX → DX
    push ax
    mov bx, NODE_SIZE
    xor dx, dx
    mul bx
    add ax, FS_HDR + N_PARENT
    mov bx, FS_SEG
    mov es, bx
    mov si, ax
    mov dx, [es:si]             ; DX = parent of queried node
    pop ax                      ; AX = queried node index

    mov [cs:nil_self], ax       ; save our index for comparison
    mov cx, [es:6]              ; CX = total node count
    xor bx, bx                  ; BX = scan index

.nil_scan:
    cmp bx, cx
    jge .nil_last               ; no higher-index sibling found → last

    cmp bx, [cs:nil_self]
    je .nil_next                ; skip self

    ; get parent of BX
    push ax
    push cx
    mov ax, bx
    mov cx, NODE_SIZE
    xor si, si
    mul cx
    add ax, FS_HDR + N_PARENT
    mov si, ax
    mov ax, [es:si]             ; parent of BX
    pop cx
    pop ax

    cmp ax, dx                  ; same parent as ours?
    jne .nil_next
    cmp bx, [cs:nil_self]       ; higher index than us?
    jle .nil_next
    ; found a later sibling → NOT last → ZF=0
    jmp .nil_not_last

.nil_next:
    inc bx
    jmp .nil_scan

.nil_last:
    xor si, si                  ; set ZF = 1
    test si, si
    jmp .nil_done

.nil_not_last:
    xor si, si
    inc si                      ; ZF = 0
    test si, si

.nil_done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; tree working storage
anc_chain   times 16 dw 0       ; ancestor node index chain
anc_depth   dw 0                ; length of chain (depth+1)
tree_count  dw 0                ; total node count snapshot
nil_self    dw 0                ; scratch for node_is_last


; ---------------------------------------------------------------------------
; CMD_DO_QUIT; ---------------------------------------------------------------------------
; CMD_DO_QUIT — shut down via APM BIOS (INT 15h, AX=5307h)
; Falls back to triple-fault halt if APM not available.
; ---------------------------------------------------------------------------
cmd_do_quit:
    mov si, msg_goodbye
    call print_white

    ; Try APM 1.x power-off: AX=5307h, BX=0001h (all devices), CX=0003h (off)
    mov ax, 0x5307
    mov bx, 0x0001
    mov cx, 0x0003
    int 0x15
    ; If we're still here APM failed — try ACPI shutdown port (QEMU/Bochs)
    mov dx, 0x604
    mov ax, 0x2000
    out dx, ax
    ; Still here? Load a null IDT and triple-fault
    lidt [cs:null_idt]
    int 3
null_idt:
    dw 0
    dd 0


; ---------------------------------------------------------------------------
; CMD_DO_MKDIR — create a directory in cwd
;   DS:SI = argument string
; ---------------------------------------------------------------------------
cmd_do_mkdir:
    pusha
    push ds

    call get_arg

    push cs
    pop es
    mov al, [es:arg_buf]
    test al, al
    jz .mkdir_usage

    ; create dir node under cwd
    mov ax, [cs:cwd_idx]
    push cs
    pop ds
    mov si, arg_buf
    mov bl, 1                   ; type = directory
    call mk_node

    ; log to bin.dish
    push cs
    pop ds
    mov si, msg_mkdir_cmd
    call log_to_bin_dish
    push cs
    pop ds
    mov si, arg_buf
    call log_to_bin_dish
    push cs
    pop ds
    mov si, msg_log_newline
    call log_to_bin_dish

    push cs
    pop ds
    mov si, msg_mkdir_ok
    call print_white
    push cs
    pop ds
    mov si, arg_buf
    call print_white_ds_cs
    push cs
    pop ds
    mov si, msg_crlf
    call print_white
    jmp .mkdir_done

.mkdir_usage:
    push cs
    pop ds
    mov si, msg_mkdir_usage
    call print_white

.mkdir_done:
    pop ds
    popa
    ret


; ---------------------------------------------------------------------------
; CMD_DO_CRTUSR — create a new user under Users/ (node 0)
;   Creates: Users/<name>/  Users/<name>/home  Users/<name>/documents
;   DS:SI = argument string (username)
; ---------------------------------------------------------------------------
cmd_do_crtusr:
    pusha
    push ds

    call get_arg

    push cs
    pop es
    mov al, [es:arg_buf]
    test al, al
    jz .crtusr_usage

    ; create Users/<name>/ dir — parent = node 0 (Users)
    mov ax, 0                   ; parent = Users node
    push cs
    pop ds
    mov si, arg_buf
    mov bl, 1
    call mk_node
    ; AX = new user dir index — save it
    mov [cs:tmp_node], ax

    ; create Users/<name>/home — parent = new user dir
    mov ax, [cs:tmp_node]
    push cs
    pop ds
    mov si, s_home
    mov bl, 0
    call mk_node

    ; create Users/<name>/documents — parent = new user dir
    mov ax, [cs:tmp_node]
    push cs
    pop ds
    mov si, s_documents
    mov bl, 0
    call mk_node

    ; log to bin.dish
    push cs
    pop ds
    mov si, msg_crtusr_cmd
    call log_to_bin_dish
    push cs
    pop ds
    mov si, arg_buf
    call log_to_bin_dish
    push cs
    pop ds
    mov si, msg_log_newline
    call log_to_bin_dish

    push cs
    pop ds
    mov si, msg_crtusr_ok
    call print_white
    push cs
    pop ds
    mov si, arg_buf
    call print_white_ds_cs
    push cs
    pop ds
    mov si, msg_crlf
    call print_white
    jmp .crtusr_done

.crtusr_usage:
    push cs
    pop ds
    mov si, msg_crtusr_usage
    call print_white

.crtusr_done:
    pop ds
    popa
    ret

tmp_node    dw 0                ; scratch storage for new node index


; ---------------------------------------------------------------------------
; print_white_ds_cs — print CS:arg_buf null-terminated (convenience wrapper)
; ---------------------------------------------------------------------------
print_white_ds_cs:
    push si
    mov si, arg_buf
    call print_white
    pop si
    ret


; ---------------------------------------------------------------------------
; log_to_bin_dish — append CS:SI string to node 10 (bin.dish) in heap
; modifies: nothing visible (saves all registers)
; ---------------------------------------------------------------------------
log_to_bin_dish:
    pusha
    push ds
    push es

    ; get current heap offset and size for node 10
    push si
    mov ax, FS_SEG
    mov ds, ax
    mov bx, FS_HDR + 10 * NODE_SIZE     ; node 10 base

    mov dx, [ds:bx + N_DATA]    ; current heap offset (0 = not yet allocated)
    mov cx, [ds:bx + N_SIZE]    ; current size

    ; if data_off == 0 and size == 0, allocate from end of used heap
    ; we track heap top in heap_top variable
    test dx, dx
    jnz .has_base
    test cx, cx
    jnz .has_base

    ; allocate: set data_off = heap_top
    push cs
    pop es
    mov dx, [es:heap_top]
    mov [ds:bx + N_DATA], dx

.has_base:
    ; write CS:SI into HEAP_SEG at offset (dx + cx)
    pop si
    push si

    mov ax, dx
    add ax, cx                  ; write position = base + current_size
    push ax

    mov ax, HEAP_SEG
    mov es, ax

    pop di                      ; DI = write offset in heap
    push cs
    pop ds

.write_lp:
    mov al, [ds:si]
    test al, al
    jz .write_done
    mov [es:di], al
    inc si
    inc di
    inc cx                      ; size++
    jmp .write_lp

.write_done:
    ; update size in node 10
    mov ax, FS_SEG
    mov ds, ax
    mov [ds:bx + N_SIZE], cx

    ; update heap_top
    push cs
    pop es
    mov ax, [es:heap_top]
    ; heap_top only moves if we just allocated (first write)
    ; simpler: just set heap_top = data_off + size (only grows)
    mov ax, dx
    add ax, cx
    ; only update if bigger
    push ax
    mov bx, [es:heap_top]
    cmp ax, bx
    jle .no_update
    mov [es:heap_top], ax
.no_update:
    pop ax

    pop si

    pop es
    pop ds
    popa
    ret

heap_top dw 0x0010              ; start heap at offset 16 (leave room for magic)


; ---------------------------------------------------------------------------
; print_white_ds — print null-terminated string at DS:SI
; (like print_white but DS-relative, not CS-relative)
; ---------------------------------------------------------------------------
print_white_ds:
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
.lp:
    mov al, [ds:si]
    test al, al
    jz .dn
    int 0x10
    inc si
    jmp .lp
.dn:
    ret


; ---------------------------------------------------------------------------
; print_cyan / print_white — CS:SI null-terminated
; ---------------------------------------------------------------------------
print_cyan:
    mov ah, 0x0E
    mov bl, 0x0B
    xor bh, bh
.lp: mov al, [cs:si]
    test al, al
    jz .dn
    int 0x10
    inc si
    jmp .lp
.dn: ret

print_white:
    mov ah, 0x0E
    mov bl, 0x0F
    xor bh, bh
.lp: mov al, [cs:si]
    test al, al
    jz .dn
    int 0x10
    inc si
    jmp .lp
.dn: ret


; ===========================================================================
; Shell state
; ===========================================================================
cwd_idx     dw 0xFFFF           ; current dir (0xFFFF = root)

; ===========================================================================
; Command strings
; ===========================================================================
cmd_help    db "help", 0
cmd_cd      db "cd", 0
cmd_crt     db "crt", 0
cmd_cat     db "cat", 0
cmd_ls      db "ls", 0
cmd_quit    db "quit", 0
cmd_mkdir   db "mkdir", 0
cmd_crtusr  db "crtusr", 0
cmd_tree    db "tree", 0
cmd_wrt     db "wrt", 0

; ===========================================================================
; Messages
; ===========================================================================
msg_prompt_arrow    db " > ", 0
msg_slash           db "/", 0
msg_crlf            db 13, 10, 0
msg_log_newline     db 13, 10, 0
s_whitetail         db "whitetail", 0

msg_welcome:
    db 13, 10
    db "  dish shell  |  type 'help' for commands", 13, 10, 0

msg_help_hint:
    db 0

msg_help_text:
    db 13, 10
    db "  Commands:", 13, 10
    db "    ls               list files in current directory", 13, 10
    db "    cd <dir>         change directory (cd .. to go up)", 13, 10
    db "    mkdir <n>     create a new directory", 13, 10
    db "    crt <n>       create a new file", 13, 10
    db "    cat <n>       print contents of a file", 13, 10
    db "    wrt <n> <txt> write text to a file", 13, 10
    db "    crtusr <n>    create a new user in Users/", 13, 10
    db "    quit             shut down the system", 13, 10
    db "    tree             show full filesystem tree", 13, 10
    db "    help             show this message", 13, 10
    db "  Commands logged to Root/source/bin.dish", 13, 10
    db 0

msg_unknown      db "  unknown command. type 'help'", 13, 10, 0
msg_notfound     db "  not found", 13, 10, 0
msg_notdir       db "  not a directory", 13, 10, 0
msg_isdir        db "  is a directory", 13, 10, 0
msg_empty_file   db "  (empty file)", 13, 10, 0
msg_created      db "  created: ", 0
msg_crt_usage    db "  usage: crt <filename>", 13, 10, 0
msg_cat_usage    db "  usage: cat <filename>", 13, 10, 0
msg_crt_cmd      db "crt ", 0
msg_mkdir_cmd    db "mkdir ", 0
msg_crtusr_cmd   db "crtusr ", 0
msg_mkdir_ok     db "  created dir: ", 0
msg_crtusr_ok    db "  created user: ", 0
msg_mkdir_usage  db "  usage: mkdir <dirname>", 13, 10, 0
msg_crtusr_usage db "  usage: crtusr <username>", 13, 10, 0
msg_wrt_ok       db "  written to: ", 0
msg_wrt_usage    db "  usage: wrt <filename> <text>", 13, 10, 0
msg_wrt_cmd      db "wrt ", 0
msg_goodbye      db 13, 10, "  Shutting down...", 13, 10, 0

; Tree prefix strings (CP437 box-drawing)
p_vbar_gap: db 179, "   ", 0        ; │   (vertical bar + 3 spaces)
p_mid:      db 195, 196, 196, " ", 0 ; ├──
p_last:     db 192, 196, 196, " ", 0 ; └──
p_gap:      db "    ", 0             ; 4 spaces (blank column)
p_slash:    db "/", 0
p_crlf:     db 13, 10, 0
msg_tree_root: db 13, 10, "whitetail/", 13, 10, 0

; ===========================================================================
; FS node name strings
; ===========================================================================
s_Users:        db "Users", 0
s_usr:          db "usr", 0
s_home:         db "home", 0
s_documents:    db "documents", 0
s_Root:         db "Root", 0
s_source:       db "source", 0
s_kbak:         db "kernel-backup.bin", 0
s_bbak:         db "bootloader-backup.bin", 0
s_copy:         db "copyright.txt", 0
s_log:          db "log.log", 0
s_bin_dish:     db "bin.dish", 0

; ===========================================================================
; Logo
; ===========================================================================
msg_logo:
    db "         88                                                         ", 13, 10
    db "         88                                                         ", 13, 10
    db "         88                                                         ", 13, 10
    db " ,adPPYb,88  ,adPPYba,  ,adPPYba, 8b,dPPYba,     ,adPPYba,  ,adPPYba,  ", 13, 10
    db 97, 56, 34, 32, 32, 32, 32, 96, 89, 56, 56, 32, 97, 56, 80, 95, 95, 95, 95, 95, 56, 56, 32, 97, 56, 80, 95, 95, 95, 95, 95, 56, 56, 32, 56, 56, 80, 39, 32, 32, 32, 34, 89, 56, 32, 32, 32, 32, 97, 56, 34, 32, 32, 32, 32, 32, 34, 56, 97, 32, 73, 56, 91, 32, 32, 32, 32, 34, 34, 32, 32, 13, 10
    db 56, 98, 32, 32, 32, 32, 32, 32, 32, 56, 56, 32, 56, 80, 80, 34, 34, 34, 34, 34, 34, 34, 32, 56, 80, 80, 34, 34, 34, 34, 34, 34, 34, 32, 56, 56, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 56, 98, 32, 32, 32, 32, 32, 32, 32, 100, 56, 32, 32, 96, 34, 89, 56, 98, 97, 44, 32, 32, 32, 13, 10
    db 34, 56, 97, 44, 32, 32, 32, 44, 100, 56, 56, 32, 34, 56, 98, 44, 32, 32, 32, 44, 97, 97, 32, 34, 56, 98, 44, 32, 32, 32, 44, 97, 97, 32, 56, 56, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 34, 56, 97, 44, 32, 32, 32, 44, 97, 56, 34, 32, 97, 97, 32, 32, 32, 32, 93, 56, 73, 32, 32, 13, 10
    db 32, 96, 34, 56, 98, 98, 100, 80, 34, 89, 56, 32, 32, 96, 34, 89, 98, 98, 100, 56, 34, 39, 32, 96, 34, 89, 98, 98, 100, 56, 34, 39, 32, 56, 56, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 34, 89, 98, 98, 100, 80, 34, 39, 32, 32, 96, 34, 89, 98, 98, 100, 80, 34, 39, 32, 32, 13, 10
    db 0
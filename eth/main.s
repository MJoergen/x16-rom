; This implements device 9, which is LOAD/SAVE over UDP.
; This implements just the very simple:
; * Send to named channel (aka SAVE)
; * Receive from named channel (aka LOAD)
; The lower protocol used is TFTP
; Any additional functionality is provided by modifying the TFTP server.
;
; The general TALK/LISTEN API is decribed in https://www.pagetable.com/?p=1031
; The sequence of events is as follows:
;  1. LISTN (FA=$08)
;  2. SECND (SA=$F0 or $F1)
;  3. CIOUT (filename)
;  4. UNLSN
;
;    LOADING:             SAVING:
;  5. TALK (FA=$08)     5. LISTN (FA=$08)
;  6. TKSA (SA=$60)     6. SECND (SA=$61)
;  7. ACPTR             7. CIOUT
;  8. UNTLK             8. UNLSN
;
;  9. LISTN (FA=$08)
; 10. SECND (SA=$E0 or $E1)
; 11. UNLSN
;
; Steps 1-4 are used for opening the file.
; Steps 5-8 are used for transferring file contents.
; Steps 9-11 are used for closing the file.
;
; This block is meant to be as simple as possible.
; In particular, it does not support multiple open files.
; It does not support the command channel either.
; The main reason for this is that the TFTP protocol is so simple.

.include "banks.inc"

.setcpu "65c02"
.importzp read_blkptr, write_blkptr, bank_save

.import tftp_init                         ; Initialize TFTP client
.import tftp_load                         ; Send RRQ,  and wait for DATA
.import tftp_read                         ; Send ACK,  and wait for DATA
.import tftp_save                         ; Send WRQ,  and wait for ACK
.import tftp_write                        ; Send DATA, and wait for ACK
.import tftp_ack                          ; Send ACK,  but don't wait for DATA


; ------------------------------------------------
; -- Jump table, referenced in kernal/serial4.0.s
; ------------------------------------------------

.segment "eth"

      jmp eth_secnd
      jmp eth_tksa
      jmp eth_acptr
      jmp eth_ciout
      jmp eth_untlk
      jmp eth_unlsn
      jmp eth_listn
      jmp eth_talk


STATUS_TIMEOUT = $02
STATUS_EOF     = $40

; -----------------------
; -- RAM bank switching
; -----------------------

via1         = $9f60
via1porta    = via1+1                   ; RAM bank
ETH_RAM_BANK = $fe

.macro BANKING_START
      pha
      lda via1porta
      sta bank_save
      lda #ETH_RAM_BANK
      sta via1porta
      pla
.endmacro

.macro BANKING_END
      pha
      lda bank_save
      sta via1porta
      pla
.endmacro


.segment "eth_data"

buffer:
      .res 256, 0
buffer_hi:
      .res 256, 0

; number of valid data bytes in each buffer
buffer_len:
      .res 2

; current r/w pointer within the buffer
buffer_ptr:
      .res 2


save_x:
      .byte 0
save_y:
      .byte 0
listen_addr:
      .byte 0

; $ff = after transmitting the contents of this buffer,
;       there won't be more
is_last_block:
      .byte 0

file_status:
      .byte 0


.segment "eth"


; -----------------------
; -- TALK
; -----------------------

eth_talk:
      rts


; -----------------------
; -- SECOND, after TALK
; -----------------------

eth_tksa:
      rts


; -----------------------
; -- UNTALK
; -----------------------

eth_untlk:
      rts


; -----------------------
; -- LISTEN
; -----------------------

eth_listn:
      BANKING_START
      stx save_x
      sty save_y

      ; Clear buffer
      stz buffer_len
      stz buffer_len+1
      stz buffer_ptr
      stz buffer_ptr+1
      stz listen_addr
      stz is_last_block
      stz file_status

      ldx save_x
      ldy save_y
      BANKING_END
      rts


; ------------------------
; -- SECOND, after LISTEN
; ------------------------

eth_secnd: ; after listen
      BANKING_START
      stx save_x
      sty save_y

      ; If it's $Fx, the bytes sent by the host until UNLISTEN
      ; will be a filename to be associated with channel x.
      ; Otherwise, we need to receive into channel x.

      sta listen_addr ; we need it for UNLISTEN

      ldx save_x
      ldy save_y
      BANKING_END
      rts


; -----------------------
; -- UNLISTEN
; -----------------------

eth_unlsn:
      BANKING_START
      stx save_x
      sty save_y

      ; $F0 is used for LOAD, and $F1 is used for SAVE
      lda listen_addr
      and #$f0
      cmp #$f0
      beq @unlsn_open

      cmp #$e0
      beq @unlsn_end                      ; After close we do nothing.

      ; Check if we need to clean up after a SAVE
      lda listen_addr
      and #$0f
      cmp #$01
      bne @unlsn_end

      ldx #<buffer                        ; Set address of buffer
      lda #>buffer
      stx write_blkptr
      sta write_blkptr + 1

      ldx buffer_ptr                      ; Set length of buffer
      lda buffer_ptr+1
      jsr tftp_write                      ; Send contents of buffer to server
      bcc @unlsn_end

      lda #STATUS_TIMEOUT
      sta status

      ; otherwise UNLISTEN does nothing
@unlsn_end:
      ldy save_y
      ldx save_x
      BANKING_END
      rts

@unlsn_open:
      jsr tftp_init

      ldy buffer_ptr
      lda #0
      sta buffer,y                     ; zero-terminate filename

      ldx #<buffer                     ; Send filename to server
      lda #>buffer
      stx write_blkptr
      sta write_blkptr+1

      lda listen_addr                  ; 0 is LOAD, 1 is SAVE
      and #$0f
      beq @unlsn_load
      jsr tftp_save                    ; Send filename and wait for ack
      bcc @unlsn_end
@error:
      lda #STATUS_TIMEOUT
      sta status
      bra @unlsn_end

@unlsn_load:
      ldx #<buffer                     ; Response from server goes into buffer
      lda #>buffer
      stx read_blkptr
      sta read_blkptr+1
      stz buffer_ptr
      stz buffer_ptr+1

      jsr tftp_load                    ; Send filename and wait for data
      bcs @error
      stx buffer_len
      sta buffer_len+1

      stz is_last_block
      cmp #2                           ; Is this the last block ?
      beq @unlsn_end                   ; No

      lda #$ff                         ; Indicate last block and send ACK to server.
      sta is_last_block
      jsr tftp_ack
      bra @unlsn_end


; -----------------------
; -- SEND
; -----------------------

eth_ciout:
      BANKING_START
      stx save_x
      sty save_y

      ; Store byte in buffer

      ldy buffer_ptr + 1
      bne @ciout2
; halfblock 0
      ldy buffer_ptr
      sta buffer,y
      inc buffer_ptr
      bne @eth_ciout_end
      inc buffer_ptr + 1

@eth_ciout_end:
      ldx save_x
      ldy save_y
      BANKING_END
      rts

@ciout2:
; halfblock 1
      ldy buffer_ptr
      sta buffer_hi,y
      inc buffer_ptr
      bne @eth_ciout_end

      ; We now have a full buffer.
      ; If it's $Fx, the bytes sent by the host until UNLISTEN
      ; will be a filename to be associated with channel x.
      ; So just ignore any further bytes.
      lda listen_addr
      bmi @eth_ciout_end

      ldx #<buffer                        ; Set address of buffer
      lda #>buffer
      stx write_blkptr
      sta write_blkptr + 1

      lda #2                              ; Set length of buffer
      ldx #0
      jsr tftp_write                      ; Send contents of buffer to server
      bcs @error

      stz buffer_ptr                      ; Reset buffer
      stz buffer_ptr+1
      bra @eth_ciout_end

@error:
      lda #STATUS_TIMEOUT
      sta status
      bra @eth_ciout_end


; -----------------------
; -- RECEIVE
; -----------------------

eth_acptr:
      BANKING_START
      stx save_x
      sty save_y

      lda file_status
      beq @eth_acptr_status_ok         ; More data

@eth_acptr_status:
      ; Store status
      sta status
      lda #0

      ldy save_y
      ldx save_x
      BANKING_END
      sec                              ; Indicate byte invalid
      rts

@eth_acptr_error:
      lda #STATUS_TIMEOUT
      bra @eth_acptr_status

@eth_acptr_status_ok:
      ; no data in buffer? read more
      lda buffer_len
      ora buffer_len + 1
      bne @eth_acptr_buffer_ok

      ldx #<buffer
      lda #>buffer
      stx read_blkptr
      sta read_blkptr + 1
      jsr tftp_read
      bcs @eth_acptr_error

      stx buffer_len
      sta buffer_len + 1

      stz is_last_block
      cmp #2                           ; Is this the last block ?
      beq @eth_acptr_buffer_ok
      lda #$ff
      sta is_last_block
      jsr tftp_ack

@eth_acptr_buffer_ok:
      ; Read byte from buffer
      ldy buffer_ptr + 1
      bne @eth_acptr1
; halfblock 0
      ldy buffer_ptr
      lda buffer,y
      bra @eth_acptr2
@eth_acptr1:
; halfblock 1
      ldy buffer_ptr
      lda buffer_hi,y

@eth_acptr2:
      pha                              ; Store byte just read

      ; Update pointers
      inc buffer_ptr
      bne :+
      inc buffer_ptr + 1
:
      ; Check if buffer is consumed
      lda buffer_ptr + 1
      cmp buffer_len + 1
      bne @eth_acptr3                  ; More bytes in buffer
      lda buffer_ptr
      cmp buffer_len
      bne @eth_acptr3

; buffer exhausted
      lda is_last_block
      bmi @eth_acptr4

; read another block next time
      stz buffer_len
      stz buffer_len + 1
      stz buffer_ptr
      stz buffer_ptr + 1
      bra @eth_acptr3

@eth_acptr4:
      lda #STATUS_EOF                  ; next time, send EOF
      sta file_status

@eth_acptr3:
      pla                              ; Retrieve byte just read

@eth_acptr_end:
      ldy save_y
      ldx save_x
      BANKING_END
      clc                              ; Indicate byte valid
      rts

; ETH's entry into jsrfar
.setcpu "65c02"
d1prb	=via1+0
d1pra	=via1+1
.export bjsrfar
bjsrfar:
.include "jsrfar.inc"


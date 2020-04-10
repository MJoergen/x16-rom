; This implements a TFTP client (RFC 1350)
; The API is fully synchronous.

.setcpu "65c02"

; Exported API
.export tftp_init                         ; Initialize TFTP client
.export tftp_load                         ; Send RRQ,  and wait for DATA
.export tftp_read                         ; Send ACK,  and wait for DATA
.export tftp_save                         ; Send WRQ,  and wait for ACK
.export tftp_write                        ; Send DATA, and wait for ACK
.export tftp_ack                          ; Send ACK,  but don't wait for DATA

; From lower layer (UDP)
.import eth_init                          ; Start Ethernet listener
.import eth_udp_set_my_port               ; UDP port number to listen on
.import eth_udp_set_server_port           ; UDP port number on server
.import eth_udp_register_rx_callback      ; Callback for received UDP packets
.import eth_udp_register_tx_callback      ; Callback when sending UDP packets
.import eth_udp_tx                        ; Send UDP packet
.import eth_rx_poll
.import eth_get_jiffies
.import eth_server_ip_resolve

.import eth_server_ip
.include "ethernet.inc"                   ; eth_rx_dat, eth_tx_dat

; From higher layer (kernal)
.importzp read_blkptr, write_blkptr



TFTP_OPCODE_RRQ   = 1
TFTP_OPCODE_WRQ   = 2
TFTP_OPCODE_DATA  = 3
TFTP_OPCODE_ACK   = 4
TFTP_OPCODE_ERROR = 5

.segment "eth_data"

tftp_timeout:        .res 1
tftp_retries:        .res 1
tftp_buffer_len:     .res 2
tftp_expect_block:   .res 2
tftp_opcode:         .res 1
tftp_error:          .res 1
tftp_got_ack:        .res 1

.segment "eth"


;---------------------------------------------------------------------
; -- Initialize TFTP
; -- Input: None
; -- Output:
; -- Carry clear : OK.
; -- Carry set   : Could not resolve servers IP address
;---------------------------------------------------------------------
tftp_init:
      jsr eth_init                        ; Initialize ethernet port

      lda #$4D                            ; 'M'
      ldx #$4A                            ; 'J'
      jsr eth_udp_set_my_port             ; UDP port number to listen on

      lda #0                              ;
      ldx #69                             ;
      jsr eth_udp_set_server_port         ; UDP port number on server

      lda #>tftp_rx_callback
      ldx #<tftp_rx_callback
      jsr eth_udp_register_rx_callback    ; Callback for received UDP packets

      lda #>tftp_tx_callback
      ldx #<tftp_tx_callback
      jsr eth_udp_register_tx_callback    ; Callback when sending UDP packets

.if 1
      ; Reset server IP address to 192.168.1.3. TBD
      lda #$c0
      sta eth_server_ip
      lda #$a8
      sta eth_server_ip+1
      lda #$01
      sta eth_server_ip+2
      lda #$03
      sta eth_server_ip+3
.else
      ; Reset server IP address to 10.100.1.86. TBD
      lda #$0a
      sta eth_server_ip
      lda #$64
      sta eth_server_ip+1
      lda #$02
      sta eth_server_ip+2
      lda #$a0
      sta eth_server_ip+3
.endif

      jmp eth_server_ip_resolve           ; Get server MAC address


; -------------------------------------------
; -- Send RRQ, and wait for DATA
; -- Input:
; -- (write_blkptr) points to zero-terminated filename
; -- (read_blkptr) points to receive buffer
; -- Output:
; -- Carry clear : OK. A:X contains number of received bytes.
; -- Carry set   : Timeout
; -------------------------------------------
tftp_load:
      lda #TFTP_OPCODE_RRQ
      sta tftp_opcode                     ; Which opcode to send
      jsr eth_udp_tx                      ; Send RRQ

      lda #1
      sta tftp_expect_block               ; Which block # to expect
      stz tftp_expect_block+1

      jmp tftp_wait_for_data


; -------------------------------------------
; -- Send ACK, but don't wait for DATA
; -- Input: tftp_expect_block contains the last received block number
; -- Output:
; -------------------------------------------
tftp_ack:
      lda #TFTP_OPCODE_ACK
      sta tftp_opcode                     ; Which opcode to send
      jmp eth_udp_tx                      ; Send ACK


; -------------------------------------------
; -- Send ACK, and wait for DATA
; -- Input: tftp_expect_block contains the last received block number
; -- Output:
; -- Carry clear : OK. A:X contains number of received bytes.
; -- Carry set   : Timeout
; -------------------------------------------
tftp_read:
      lda #TFTP_OPCODE_ACK
      sta tftp_opcode                     ; Which opcode to send
      jsr eth_udp_tx                      ; Send ACK

      inc tftp_expect_block
      bne @tftp_read_data
      inc tftp_expect_block+1

@tftp_read_data:
      jmp tftp_wait_for_data


; -------------------------------------------
; -- Send WRQ, and wait for ACK
; -------------------------------------------
tftp_save:
      lda #TFTP_OPCODE_WRQ
      sta tftp_opcode                     ; Which opcode to send
      jsr eth_udp_tx                      ; Send WRQ

      stz tftp_expect_block               ; Which block # to expect
      stz tftp_expect_block+1

      jmp tftp_wait_for_ack


; -------------------------------------------
; -- Send DATA, and wait for ACK
; -- Input:
; -- (write_blkptr) points to data to be sent
; -- A:X contains number of bytes
; -- Output:
; -- Carry clear : OK.
; -- Carry set   : Timeout
; -------------------------------------------
tftp_write:
      stx tftp_buffer_len                 ; Store length of buffer
      sta tftp_buffer_len+1

      lda #TFTP_OPCODE_DATA
      sta tftp_opcode                     ; Which opcode to send

      inc tftp_expect_block               ; Increment block #
      bne @1
      inc tftp_expect_block+1
@1:

      jsr eth_udp_tx                      ; Send DATA
      jmp tftp_wait_for_ack


; ---------- INTERNAL ROUTINES --------------

; -------------------------------------------
; -- Wait for ACK
; -- Input: tftp_expect_block contains expected block number
; -- Output:
; -- Carry clear : OK.
; -- Carry set   : Timeout
; -------------------------------------------
tftp_wait_for_ack:
      stz tftp_error                      ; Clear any previous errors
      stz tftp_got_ack                    ; Haven't received ACK yet

      jsr eth_get_jiffies
      adc #60                             ; Don't bother clearing carry
      sta tftp_timeout                    ; Timeout approx 1 second.

@tftp_read_wait:
      jsr eth_rx_poll
      lda tftp_error
      bne @tftp_read_error

      ; Have we received the ack?
      lda tftp_got_ack
      bne @tftp_read_ok

      jsr eth_get_jiffies
      cmp tftp_timeout
      bne @tftp_read_wait

@tftp_read_error:
      sec                                 ; Timeout
      rts

@tftp_read_ok:
      clc
      rts


; -------------------------------------------
; -- Wait for DATA
; -- Input: tftp_expect_block contains expected block number
; -- (read_blkptr) points to receive buffer
; -- Output:
; -- Carry clear : OK. A:X contains number of received bytes.
; -- Carry set   : Timeout
; -------------------------------------------
tftp_wait_for_data:
      stz tftp_buffer_len                 ; Clear receive buffer
      stz tftp_buffer_len+1
      stz tftp_error                      ; Clear any previous errors

      jsr eth_get_jiffies
      adc #60                             ; Don't bother clearing carry
      sta tftp_timeout                    ; Timeout approx 1 second.

@tftp_read_wait:
      jsr eth_rx_poll
      lda tftp_error
      bne @tftp_read_error

      ; Have we received the data?
      lda tftp_buffer_len
      ora tftp_buffer_len+1
      bne @tftp_read_ok

      jsr eth_get_jiffies
      cmp tftp_timeout
      bne @tftp_read_wait

@tftp_read_error:
      sec                                 ; Timeout
      rts

@tftp_read_ok:
      ldx tftp_buffer_len
      lda tftp_buffer_len+1
      clc
      rts


; -------------------------------------------
; -- Called when we receive an UDP packet
; -- Input: A:X contains number of bytes in UDP payload.
; -- Output:
; -- write_blkptr
; -- Carry clear : OK. A:X contains number of received bytes.
; -- Carry set   : Timeout
; -------------------------------------------
tftp_rx_callback:
      pha                                 ; Store UDP payload length
      phx
      lda eth_rx_dat
      bne @tftp_rx_pop
      lda eth_rx_dat
      cmp #TFTP_OPCODE_DATA
      beq @tftp_rx_data
      cmp #TFTP_OPCODE_ACK
      beq @tftp_rx_ack

      lda #$ff                            ; Indicate error
      sta tftp_error

@tftp_rx_pop:
      plx
      pla
      rts

@tftp_rx_ack:
      lda eth_rx_dat                      ; Get received block number
      ldx eth_rx_dat

      cpx tftp_expect_block               ; Check if block number matches
      bne @tftp_rx_pop
      cmp tftp_expect_block+1
      bne @tftp_rx_pop

      lda #1                              ; Indicate we got the ACK
      sta tftp_got_ack
      bra @tftp_rx_pop

@tftp_rx_data:
      lda eth_rx_dat                      ; Get received block number
      ldx eth_rx_dat

      cpx tftp_expect_block               ; Check if block number matches
      bne @tftp_rx_pop
      cmp tftp_expect_block+1
      bne @tftp_rx_pop

      ; Calculate length of TFTP data
      pla
      sec
      sbc #4
      tax
      pla
      sbc #0
      stx tftp_buffer_len
      sta tftp_buffer_len+1

      ; Copy TFTP data
      ldy #0
@tftp_rx_block_first:      
      lda eth_rx_dat
      sta (read_blkptr),y
      iny
      bne @tftp_rx_block_first
      inc read_blkptr+1
@tftp_rx_block_second:
      lda eth_rx_dat
      sta (read_blkptr),y
      iny
      bne @tftp_rx_block_second
      rts


; -------------------------------------------
; Called before we send an UDP packet
; -------------------------------------------

tftp_tx_callback:
      lda tftp_opcode
      cmp #TFTP_OPCODE_RRQ
      beq @tftp_tx_rrq
      cmp #TFTP_OPCODE_WRQ
      beq @tftp_tx_wrq
      cmp #TFTP_OPCODE_ACK
      beq @tftp_tx_ack
      cmp #TFTP_OPCODE_DATA
      beq @tftp_tx_data
      rts

@tftp_tx_rrq:
@tftp_tx_wrq:
      stz eth_tx_dat                      ; Store TFTP opcode (RRQ or WRQ)
      sta eth_tx_dat

      ldy #$ff
@tftp_filename:                           ; Store TFTP filename
      iny
      lda (write_blkptr),y
      sta eth_tx_dat
      bne @tftp_filename

      ldy #$ff
@tftp_octet:                              ; Store string "octet\0"
      iny
      lda tftp_octet,y
      sta eth_tx_dat
      bne @tftp_octet
      rts

@tftp_tx_ack:
      stz eth_tx_dat                      ; Store TFTP opcode (ACK)
      sta eth_tx_dat

      ldx tftp_expect_block               ; Store TFTP block number
      lda tftp_expect_block+1
      sta eth_tx_dat
      stx eth_tx_dat
      rts

@tftp_tx_data:
      stz eth_tx_dat                      ; Store TFTP opcode (DATA)
      sta eth_tx_dat

      ldx tftp_expect_block               ; Store TFTP block number
      lda tftp_expect_block+1
      sta eth_tx_dat
      stx eth_tx_dat

      lda eth_tx_hi                       ; Store start of data
      pha
      lda eth_tx_lo
      pha

      ; Copy TFTP data
      ldy #0
@tftp_tx_block_first:
      lda (write_blkptr),y
      sta eth_tx_dat
      iny
      bne @tftp_tx_block_first
      inc write_blkptr+1
@tftp_tx_block_second:
      lda (write_blkptr),y
      sta eth_tx_dat
      iny
      bne @tftp_tx_block_second

      ; Adjust write pointer
      pla
      clc
      adc tftp_buffer_len
      sta eth_tx_lo
      pla
      adc tftp_buffer_len+1
      sta eth_tx_hi
      rts


tftp_octet: .byte "octet",0


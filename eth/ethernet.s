.setcpu "65c02"

; Ethernet protocol

; External API
.export eth_init
.export eth_rx_start
.export eth_rx_poll
.export eth_rx_check_len
.export eth_tx
.export eth_tx_pad
.export eth_tx_get_len
.export eth_tx_end
.export ethernet_insert_header

.import eth_arp_receive        ; arp.s
.import eth_ip_receive         ; ip.s
.import eth_my_mac             ; arp.s
.import eth_server_mac         ; arp.s

.include "ethernet.inc"


.segment "eth_data"
      eth_rx_len: .res 2   ; Length of last received frame
      eth_tx_end: .res 2   ; End of current transmitted frame

.segment "eth"

; -------------------------------------------------------------------
; Get ready to receive packets
; inputs: none
; outputs: none
eth_init:
eth_rx_start:
      lda #1
      sta eth_rx_own       ; Transfer ownership to FPGA
      rts


; -------------------------------------------------------------------
; Is a packet ready?
; inputs: none
; outputs:
; carry clear : a packet was received. Stored in virtual address 0x0000.
; carry set   : no packet is raedy
eth_rx_pending:
      lda eth_rx_own
      ror a                ; Move bit 0 to carry
      rts


; -------------------------------------------------------------------
; Checks whether the frame contains at least A:X number of bytes.
; Return carry clear if yes, and carry set if no.
eth_rx_check_len:
      cmp eth_rx_len+1
      bne @return
      cpx eth_rx_len
@return:
      rts
      

; -------------------------------------------------------------------
; Check for received Ethernet packet, and process it.
; Should be called in a polling fashion, i.e. in a busy loop.
; Return carry set, if no packet was received
; Return carry clear, if a packet was received
eth_rx_poll:
      jsr eth_rx_pending
      bcs @return          ; No packet at the moment
      jsr eth_rx           ; Handle received packet
      jsr eth_rx_start
      clc
@return:
      rts

eth_rx:
      ; Initialize read pointer
      stz eth_rx_lo
      stz eth_rx_hi

      ; Read received length
      ldx eth_rx_dat       ; Get LSB of length in X
      lda eth_rx_dat       ; Get MSB of length in A
      sta eth_rx_len+1
      stx eth_rx_len

      ; Make sure the entire MAC header is received
      lda #0
      ldx #(mac_end - mac_start)
      jsr eth_rx_check_len
      bcs @return       ; Frame too small

      ; Get Ethernet type/length field
      lda #mac_tlen
      sta eth_rx_lo
      lda eth_rx_dat
      ldx eth_rx_dat

      ; Check for $0800 (IP) and $0806 (ARP)
      cmp #8
      bne @return
      cpx #0
      beq @ip
      cpx #6
      beq @arp
@return:
      rts

@ip:  jmp eth_ip_receive
@arp: jmp eth_arp_receive


; -------------------------------------------------------------------
; Send a packet
; inputs: Packet stored in virtual address 0x0800. Must be padded to minimum 60 bytes.
; outputs: Returns when packet is sent.
eth_tx:
      lda #1
      sta eth_tx_own       ; Transfer ownership to FPGA
@wait:
      lda eth_tx_own
      bne @wait            ; Wait until Tx buffer is ready
      rts


; -------------------------------------------------------------------
; Insert ethernet header
; A:X contains Ethernet type/len
ethernet_insert_header:
      pha

      ; Prepare Tx pointer
      lda #2
      sta eth_tx_lo
      stz eth_tx_hi

      ; Destination MAC address
      lda eth_server_mac
      sta eth_tx_dat
      lda eth_server_mac+1
      sta eth_tx_dat
      lda eth_server_mac+2
      sta eth_tx_dat
      lda eth_server_mac+3
      sta eth_tx_dat
      lda eth_server_mac+4
      sta eth_tx_dat
      lda eth_server_mac+5
      sta eth_tx_dat

      lda eth_my_mac
      sta eth_tx_dat
      lda eth_my_mac+1
      sta eth_tx_dat
      lda eth_my_mac+2
      sta eth_tx_dat
      lda eth_my_mac+3
      sta eth_tx_dat
      lda eth_my_mac+4
      sta eth_tx_dat
      lda eth_my_mac+5
      sta eth_tx_dat

      pla
      sta eth_tx_dat
      stx eth_tx_dat
      rts


; -------------------------------------------------------------------
; Input:
; * A:X contains the start address
; * eth_tx_end contains the end address
; Output:
; * A:X contains number of bytes
eth_tx_get_len:
      pha
      txa
      eor #$ff
      sec
      adc eth_tx_end
      tax
      pla
      eor #$ff
      adc eth_tx_end+1
      rts


; -------------------------------------------------------------------
; Update eth_tx_end, so the total MAC frame is at least 60 bytes excluding CRC
eth_tx_pad:
      lda eth_tx_end+1
      bne @return
      lda eth_tx_end
      cmp #(60 + mac_start)
      bcs @return
      lda #(60 + mac_start)
      sta eth_tx_end

      stz eth_tx_lo
      stz eth_tx_hi
      lda #60
      sta eth_tx_dat
      stz eth_tx_dat
@return:
      rts


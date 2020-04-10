; This implements a very simple ARP client
; We maintain only a single address in the ARP table.

.setcpu "65c02"

; Exported API
.export eth_get_jiffies
.export eth_server_ip_resolve
.export eth_arp_receive

.export eth_my_mac
.export eth_my_ip
.export eth_server_mac
.export eth_server_ip

; From lower layer (Ethernet)
.import ethernet_insert_header
.import eth_rx_poll
.import eth_rx_check_len
.import eth_tx

.include "ethernet.inc"
.include "kernal.inc"   ; rdtim


.segment "eth_data"
      ; Default value is broadcast. Will be overwritten when an ARP reply is received.
      eth_server_mac:   .res 6

      ; Configured by user. Default is 192.168.1.16
      eth_server_ip:    .res 4

      eth_arp_timeout:  .res 1
      eth_arp_retries:  .res 1

.segment "eth"
      ; The vendor ID is Digilent
      ; The serial number is ascii for "X16".
      eth_my_mac:     .byt $00, $18, $3e, $58, $31, $36   ; Hardcoded from factory

      ; TBD: Get IP address using DHCP
.if 1
      eth_my_ip:      .byt $c0, $a8, $01, $16             ; 192.168.1.22
.else
      eth_my_ip:      .byt $0a, $64, $03, $a0             ; 10.100.3.160
.endif


; -------------------------------------------
; -- Resolve server IP address
; -- Input: eth_server_ip contains the server IP address
; -- Output:
; -- Carry clear : eth_server_mac contains the server MAC address
; -- Carry set   : Timeout
; -------------------------------------------

; Get server MAC address
eth_server_ip_resolve:

      ; Reset server MAC address to broadcast
      lda #$ff
      sta eth_server_mac
      sta eth_server_mac+1
      sta eth_server_mac+2
      sta eth_server_mac+3
      sta eth_server_mac+4
      sta eth_server_mac+5

@resolve_resend:
      ; Send ARP request
      jsr eth_arp_send_request

      jsr eth_get_jiffies
      adc #60                             ; Don't bother clearing carry
      sta eth_arp_timeout                 ; Timeout after 1 second.
      lda #4
      sta eth_arp_retries                 ; Try 4 times before giving up.

@resolve_wait:
      jsr eth_rx_poll

      ; Have we received the MAC address?
      lda eth_server_mac
      cmp #$ff
      bne @resolve_ok

      jsr eth_get_jiffies
      cmp eth_arp_timeout
      bne @resolve_wait
      dec eth_arp_retries
      bne @resolve_resend
      sec                                 ; Timeout
      rts

@resolve_ok:
      clc
      rts


; -------------------------------------------
; -- A simple 8-bit counter for each jiffie.
; -- Input: none
; -- Output: 8-bit counter in A.
; -- Destroys: Both X- and Y-register
; -------------------------------------------

eth_get_jiffies:
      jmp rdtim


; ---------- INTERNAL ROUTINES --------------


; -------------------------------------------
; -- Process a received ARP packet:
; -- Input: none
; -- Output: none
; -------------------------------------------
eth_arp_receive:
      ; Make sure ARP header is available
      lda #0
      ldx #(arp_end - mac_start)
      jsr eth_rx_check_len
      bcs @eth_arp_return

      ; Multiplex on ARP code
      lda #arp_start+7
      sta eth_rx_lo
      lda eth_rx_dat
      cmp #1
      beq eth_arp_receive_request
      cmp #2
      beq eth_arp_receive_reply
@eth_arp_return:
      rts


; -------------------------------------------
; -- Process a received ARP request
; -- Input: none
; -- Output: none
; -------------------------------------------
eth_arp_receive_request:
      ; For now we just send an ARP reply with our address always.
      ; TODO: Add check for whether the request is for our IP address.
      jmp eth_arp_send_reply


; -------------------------------------------
; -- Process a received ARP reply
; -- Input: none
; -- Output: none
; -------------------------------------------
eth_arp_receive_reply:
      lda #arp_src_prot       ; Is reply coming from the server?
      sta eth_rx_lo
      lda eth_rx_dat
      cmp eth_server_ip
      bne @eth_arp_return
      lda eth_rx_dat
      cmp eth_server_ip+1
      bne @eth_arp_return
      lda eth_rx_dat
      cmp eth_server_ip+2
      bne @eth_arp_return
      lda eth_rx_dat
      cmp eth_server_ip+3
      bne @eth_arp_return
      
      lda #arp_src_hw         ; Copy servers MAC address
      sta eth_rx_lo
      read_server_mac_from_rx
@eth_arp_return:
      rts


; -------------------------------------------
; -- Send ARP request
; -- Input: none
; -- Output: none
; -------------------------------------------
eth_arp_send_request:
      lda #arp_start
      sta eth_tx_lo
      stz eth_tx_hi

      ; ARP header
      lda #0                  ; Hardware address = Ethernet
      sta eth_tx_dat
      lda #1
      sta eth_tx_dat
      lda #8                  ; Protocol addresss = IP
      sta eth_tx_dat
      lda #0
      sta eth_tx_dat
      lda #6                  ; Hardware address length
      sta eth_tx_dat
      lda #4                  ; Protocol address length
      sta eth_tx_dat
      lda #0
      sta eth_tx_dat
      lda #1                  ; ARP request
      sta eth_tx_dat

      write_my_mac_to_tx      ; Sender hardware address

      write_my_ip_to_tx       ; Sender protocol address

      lda #0                  ; Target hardware address (unknown)
      sta eth_tx_dat
      sta eth_tx_dat
      sta eth_tx_dat
      sta eth_tx_dat
      sta eth_tx_dat
      sta eth_tx_dat

      write_server_ip_to_tx   ; Target protocol address

eth_arp_pad_and_send:

@pad: stz eth_tx_dat          ; Padding
      lda eth_tx_lo
      cmp #62
      bcc @pad

      lda #8
      ldx #6
      jsr ethernet_insert_header

      ; Build the packet at virtual address $0000
      stz eth_tx_lo
      stz eth_tx_hi

      ; Set length of packet
      lda #60                 ; Minimum length is 60 bytes exluding CRC.
      sta eth_tx_dat
      stz eth_tx_dat

      jmp eth_tx


; -------------------------------------------
; -- Send ARP reply
; -- Input: none
; -- Output: none
; -------------------------------------------
eth_arp_send_reply:
      lda #arp_start
      sta eth_tx_lo
      stz eth_tx_hi

      ; ARP header
      lda #0                  ; Hardware address = Ethernet
      sta eth_tx_dat
      lda #1
      sta eth_tx_dat
      lda #8                  ; Protocol addresss = IP
      sta eth_tx_dat
      lda #0
      sta eth_tx_dat
      lda #6                  ; Hardware address length
      sta eth_tx_dat
      lda #4                  ; Protocol address length
      sta eth_tx_dat
      lda #0
      sta eth_tx_dat
      lda #2                  ; ARP reply
      sta eth_tx_dat

      write_my_mac_to_tx      ; Sender hardware address

      write_my_ip_to_tx       ; Sender protocol address

      lda #arp_src_hw         ; Target hardware address
      sta eth_rx_lo
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat

      lda eth_rx_dat          ; Target protocol address
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat
      lda eth_rx_dat
      sta eth_tx_dat

      jmp eth_arp_pad_and_send



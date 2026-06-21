; ======================================================
; Zmodem receive (download) for Sprinter DSS Network Kit
; Runs over the same ESP-AT TCP stream as the telnet client. CRC-16 only:
; we never advertise CANFC32, so the sender uses 16-bit CRC. Auto-started
; from the terminal when a Zmodem header start ("*" "*" ZDLE) is seen.
;
; Depends on: TCP.SEND_BUFFER / TCP.RECEIVE (esp_tcp), WIFI.UART_RX_* (esplib),
; DSS file funcs, the PRINT/PRINTLN macros. Include AFTER esp_tcp and BEFORE
; esplib so the kit's RS_BUFF BSS anchor sits above this module's buffers.
; ======================================================

	IFNDEF	_ZMODEM
	DEFINE	_ZMODEM

ZM_RXBUF_SIZE		EQU 512			; TCP refill buffer
ZM_DATA_SIZE		EQU 1024		; one ZDATA subpacket
ZM_FNAME_SIZE		EQU 96
ZM_TXBUF_SIZE		EQU 40			; outgoing hex header build area
ZM_RECV_TMO		EQU 10000		; ms to wait for the next stream byte
ZM_HDR_RETRIES		EQU 10			; header re-scans before giving up

DSS_CREATE_OVERWRITE	EQU 0x0A		; create, truncating an existing file

; --- protocol bytes ---
ZPAD			EQU '*'			; 0x2A
ZDLE			EQU 0x18		; CAN - ctrl-escape introducer
ZBIN			EQU 'A'			; binary header, CRC16
ZHEX			EQU 'B'			; hex header
ZBIN32			EQU 'C'			; binary header, CRC32 (we don't request it)
XON			EQU 0x11

; --- frame types ---
ZRQINIT			EQU 0
ZRINIT			EQU 1
ZACK			EQU 3
ZFILE			EQU 4
ZSKIP			EQU 5
ZNAK			EQU 6
ZFIN			EQU 8
ZRPOS			EQU 9
ZDATA			EQU 10
ZEOF			EQU 11

; --- ZDLE data-subpacket terminators ---
ZCRCE			EQU 'h'			; 0x68 end of frame, header follows
ZCRCG			EQU 'i'			; 0x69 frame continues, no ACK
ZCRCQ			EQU 'j'			; 0x6A frame continues, ACK expected
ZCRCW			EQU 'k'			; 0x6B end of frame, ACK expected
ZRUB0			EQU 'l'			; 0x6C -> 0x7F
ZRUB1			EQU 'm'			; 0x6D -> 0xFF

; --- ZRINIT capability flags (placed in ZF0 = the 4th header byte) ---
CANFDX			EQU 0x01		; full duplex
CANOVIO			EQU 0x02		; can overlap I/O
; (CANFC32 = 0x20 deliberately NOT set -> sender uses CRC16)

	MODULE ZM

; ------------------------------------------------------
; RECEIVE: entry from the telnet terminal once a header start was seen.
; In: HL = pointer to the unconsumed tail of the current TCP batch,
;     BC = its byte count (the "handoff"). Further bytes come from TCP.RECEIVE.
; Returns when the session ends (success or abort); caller resumes terminal.
; ------------------------------------------------------
RECEIVE
	LD	(SRC_PTR),HL
	LD	(SRC_CNT),BC
	XOR	A
	LD	(FH_OPEN),A
	LD	(ABORTED),A
	LD	HL,0
	LD	(FPOS),HL
	LD	(FPOS+2),HL
	PRINT	WCOMMON.LINE_END
	PRINTLN	MSG_START
.SESSION
	CALL	SEND_ZRINIT		; advertise CRC16 / full duplex
.NEXT_HDR
	CALL	RECV_HEADER		; A = frame type, CF=1 on fatal timeout/close
	JP	C,.GIVEUP
	CP	ZRQINIT
	JR	Z,.SESSION		; sender still announcing
	CP	ZFILE
	JP	Z,.ON_ZFILE
	CP	ZDATA
	JP	Z,.ON_ZDATA
	CP	ZEOF
	JP	Z,.ON_ZEOF
	CP	ZFIN
	JP	Z,.ON_ZFIN
	JR	.NEXT_HDR		; ZSKIP/ZNAK/unknown -> keep listening

.ON_ZFILE
	CALL	RECV_SUBPACKET		; name+info -> DATA_BUF, DE=len
	JR	C,.SESSION		; bad subpacket -> resend ZRINIT
	CALL	OPEN_OUTPUT
	JR	C,.GIVEUP
	LD	HL,0
	LD	(FPOS),HL
	LD	(FPOS+2),HL
	CALL	SEND_ZRPOS
	JP	.NEXT_HDR

.ON_ZDATA
	CALL	HDR_POS_MATCHES		; CF=0 if header pos == FPOS
	JR	C,.RESYNC
.DATA_LOOP
	CALL	RECV_SUBPACKET		; DATA_BUF/DE=len, A=terminator
	JR	C,.RESYNC
	LD	(LAST_TERM),A
	CALL	WRITE_OUTPUT		; write DE bytes, advance FPOS
	JR	C,.GIVEUP
	CALL	SHOW_PROGRESS
	LD	A,(LAST_TERM)
	CP	ZCRCG
	JR	Z,.DATA_LOOP
	CP	ZCRCQ
	JR	Z,.DATA_ACK
	CP	ZCRCW
	JR	Z,.DATA_ACK_END
	JP	.NEXT_HDR		; ZCRCE / anything -> header follows
.DATA_ACK
	CALL	SEND_ZACK
	JR	.DATA_LOOP
.DATA_ACK_END
	CALL	SEND_ZACK
	JP	.NEXT_HDR
.RESYNC
	CALL	SEND_ZRPOS		; tell the sender our position
	JP	.NEXT_HDR

.ON_ZEOF
	CALL	HDR_POS_MATCHES		; all bytes received?
	JR	C,.RESYNC
	CALL	CLOSE_OUTPUT
	PRINTLN	MSG_FILE_OK
	JP	.SESSION		; ready for the next file or ZFIN

.ON_ZFIN
	CALL	SEND_ZFIN
	CALL	CLOSE_OUTPUT
	PRINTLN	MSG_DONE
	RET

.GIVEUP
	CALL	ABORT_TRANSFER
	PRINTLN	MSG_ABORT
	RET

; ======================================================
; Stream input
; ======================================================

; GETBYTE: next raw byte. Out: A=byte, CF=0; CF=1 on timeout/close/abort.
GETBYTE
	LD	HL,(SRC_CNT)
	LD	A,H
	OR	L
	JR	NZ,.have
	CALL	FILL
	RET	C
.have
	LD	HL,(SRC_PTR)
	LD	A,(HL)
	INC	HL
	LD	(SRC_PTR),HL
	PUSH	AF
	LD	HL,(SRC_CNT)
	DEC	HL
	LD	(SRC_CNT),HL
	POP	AF
	OR	A			; CF=0
	RET

; FILL: pull a fresh batch from the ESP into RXBUF. CF=1 on timeout/close/abort.
FILL
	CALL	CHECK_ABORT
	JR	C,.fail
	LD	HL,RXBUF
	LD	BC,ZM_RXBUF_SIZE
	LD	DE,ZM_RECV_TMO
	CALL	TCP.RECEIVE
	JR	C,.fail
	LD	A,B
	OR	C
	JR	Z,.fail
	LD	(SRC_CNT),BC
	LD	HL,RXBUF
	LD	(SRC_PTR),HL
	OR	A
	RET
.fail
	SCF
	RET

; GET_UNESC: next ZDLE-decoded element.
; Out: A=value, B=0 (data) or B=1 (terminator; A=ZCRC* char), CF=1 on error.
GET_UNESC
	CALL	GETBYTE
	RET	C
	CP	ZDLE
	JR	Z,.esc
	LD	B,0
	OR	A
	RET
.esc
	CALL	GETBYTE
	RET	C
	CP	ZCRCE
	JR	Z,.term
	CP	ZCRCG
	JR	Z,.term
	CP	ZCRCQ
	JR	Z,.term
	CP	ZCRCW
	JR	Z,.term
	CP	ZRUB0
	JR	Z,.rub0
	CP	ZRUB1
	JR	Z,.rub1
	XOR	0x40			; ZDLEE etc.
	LD	B,0
	OR	A
	RET
.term
	LD	B,1
	OR	A
	RET
.rub0
	LD	A,0x7F
	LD	B,0
	OR	A
	RET
.rub1
	LD	A,0xFF
	LD	B,0
	OR	A
	RET

; ======================================================
; Header receive
; ======================================================

; RECV_HEADER: find "*"["*"...] ZDLE <fmt>, decode it into HDR_TYPE/HDR_P0..3.
; Out: A=type, CF=0; CF=1 on too many failures / close.
RECV_HEADER
	LD	A,ZM_HDR_RETRIES
	LD	(HDR_TRY),A
.again
	CALL	SCAN_ZDLE
	JR	C,.fail
	CALL	GETBYTE			; format byte
	JR	C,.fail
	CP	ZHEX
	JR	Z,.hex
	CP	ZBIN
	JR	Z,.bin
	CP	ZBIN32
	JR	Z,.bin32
	JR	.retry
.hex
	CALL	RECV_HEX
	JR	C,.retry
	JR	.ok
.bin
	CALL	RECV_BIN
	JR	C,.retry
	JR	.ok
.bin32
	CALL	RECV_BIN32
	JR	C,.retry
.ok
	LD	A,(HDR_TYPE)
	OR	A			; CF=0
	RET
.retry
	LD	A,(HDR_TRY)
	DEC	A
	LD	(HDR_TRY),A
	JR	NZ,.again
.fail
	SCF
	RET

; SCAN_ZDLE: read until ZPAD(one or more) immediately followed by ZDLE.
SCAN_ZDLE
.s
	CALL	GETBYTE
	RET	C
	CP	ZPAD
	JR	NZ,.s
.p
	CALL	GETBYTE
	RET	C
	CP	ZPAD
	JR	Z,.p
	CP	ZDLE
	JR	Z,.done
	JR	.s
.done
	OR	A
	RET

; RECV_HEX: 14 hex chars -> type,p0..3,crchi,crclo; verify CRC16. Swallow CR/LF.
RECV_HEX
	LD	IX,HDR_TYPE
	LD	B,5
.rb
	CALL	GET_HEXBYTE
	RET	C
	LD	(IX+0),A
	INC	IX
	DJNZ	.rb
	CALL	HDR_CRC			; HL=crc
	CALL	GET_HEXBYTE		; crc hi
	RET	C
	CP	H
	JR	NZ,.bad
	CALL	GET_HEXBYTE		; crc lo
	RET	C
	CP	L
	JR	NZ,.bad
	CALL	GETBYTE			; trailing CR
	CALL	GETBYTE			; trailing LF
	OR	A
	RET
.bad
	SCF
	RET

; RECV_BIN: type,p0..3,crchi,crclo as ZDLE-decoded bytes; verify CRC16.
RECV_BIN
	LD	IX,HDR_TYPE
	LD	B,5
.rb
	CALL	GET_UNESC
	RET	C
	LD	(IX+0),A
	INC	IX
	DJNZ	.rb
	CALL	HDR_CRC
	CALL	GET_UNESC		; crc hi
	RET	C
	CP	H
	JR	NZ,.bad
	CALL	GET_UNESC		; crc lo
	RET	C
	CP	L
	JR	NZ,.bad
	OR	A
	RET
.bad
	SCF
	RET

; RECV_BIN32: a CRC32 header we never requested; read type,p0..3 + 4 CRC bytes
; and accept the type without verification (best effort).
RECV_BIN32
	LD	IX,HDR_TYPE
	LD	B,5
.rb
	CALL	GET_UNESC
	RET	C
	LD	(IX+0),A
	INC	IX
	DJNZ	.rb
	LD	B,4
.cc
	CALL	GET_UNESC
	RET	C
	DJNZ	.cc
	OR	A
	RET

; HDR_CRC: CRC16 over HDR_TYPE,HDR_P0..3 (5 bytes). Out: HL=crc.
HDR_CRC
	LD	HL,0
	LD	IX,HDR_TYPE
	LD	B,5
.l
	LD	A,(IX+0)
	INC	IX
	CALL	CRC_UPD
	DJNZ	.l
	RET

; GET_HEXBYTE: two hex chars -> A=byte. CF=1 on stream error.
GET_HEXBYTE
	CALL	GETBYTE
	RET	C
	CALL	UNHEX
	RLCA
	RLCA
	RLCA
	RLCA
	AND	0xF0
	LD	C,A
	CALL	GETBYTE
	RET	C
	CALL	UNHEX
	OR	C
	OR	A			; CF=0
	RET

; ======================================================
; Data subpacket receive
; ======================================================

; RECV_SUBPACKET: read a subpacket into DATA_BUF. Out: DE=len, A=terminator,
; CF=0 if CRC ok; CF=1 on CRC error / stream error / overflow.
RECV_SUBPACKET
	LD	HL,0
	LD	(SP_CRC),HL
	LD	HL,DATA_BUF
	LD	(SP_PTR),HL
	LD	HL,0
	LD	(SP_LEN),HL
.byte
	CALL	GET_UNESC		; A=val, B=flag
	RET	C
	LD	C,A			; C = value
	LD	A,B
	OR	A
	JR	NZ,.term
	; data byte in C
	LD	HL,(SP_LEN)
	LD	DE,ZM_DATA_SIZE
	OR	A
	SBC	HL,DE
	JR	NC,.overflow		; len >= size
	LD	HL,(SP_PTR)
	LD	(HL),C
	INC	HL
	LD	(SP_PTR),HL
	LD	HL,(SP_LEN)
	INC	HL
	LD	(SP_LEN),HL
	LD	A,C
	LD	HL,(SP_CRC)
	CALL	CRC_UPD
	LD	(SP_CRC),HL
	JR	.byte
.term
	LD	A,C
	LD	(SP_TERM),A		; terminator char
	LD	HL,(SP_CRC)
	CALL	CRC_UPD			; terminator is part of the CRC
	LD	(SP_CRC),HL
	CALL	GET_UNESC		; received CRC hi
	RET	C
	LD	HL,SP_CRC+1		; computed hi
	CP	(HL)
	JR	NZ,.bad
	CALL	GET_UNESC		; received CRC lo
	RET	C
	LD	HL,SP_CRC		; computed lo
	CP	(HL)
	JR	NZ,.bad
	LD	DE,(SP_LEN)
	LD	A,(SP_TERM)
	OR	A			; CF=0
	RET
.bad
	SCF
	RET
.overflow
	SCF
	RET

; ======================================================
; Header send
; ======================================================

SEND_ZRINIT
	XOR	A
	LD	(TXP+0),A
	LD	(TXP+1),A
	LD	(TXP+2),A
	LD	A,CANFDX | CANOVIO
	LD	(TXP+3),A
	LD	A,ZRINIT
	JR	SEND_HDR

SEND_ZRPOS
	LD	A,ZRPOS
	JR	SEND_POS
SEND_ZACK
	LD	A,ZACK
SEND_POS				; A=type, position = FPOS
	PUSH	AF
	LD	HL,FPOS
	LD	DE,TXP
	LD	BC,4
	LDIR
	POP	AF
	JR	SEND_HDR

SEND_ZFIN
	XOR	A
	LD	(TXP+0),A
	LD	(TXP+1),A
	LD	(TXP+2),A
	LD	(TXP+3),A
	LD	A,ZFIN
	; fall through

; SEND_HDR: build "**" ZDLE 'B' hex(type,p0..3,crchi,crclo) CR LF XON, send it.
; In: A=type, TXP[0..3]=the four bytes.
SEND_HDR
	LD	(SEND_T),A
	LD	HL,TXBUF
	LD	(TXP_DST),HL
	LD	A,ZPAD
	CALL	PUT
	LD	A,ZPAD
	CALL	PUT
	LD	A,ZDLE
	CALL	PUT
	LD	A,ZHEX
	CALL	PUT
	LD	HL,0
	LD	(SEND_CRC),HL
	LD	A,(SEND_T)
	CALL	EMIT_CRC_HEX
	LD	IX,TXP
	LD	B,4
.p
	LD	A,(IX+0)
	INC	IX
	CALL	EMIT_CRC_HEX
	DJNZ	.p
	LD	HL,(SEND_CRC)
	LD	A,H
	CALL	PUTHEX
	LD	A,L
	CALL	PUTHEX
	LD	A,0x0D
	CALL	PUT
	LD	A,0x0A
	CALL	PUT
	LD	A,XON
	CALL	PUT
	; length = TXP_DST - TXBUF
	LD	HL,(TXP_DST)
	LD	DE,TXBUF
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,TXBUF
	JP	TCP.SEND_BUFFER

; PUT: append A to (TXP_DST). Preserves A,BC,DE.
PUT
	PUSH	HL
	LD	HL,(TXP_DST)
	LD	(HL),A
	INC	HL
	LD	(TXP_DST),HL
	POP	HL
	RET

; PUTHEX: append the two hex digits of A. Preserves BC,DE.
PUTHEX
	LD	C,A
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	HEXCHR
	CALL	PUT
	LD	A,C
	CALL	HEXCHR
	JP	PUT

; EMIT_CRC_HEX: CRC-update SEND_CRC with A, then append hex(A).
EMIT_CRC_HEX
	PUSH	AF
	LD	HL,(SEND_CRC)
	CALL	CRC_UPD
	LD	(SEND_CRC),HL
	POP	AF
	JR	PUTHEX

; HEXCHR: low nibble of A -> lowercase hex char. Preserves BC,DE.
HEXCHR
	AND	0x0F
	CP	10
	JR	C,.d
	ADD	A,'a'-10
	RET
.d
	ADD	A,'0'
	RET

; UNHEX: hex char in A -> nibble (0..15). Accepts upper/lower case.
UNHEX
	CP	'a'
	JR	C,.up
	SUB	'a'-10
	RET
.up
	CP	'A'
	JR	C,.num
	SUB	'A'-10
	RET
.num
	SUB	'0'
	RET

; CRC_UPD: CRC-16/XMODEM update. In: A=byte, HL=crc. Out: HL=crc. Preserves BC,DE.
CRC_UPD
	PUSH	BC
	LD	B,A
	LD	A,H
	XOR	B
	LD	H,A
	LD	B,8
.l
	ADD	HL,HL
	JR	NC,.s
	LD	A,H
	XOR	0x10
	LD	H,A
	LD	A,L
	XOR	0x21
	LD	L,A
.s
	DJNZ	.l
	POP	BC
	RET

; ======================================================
; Position / file
; ======================================================

; HDR_POS_MATCHES: compare HDR_P0..3 (received pos) with FPOS. CF=0 if equal.
HDR_POS_MATCHES
	LD	HL,HDR_P0
	LD	DE,FPOS
	LD	B,4
.l
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.diff
	INC	HL
	INC	DE
	DJNZ	.l
	OR	A
	RET
.diff
	SCF
	RET

; OPEN_OUTPUT: parse filename (ASCIIZ at DATA_BUF) and create/overwrite it.
OPEN_OUTPUT
	LD	HL,DATA_BUF
	LD	DE,FNAME
	LD	B,ZM_FNAME_SIZE-1
.cp
	LD	A,(HL)
	LD	(DE),A
	OR	A
	JR	Z,.named
	INC	HL
	INC	DE
	DJNZ	.cp
	XOR	A
	LD	(DE),A
.named
	PRINT	MSG_RECV
	PRINT	FNAME
	PRINT	WCOMMON.LINE_END
	LD	HL,FNAME
	LD	A,FA_ARCHIVE
	LD	C,DSS_CREATE_OVERWRITE
	RST	DSS
	RET	C
	LD	(FH),A
	LD	A,1
	LD	(FH_OPEN),A
	OR	A
	RET

; WRITE_OUTPUT: write DE bytes from DATA_BUF and advance FPOS. CF=1 on error.
WRITE_OUTPUT
	LD	A,D
	OR	E
	RET	Z			; nothing to write (CF=0)
	PUSH	DE
	CALL	WIFI.UART_RX_PAUSE	; hold the ESP during the slow disk write
	LD	A,(FH)
	LD	HL,DATA_BUF
	POP	DE
	PUSH	DE
	LD	C,DSS_WRITE
	RST	DSS			; A=handle, HL=buf, DE=count
	PUSH	AF
	CALL	WIFI.UART_RX_RESUME
	POP	AF
	JR	C,.err
	POP	DE
	CALL	ADD_FPOS
	OR	A
	RET
.err
	POP	DE
	SCF
	RET

; ADD_FPOS: FPOS (4-byte LE) += DE.
ADD_FPOS
	LD	HL,(FPOS)
	ADD	HL,DE
	LD	(FPOS),HL
	RET	NC
	LD	HL,(FPOS+2)
	INC	HL
	LD	(FPOS+2),HL
	RET

CLOSE_OUTPUT
	LD	A,(FH_OPEN)
	OR	A
	RET	Z
	LD	A,(FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	XOR	A
	LD	(FH_OPEN),A
	RET

; ABORT_TRANSFER: send the Zmodem cancel sequence and close any open file.
ABORT_TRANSFER
	LD	HL,CANSEQ
	LD	BC,CANSEQ_LEN
	CALL	TCP.SEND_BUFFER
	JP	CLOSE_OUTPUT

; CHECK_ABORT: Esc -> set ABORTED, CF=1. Preserves nothing important.
CHECK_ABORT
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.no
	LD	A,E
	CP	0x1B
	JR	NZ,.no
	LD	A,1
	LD	(ABORTED),A
	POP	HL
	POP	DE
	POP	BC
	SCF
	RET
.no
	POP	HL
	POP	DE
	POP	BC
	OR	A
	RET

; SHOW_PROGRESS: one dot per subpacket (KB counter is a later polish).
SHOW_PROGRESS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	RET

; ======================================================
; Messages
; ======================================================
MSG_START
	DB "Zmodem download (Esc aborts)...",0
MSG_RECV
	DB "Receiving ",0
MSG_FILE_OK
	DB " OK",0
MSG_DONE
	DB "Zmodem done.",0
MSG_ABORT
	DB "Zmodem aborted.",0

CANSEQ
	DB 0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18
	DB 0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08
CANSEQ_LEN	EQU $-CANSEQ

; ======================================================
; State + buffers (in the loaded image; include this module before esplib so
; the RS_BUFF BSS anchor sits above it). TODO: move the big buffers to runtime
; BSS to shave ~1.6 KB off the .EXE.
; ======================================================
SRC_PTR		DW 0
SRC_CNT		DW 0
HDR_TRY		DB 0
HDR_TYPE	DB 0
HDR_P0		DB 0
HDR_P1		DB 0
HDR_P2		DB 0
HDR_P3		DB 0
SP_CRC		DW 0
SP_PTR		DW 0
SP_LEN		DW 0
SP_TERM		DB 0
LAST_TERM	DB 0
SEND_T		DB 0
SEND_CRC	DW 0
TXP_DST		DW 0
TXP		DS 4,0
FH		DB 0
FH_OPEN		DB 0
ABORTED		DB 0
FPOS		DS 4,0
FNAME		DS ZM_FNAME_SIZE,0
TXBUF		DS ZM_TXBUF_SIZE,0
RXBUF		DS ZM_RXBUF_SIZE,0
DATA_BUF	DS ZM_DATA_SIZE,0

	ENDMODULE

	ENDIF

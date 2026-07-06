; ======================================================
; Zmodem receive (download) for Sprinter ESP Network Kit
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
ZM_DATA_SIZE		EQU 1024		; flush-to-disk chunk size
ZM_RX_WINDOW		EQU 1024		; receive window advertised in ZRINIT (paces sender)
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
	; Switch out of transparent passthrough into +IPD mode: TCP.RECEIVE then
	; gives us the proven, back-pressured receive path (the raw transparent
	; drain loses bytes during disk writes). The handoff bytes are dropped - the
	; sender re-sends ZRQINIT, which we pick up via TCP.RECEIVE.
	CALL	MAIN.ZM_TO_CMDMODE
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
	JR	NC,.NEXT_HDR
	LD	A,'S'			; TEMP: ZRINIT send (CIPSEND) failed
	CALL	DBG_CH
.NEXT_HDR
	LD	A,(ABORTED)		; Esc pressed during a read -> stop now
	OR	A
	JP	NZ,.GIVEUP
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
	JP	C,.GIVEUP
	LD	HL,0
	LD	(FPOS),HL
	LD	(FPOS+2),HL
	CALL	SEND_ZRPOS
	JP	.NEXT_HDR

.ON_ZDATA
	CALL	HDR_POS_MATCHES		; CF=0 if header pos == FPOS
	JR	NC,.DATA_LOOP
	LD	A,'p'			; TEMP: ZDATA position mismatch
	CALL	DBG_CH
	JP	.RESYNC
.DATA_LOOP
	CALL	RECV_SUBPACKET		; DATA_BUF/DE=len, A=terminator
	JR	NC,.SP_OK
	LD	A,'c'			; TEMP: subpacket read/CRC failure
	CALL	DBG_CH
	JP	.RESYNC
.SP_OK
	LD	(LAST_TERM),A		; RECV_SUBPACKET already wrote the data to disk
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
	JR	NC,.EOF_OK
	LD	A,'e'			; TEMP: ZEOF position mismatch (FPOS != filelen)
	CALL	DBG_CH
	CALL	DBG_POS			; TEMP: show FPOS vs ZEOF position
	JP	.RESYNC
.EOF_OK
	CALL	CLOSE_OUTPUT
	PRINTLN	MSG_FILE_OK
	JP	.SESSION		; ready for the next file or ZFIN

.ON_ZFIN
	CALL	SEND_ZFIN
	CALL	CLOSE_OUTPUT
	PRINTLN	MSG_DONE
	JP	MAIN.ZM_RESUME_TRANSPARENT	; restore CIPMODE=1 + passthrough

.GIVEUP
	CALL	ABORT_TRANSFER
	PRINTLN	MSG_ABORT
	JP	MAIN.ZM_RESUME_TRANSPARENT	; restore CIPMODE=1 + passthrough

; ======================================================
; Stream input
; ======================================================

; GETBYTE: next raw byte. Out: A=byte, CF=0; CF=1 on timeout/close/abort.
GETBYTE
	LD	HL,(SRC_CNT)
	LD	A,H
	OR	L
	JR	NZ,.have
	PUSH	BC			; FILL clobbers BC; preserve it so DJNZ loop
	CALL	FILL			; counters in callers survive a mid-read refill
	POP	BC
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
; Transparent mode: read raw UART bytes (no +IPD framing). RTS is raised only
; for the drain; the keyboard poll and the caller's processing run with RTS
; down so the ESP is held off and no byte is lost.
FILL
	; Poll the keyboard with RTS DROPPED: DSS_SCANKEY is a slow call and with
	; RTS up the ESP overruns the FIFO (lost bytes -> data-subpacket CRC fails).
	; RTS goes back up for the drain itself.
	; +IPD receive via the kit's TCP.RECEIVE, bracketed RTS up/down like
	; moonrabbit/ftp: RTS up to stream the batch, down while we parse/CRC/write
	; (TCP backpressure holds the sender, so no bytes are lost during writes).
	CALL	CHECK_ABORT
	JR	C,.fail
	CALL	WIFI.UART_RX_RESUME
	LD	HL,RXBUF
	LD	BC,ZM_RXBUF_SIZE
	LD	DE,ZM_RECV_TMO
	CALL	TCP.RECEIVE
	PUSH	AF
	CALL	WIFI.UART_RX_PAUSE
	POP	AF
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
	JR	C,.timeout
	CALL	GETBYTE			; format byte
	JR	C,.timeout
	CP	ZHEX
	JR	Z,.hex
	CP	ZBIN
	JR	Z,.bin
	CP	ZBIN32
	JR	Z,.bin32
	CALL	DBG_CH			; TEMP: unrecognised format byte
	JR	.retry
.hex
	CALL	RECV_HEX
	JR	C,.crcfail
	JR	.ok
.bin
	CALL	RECV_BIN
	JR	C,.crcfail
	JR	.ok
.bin32
	CALL	RECV_BIN32
	JR	C,.crcfail
.ok
	CALL	DBG_HDR			; TEMP diagnostic: show each received frame type
	LD	A,(HDR_TYPE)
	OR	A			; CF=0
	RET
.crcfail
	LD	A,'!'			; TEMP: header CRC/parse error
	CALL	DBG_CH
.retry
	LD	A,(HDR_TRY)
	DEC	A
	LD	(HDR_TRY),A
	JR	NZ,.again
.fail
	SCF
	RET
.timeout
	LD	A,'T'			; TEMP: no data / stream end
	CALL	DBG_CH
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
	CALL	HDR_CRC			; HL = computed crc
	LD	(HCRC),HL		; save it - GET_HEXBYTE/GETBYTE clobber HL
	CALL	GET_HEXBYTE		; received crc hi
	RET	C
	LD	HL,HCRC+1		; computed hi
	CP	(HL)
	JR	NZ,.bad
	CALL	GET_HEXBYTE		; received crc lo
	RET	C
	LD	HL,HCRC			; computed lo
	CP	(HL)
	JR	NZ,.bad
	CALL	GETBYTE			; trailing CR
	CALL	GETBYTE			; trailing LF
	OR	A
	RET
.bad
	SCF
	RET

; RECV_BIN: type,p0..3,crchi,crclo as ZDLE-decoded bytes; verify CRC16.
; Counter is in C (GET_UNESC returns its data/terminator flag in B, so B cannot
; be used as the DJNZ counter here); GET_UNESC leaves C untouched.
RECV_BIN
	LD	IX,HDR_TYPE
	LD	C,5
.rb
	CALL	GET_UNESC
	RET	C
	LD	(IX+0),A
	INC	IX
	DEC	C
	JR	NZ,.rb
	CALL	HDR_CRC			; HL = computed crc
	LD	(HCRC),HL		; save it - GET_UNESC/GETBYTE clobber HL
	CALL	GET_UNESC		; received crc hi
	RET	C
	LD	HL,HCRC+1		; computed hi
	CP	(HL)
	JR	NZ,.bad
	CALL	GET_UNESC		; received crc lo
	RET	C
	LD	HL,HCRC			; computed lo
	CP	(HL)
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
	LD	C,5			; counter in C (GET_UNESC clobbers B)
.rb
	CALL	GET_UNESC
	RET	C
	LD	(IX+0),A
	INC	IX
	DEC	C
	JR	NZ,.rb
	LD	C,4
.cc
	CALL	GET_UNESC
	RET	C
	DEC	C
	JR	NZ,.cc
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

; RECV_SUBPACKET: read a data subpacket, writing it to the output file as the
; 1 KB buffer fills - so a subpacket of ANY size is handled (the sender here
; sends the whole file as one big subpacket). On a good CRC the data stays
; committed and FPOS is advanced; on a bad CRC / stream error the file is
; rewound to the subpacket start and FPOS restored, so .RESYNC re-requests it.
; Out: A=terminator, CF=0 on success; CF=1 on CRC/stream error.
RECV_SUBPACKET
	LD	HL,(FPOS)		; remember where this subpacket starts
	LD	(SP_START),HL
	LD	HL,(FPOS+2)
	LD	(SP_START+2),HL
	LD	HL,0
	LD	(SP_CRC),HL
	LD	HL,DATA_BUF
	LD	(SP_PTR),HL
	LD	HL,0
	LD	(SP_LEN),HL
.byte
	CALL	GET_UNESC		; A=val, B=flag
	JR	C,.streamerr
	LD	C,A			; C = value
	LD	A,B
	OR	A
	JR	NZ,.term
	; data byte: if the buffer is full, flush it to disk first
	LD	HL,(SP_LEN)
	LD	DE,ZM_DATA_SIZE
	OR	A
	SBC	HL,DE
	JR	C,.store		; len < size
	CALL	FLUSH_BUF
	JR	C,.writeerr
.store
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
	CALL	CRC_UPD			; terminator is part of the CRC (A = terminator)
	LD	(SP_CRC),HL
	; Read + verify the 2 CRC bytes FIRST, while the stream is still flowing fast.
	; They arrive immediately after the terminator; if we did the slow buffer-tail
	; disk write before reading them, the bytes streamed during that write would be
	; lost and every subpacket CRC would fail. Flush only AFTER the CRC checks out.
	CALL	GET_UNESC		; received CRC hi
	JR	C,.streamerr
	LD	HL,SP_CRC+1		; computed hi
	CP	(HL)
	JR	NZ,.crcbad
	CALL	GET_UNESC		; received CRC lo
	JR	C,.streamerr
	LD	HL,SP_CRC		; computed lo
	CP	(HL)
	JR	NZ,.crcbad
	CALL	FLUSH_BUF		; CRC ok -> commit the buffer tail now
	JR	C,.writeerr
	LD	A,(SP_TERM)
	OR	A			; CF=0
	RET
.crcbad
	LD	A,'X'			; TEMP: subpacket CRC mismatch
	CALL	DBG_CH
	CALL	SEEK_TO_SP_START
	SCF
	RET
.streamerr
	CALL	SEEK_TO_SP_START
	SCF
	RET
.writeerr
	SCF
	RET

; FLUSH_BUF: write the SP_LEN bytes in DATA_BUF to the file, advance FPOS, reset
; the buffer. CF=1 on a DSS write error.
FLUSH_BUF
	LD	DE,(SP_LEN)
	LD	A,D
	OR	E
	RET	Z			; nothing buffered (CF=0)
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
	CALL	ADD_FPOS		; FPOS += bytes written
	LD	HL,DATA_BUF		; reset the buffer
	LD	(SP_PTR),HL
	LD	HL,0
	LD	(SP_LEN),HL
	OR	A
	RET
.err
	POP	DE
	SCF
	RET

; SEEK_TO_SP_START: rewind the file to SP_START and restore FPOS = SP_START.
SEEK_TO_SP_START
	LD	A,(FH)
	LD	B,0			; whence = from start
	LD	HL,(SP_START+2)		; HL:IX = position (high16:low16)
	LD	IX,(SP_START)
	LD	C,DSS_MOVE_FP
	RST	DSS
	LD	HL,(SP_START)
	LD	(FPOS),HL
	LD	HL,(SP_START+2)
	LD	(FPOS+2),HL
	RET

; ======================================================
; Header send
; ======================================================

; SEND_ZRINIT: advertise a 1 KB receive window (ZP0/ZP1) and DROP CANOVIO, so
; the sender stops streaming the whole file as one giant subpacket and instead
; sends <=1 KB subpackets, each ZCRCW-terminated, waiting for our ZACK. That
; paces it to our disk-write speed and stops the ESP buffer from overrunning.
SEND_ZRINIT
	; +IPD mode gives reliable back-pressured RX, so no window limit is needed
	; (windowing the sender did not help and the sender ignored it anyway).
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
	; NO_WAIT: do not wait for "SEND OK" - that would consume the sender's reply
	; (ZFILE/data +IPD) which we need to parse next.
	JP	TCP.SEND_BUFFER_NO_WAIT

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
	; The sender keeps streaming for a while before it processes the ZCAN, so
	; drain+discard ~2 s of in-flight +IPD data; otherwise it floods the terminal
	; as garbage when we return.
	CALL	WIFI.UART_RX_RESUME
	LD	B,20
.drain
	PUSH	BC
	LD	HL,RXBUF
	LD	BC,ZM_RXBUF_SIZE
	LD	DE,100
	CALL	TCP.RECEIVE
	POP	BC
	DJNZ	.drain
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

; DBG_CH (TEMP): print the char in A. Remove once Zmodem is verified.
DBG_CH
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	RET

; DBG_HDR (TEMP): print "<XX>" with XX = received frame type (hex), to trace
; the handshake on screen. Remove once Zmodem is verified.
DBG_HDR
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	A,'<'
	CALL	.pc
	LD	A,(HDR_TYPE)
	PUSH	AF
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	.ph
	POP	AF
	CALL	.ph
	LD	A,'>'
	CALL	.pc
	POP	HL
	POP	DE
	POP	BC
	RET
.ph
	AND	0x0F
	CP	10
	JR	C,.d
	ADD	A,'a'-10
	JR	.pc
.d
	ADD	A,'0'
.pc
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	RET

; DBG_BYTE (TEMP): print A as two hex chars.
DBG_BYTE
	PUSH	BC
	PUSH	HL
	LD	C,A
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	.nib
	LD	A,C
	CALL	.nib
	POP	HL
	POP	BC
	RET
.nib
	AND	0x0F
	CP	10
	JR	C,.dig
	ADD	A,'a'-10
	JP	DBG_CH
.dig
	ADD	A,'0'
	JP	DBG_CH

; DBG_POS (TEMP): print "F<fpos>Z<zeof pos>" (little-endian byte order).
DBG_POS
	LD	A,'F'
	CALL	DBG_CH
	LD	HL,FPOS
	CALL	.dump4
	LD	A,'Z'
	CALL	DBG_CH
	LD	HL,HDR_P0
	CALL	.dump4
	LD	A,' '
	JP	DBG_CH
.dump4
	LD	B,4
.dl
	LD	A,(HL)
	CALL	DBG_BYTE
	INC	HL
	DJNZ	.dl
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
HCRC		DW 0			; computed header CRC, saved across the received-CRC read
SP_CRC		DW 0
SP_PTR		DW 0
SP_LEN		DW 0
SP_START	DS 4,0			; file offset at the current subpacket's start
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

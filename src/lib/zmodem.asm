; ======================================================
; Zmodem send/receive for Sprinter ESP Network Kit
; Runs over the same ESP-AT TCP stream as the telnet client. CRC-16 only:
; we never advertise CANFC32, so the peer uses 16-bit CRC. Auto-started from
; the terminal when a Zmodem header start ("*" "*" ZDLE) is seen.
;
; Depends on: TCP.SEND_BUFFER / TCP.RECEIVE (esp_tcp), WIFI.UART_RX_* (esplib),
; DSS file funcs, the PRINT/PRINTLN macros, and one allocated WIN2 page.
; Include after esp_tcp and before esplib.
; ======================================================

	IFNDEF	_ZMODEM
	DEFINE	_ZMODEM

ZM_RXBUF_SIZE		EQU 512			; TCP refill buffer
ZM_DATA_SIZE		EQU 8192		; max accepted receive subpacket
ZM_TX_CHUNK		EQU 1024		; stop-and-wait upload chunk
ZM_RX_WINDOW		EQU ZM_DATA_SIZE		; advertised sender frame limit
ZM_FNAME_SIZE		EQU 96
ZM_TXBUF_SIZE		EQU 40			; outgoing hex header build area
ZM_TXDATA_SIZE		EQU ZM_TX_CHUNK*2+16	; worst-case escaped upload subpacket
ZM_RECV_TMO		EQU 10000		; ms to wait for the next stream byte
ZM_HDR_RETRIES		EQU 10			; header re-scans before giving up
ZM_SEND_RETRIES		EQU 10

DSS_CREATE_OVERWRITE	EQU 0x0A		; create, truncating an existing file

; --- protocol bytes ---
ZPAD			EQU '*'			; 0x2A
ZDLE			EQU 0x18		; CAN - ctrl-escape introducer
ZBIN			EQU 'A'			; binary header, CRC16
ZHEX			EQU 'B'			; hex header
ZBIN32			EQU 'C'			; binary header, CRC32 (we don't request it)
XON			EQU 0x11
XOFF			EQU 0x13

; --- frame types ---
ZRQINIT			EQU 0
ZRINIT			EQU 1
ZSINIT			EQU 2
ZACK			EQU 3
ZFILE			EQU 4
ZSKIP			EQU 5
ZNAK			EQU 6
ZABORT			EQU 7
ZFIN			EQU 8
ZRPOS			EQU 9
ZDATA			EQU 10
ZEOF			EQU 11
ZCRC			EQU 13

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
ESCCTL			EQU 0x40		; peer must escape all control bytes
; (CANFC32 = 0x20 deliberately NOT set -> sender uses CRC16)

; --- ZFILE conversion/management flags ---
ZCBIN			EQU 1			; binary transfer, no conversion
ZMCLOB			EQU 4			; replace destination if it exists

; --- Telnet command bytes used by the binary stream decoder ---
ZM_IAC			EQU 0xFF
ZM_WILL			EQU 0xFB
ZM_WONT			EQU 0xFC
ZM_DO			EQU 0xFD
ZM_DONT			EQU 0xFE
ZM_SB			EQU 0xFA
ZM_SE			EQU 0xF0

	MODULE ZM

; ------------------------------------------------------
; RECEIVE: entry from the telnet terminal once a header start was seen.
; In: HL = pointer to the unconsumed tail of the current TCP batch,
;     BC = its byte count (the handoff is intentionally discarded while the
;     ESP switches from transparent mode to back-pressured +IPD mode).
; The first repeated header chooses the role: ZRQINIT means the remote side is
; sending (download), while ZRINIT means it is receiving (upload).
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
	LD	(WCOMMON.CANCELLED),A
	LD	(IO_ERROR),A
	LD	(SP_TO_FILE),A
	LD	(HDR_WAIT),A
	LD	HL,0
	LD	(SRC_CNT),HL
	LD	(FPOS),HL
	LD	(FPOS+2),HL
	PRINT	WCOMMON.LINE_END
	PRINTLN	MSG_DETECT
.WAIT_ROLE
	CALL	RECV_HEADER
	JP	C,.GIVEUP
	CP	ZRQINIT
	JR	Z,.RX_START
	CP	ZRINIT
	JR	Z,.TX_START
	JR	.WAIT_ROLE

.TX_START
	CALL	SEND_FILE
	JP	C,.GIVEUP
	JP	.DONE

.RX_START
	PRINTLN	MSG_DOWNLOAD
.RX_SESSION
	CALL	SEND_ZRINIT		; advertise CRC16 / full duplex
	JP	C,.GIVEUP
.RX_NEXT_HDR
	LD	A,(ABORTED)		; Esc pressed during a read -> stop now
	OR	A
	JP	NZ,.GIVEUP
	CALL	RECV_HEADER		; A = frame type, CF=1 on fatal timeout/close
	JP	C,.GIVEUP
	CP	ZRQINIT
	JR	Z,.RX_SESSION		; sender still announcing
	CP	ZSINIT
	JR	Z,.RX_ZSINIT
	CP	ZFILE
	JR	Z,.RX_ZFILE
	CP	ZDATA
	JP	Z,.RX_ZDATA
	CP	ZEOF
	JP	Z,.RX_ZEOF
	CP	ZFIN
	JP	Z,.RX_ZFIN
	JR	.RX_NEXT_HDR		; ZSKIP/ZNAK/unknown -> keep listening

.RX_ZSINIT
	XOR	A
	LD	(SP_TO_FILE),A
	CALL	RECV_SUBPACKET		; attention string; currently ignored
	JR	C,.RX_SESSION
	CALL	SEND_ZACK_ZERO
	JP	C,.GIVEUP
	JP	.RX_NEXT_HDR

.RX_ZFILE
	CALL	CLOSE_OUTPUT		; a repeated offer replaces any partial prior file
	XOR	A
	LD	(SP_TO_FILE),A		; metadata stays in DATA_BUF; no file is open yet
	CALL	RECV_SUBPACKET		; name+info -> DATA_BUF, DE=len
	JR	C,.RX_SESSION		; bad subpacket -> resend ZRINIT
	CALL	OPEN_OUTPUT
	JP	C,.GIVEUP
	LD	HL,0
	LD	(FPOS),HL
	LD	(FPOS+2),HL
	CALL	SEND_ZRPOS
	JP	C,.GIVEUP
	JP	.RX_NEXT_HDR

.RX_ZDATA
	CALL	HDR_POS_MATCHES		; CF=0 if header pos == FPOS
	JR	NC,.RX_DATA_LOOP
	JP	.RX_RESYNC
.RX_DATA_LOOP
	LD	A,1
	LD	(SP_TO_FILE),A
	CALL	RECV_SUBPACKET		; DATA_BUF/DE=len, A=terminator
	JR	NC,.RX_SP_OK
	LD	A,(IO_ERROR)
	OR	A
	JP	NZ,.GIVEUP
	JP	.RX_RESYNC
.RX_SP_OK
	LD	(LAST_TERM),A		; RECV_SUBPACKET already wrote the data to disk
	CALL	SHOW_PROGRESS
	LD	A,(LAST_TERM)
	CP	ZCRCG
	JR	Z,.RX_DATA_LOOP
	CP	ZCRCQ
	JR	Z,.RX_DATA_ACK
	CP	ZCRCW
	JR	Z,.RX_DATA_ACK_END
	JP	.RX_NEXT_HDR		; ZCRCE / anything -> header follows
.RX_DATA_ACK
	CALL	SEND_ZACK
	JP	C,.GIVEUP
	JR	.RX_DATA_LOOP
.RX_DATA_ACK_END
	CALL	SEND_ZACK
	JP	C,.GIVEUP
	JP	.RX_NEXT_HDR
.RX_RESYNC
	CALL	SEND_ZRPOS		; tell the sender our position
	JP	C,.GIVEUP
	JP	.RX_NEXT_HDR

.RX_ZEOF
	CALL	HDR_POS_MATCHES		; all bytes received?
	JR	NC,.RX_EOF_OK
	JP	.RX_RESYNC
.RX_EOF_OK
	CALL	CLOSE_OUTPUT
	PRINTLN	MSG_FILE_OK
	JP	.RX_SESSION		; ready for the next file or ZFIN

.RX_ZFIN
	CALL	SEND_ZFIN
	JP	C,.GIVEUP
	CALL	WAIT_OO			; sender closes a successful session with "OO"
	CALL	CLOSE_OUTPUT
	JR	.DONE

.DONE
	CALL	CLOSE_OUTPUT
	PRINTLN	MSG_DONE
	JP	MAIN.ZM_RESUME_TRANSPARENT	; restore CIPMODE=1 + passthrough

.GIVEUP
	CALL	ABORT_TRANSFER
	PRINTLN	MSG_ABORT
	JP	MAIN.ZM_RESUME_TRANSPARENT	; restore CIPMODE=1 + passthrough

; ======================================================
; Upload (local sender)
; ======================================================

SEND_FILE
	PRINTLN	MSG_UPLOAD
	CALL	PROMPT_FILENAME
	RET	C
	CALL	OPEN_INPUT
	RET	C
	CALL	BUILD_FILE_INFO
	LD	A,ZM_SEND_RETRIES
	LD	(SEND_TRIES),A
.offer
	XOR	A
	LD	(TXP+0),A		; ZF3
	LD	(TXP+1),A		; ZF2: normal transport
	LD	A,ZMCLOB
	LD	(TXP+2),A		; ZF1: replace existing destination
	LD	A,ZCBIN
	LD	(TXP+3),A		; ZF0: binary, no conversion
	LD	A,ZFILE
	CALL	SEND_HDR_WAIT
	JP	C,.fail
	LD	HL,DATA_BUF
	LD	BC,(INFO_LEN)
	LD	A,ZCRCW
	CALL	SEND_SUBPACKET
	JP	C,.fail
.wait_pos
	CALL	RECV_HEADER
	JR	C,.retry_offer
	CP	ZRPOS
	JR	Z,.position
	CP	ZSKIP
	JP	Z,.skipped
	CP	ZRINIT
	JR	Z,.wait_pos		; discard an rz retry queued while user chose a file
	CP	ZNAK
	JR	Z,.retry_offer
	CP	ZFIN
	JP	Z,.fail
	CP	ZABORT
	JP	Z,.fail
	JR	.wait_pos
.retry_offer
	LD	A,(SEND_TRIES)
	DEC	A
	LD	(SEND_TRIES),A
	JR	NZ,.offer
	JP	.fail
.position
	CALL	SEEK_TO_HDR_POS
	JP	C,.fail
.next_chunk
	LD	A,ZM_SEND_RETRIES
	LD	(SEND_TRIES),A
.read_chunk
	CALL	READ_INPUT
	JP	C,.fail
	LD	A,D
	OR	E
	JP	Z,.start_eof
	LD	(TX_COUNT),DE
	LD	HL,(FPOS)
	LD	(SP_START),HL
	LD	HL,(FPOS+2)
	LD	(SP_START+2),HL
	CALL	COPY_FPOS_TO_TXP
	LD	A,ZDATA
	CALL	SEND_HDR_WAIT
	JP	C,.fail
	LD	HL,DATA_BUF
	LD	BC,(TX_COUNT)
	LD	A,ZCRCW			; stop-and-wait: slower, deterministic and retryable
	CALL	SEND_SUBPACKET
	JP	C,.fail
	LD	DE,(TX_COUNT)
	CALL	ADD_FPOS
	CALL	SHOW_PROGRESS
.wait_ack
	CALL	RECV_HEADER
	JR	C,.retry_chunk
	CP	ZACK
	JR	Z,.ack
	CP	ZRPOS
	JR	Z,.reposition
	CP	ZNAK
	JR	Z,.retry_chunk
	CP	ZSKIP
	JP	Z,.skipped
	CP	ZABORT
	JP	Z,.fail
	CP	ZFIN
	JP	Z,.fail
	LD	A,(SEND_TRIES)
	DEC	A
	LD	(SEND_TRIES),A
	JR	NZ,.wait_ack
	JP	.fail
.ack
	CALL	HDR_POS_MATCHES
	JR	NC,.next_chunk
	; A stale/different ZACK is treated like an explicit reposition request.
.reposition
	CALL	SEEK_TO_HDR_POS
	JP	C,.fail
	JR	.next_chunk
.retry_chunk
	LD	A,(SEND_TRIES)
	DEC	A
	LD	(SEND_TRIES),A
	JP	Z,.fail
	LD	A,1
	LD	(SP_TO_FILE),A
	CALL	SEEK_TO_SP_START
	JP	.read_chunk

.start_eof
	LD	A,ZM_SEND_RETRIES
	LD	(SEND_TRIES),A
.send_eof
	CALL	COPY_FPOS_TO_TXP
	LD	A,ZEOF
	CALL	SEND_HDR
	JR	C,.fail
.wait_eof
	CALL	RECV_HEADER
	JR	C,.retry_eof
	CP	ZRINIT
	JR	Z,.finish
	CP	ZRPOS
	JR	Z,.reposition
	CP	ZACK
	JR	Z,.retry_eof
	CP	ZSKIP
	JR	Z,.skipped
	CP	ZABORT
	JR	Z,.fail
.retry_eof
	LD	A,(SEND_TRIES)
	DEC	A
	LD	(SEND_TRIES),A
	JR	NZ,.send_eof
	JR	.fail

.skipped
	PRINTLN	MSG_SKIPPED
.finish
	CALL	CLOSE_OUTPUT
	CALL	SEND_ZFIN
	JR	C,.fail_closed
	LD	A,ZM_SEND_RETRIES
	LD	(SEND_TRIES),A
.wait_fin
	CALL	RECV_HEADER
	JR	C,.retry_fin
	CP	ZFIN
	JR	Z,.send_oo
	; Ignore unrelated delayed headers, but periodically resend ZFIN.
.retry_fin
	LD	A,(SEND_TRIES)
	DEC	A
	LD	(SEND_TRIES),A
	JR	Z,.fail_closed
	CALL	SEND_ZFIN
	JR	NC,.wait_fin
	JR	.fail_closed
.send_oo
	LD	HL,OO_SEQ
	LD	BC,2
	CALL	SEND_TCP_NO_WAIT
	RET
.fail
	CALL	CLOSE_OUTPUT
.fail_closed
	SCF
	RET

; Ask for a local file after the remote rz/ZRINIT is detected. Empty input or
; Esc cancels the transfer. DSS_ECHOKEY provides the visible line editing.
PROMPT_FILENAME
	PRINT	MSG_FILE_PROMPT
	LD	C,DSS_KCLEAR
	RST	DSS
	LD	HL,FNAME
	LD	(INPUT_PTR),HL
	XOR	A
	LD	(INPUT_LEN),A
.key
	LD	C,DSS_ECHOKEY
	RST	DSS
	CP	0x1B
	JR	Z,.cancel
	CP	13
	JR	Z,.done
	CP	10
	JR	Z,.done
	CP	8
	JR	Z,.backspace
	CP	0x20
	JR	C,.key
	LD	C,A
	LD	A,(INPUT_LEN)
	CP	ZM_FNAME_SIZE-1
	JR	NC,.key
	LD	HL,(INPUT_PTR)
	LD	(HL),C
	INC	HL
	LD	(INPUT_PTR),HL
	LD	A,(INPUT_LEN)
	INC	A
	LD	(INPUT_LEN),A
	JR	.key
.backspace
	LD	A,(INPUT_LEN)
	OR	A
	JR	Z,.key
	DEC	A
	LD	(INPUT_LEN),A
	LD	HL,(INPUT_PTR)
	DEC	HL
	LD	(INPUT_PTR),HL
	JR	.key
.done
	LD	HL,(INPUT_PTR)
	LD	(HL),0
	PRINT	WCOMMON.LINE_END
	LD	A,(INPUT_LEN)
	OR	A
	JR	Z,.cancel_no_line
	RET
.cancel
	PRINT	WCOMMON.LINE_END
.cancel_no_line
	SCF
	RET

OPEN_INPUT
	PRINT	MSG_SENDING
	PRINT	FNAME
	PRINT	WCOMMON.LINE_END
	LD	HL,FNAME
	LD	A,FM_READ
	LD	C,DSS_OPEN_FILE
	RST	DSS
	JR	C,.error
	LD	(FH),A
	LD	A,1
	LD	(FH_OPEN),A
	LD	A,(FH)
	LD	B,SEEK_END
	LD	HL,0
	LD	IX,0
	LD	C,DSS_MOVE_FP
	RST	DSS
	JR	C,.error_close
	LD	(FILE_SIZE),IX
	LD	(FILE_SIZE+2),HL
	LD	A,(FH)
	LD	B,0
	LD	HL,0
	LD	IX,0
	LD	C,DSS_MOVE_FP
	RST	DSS
	JR	C,.error_close
	LD	HL,0
	LD	(FPOS),HL
	LD	(FPOS+2),HL
	OR	A
	RET
.error_close
	CALL	CLOSE_OUTPUT
.error
	PRINTLN	MSG_FILE_ERROR
	SCF
	RET

; DATA_BUF = basename NUL, decimal size and standard metadata fields NUL.
BUILD_FILE_INFO
	LD	HL,FNAME
	LD	DE,FNAME
.find_end
	LD	A,(HL)
	OR	A
	JR	Z,.copy_name
	CP	'/'
	JR	Z,.new_base
	CP	92			; '\\'
	JR	Z,.new_base
	CP	':'
	JR	NZ,.find_next
.new_base
	PUSH	HL
	POP	DE
	INC	DE
.find_next
	INC	HL
	JR	.find_end
.copy_name
	LD	HL,DATA_BUF
.copy_loop
	LD	A,(DE)
	LD	(HL),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.copy_loop
	CALL	APPEND_FILE_SIZE
	LD	DE,FILE_INFO_SUFFIX
.suffix
	LD	A,(DE)
	LD	(HL),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.suffix
	LD	DE,DATA_BUF
	OR	A
	SBC	HL,DE
	LD	(INFO_LEN),HL
	RET

; Append FILE_SIZE as ten decimal digits (leading zeroes are valid decimal).
; Out: HL points just after the digits.
APPEND_FILE_SIZE
	PUSH	HL
	LD	HL,FILE_SIZE
	LD	DE,U32_WORK
	LD	BC,4
	LDIR
	POP	HL
	LD	IX,U32_POW10
	LD	B,10
.power
	XOR	A
	LD	(DEC_DIGIT),A
.subtract
	CALL	U32_WORK_GE_IX
	JR	C,.emit
	CALL	U32_WORK_SUB_IX
	LD	A,(DEC_DIGIT)
	INC	A
	LD	(DEC_DIGIT),A
	JR	.subtract
.emit
	LD	A,(DEC_DIGIT)
	ADD	A,'0'
	LD	(HL),A
	INC	HL
	LD	DE,4
	ADD	IX,DE
	DJNZ	.power
	RET

; CF=0 if U32_WORK >= little-endian dword at IX, CF=1 otherwise.
U32_WORK_GE_IX
	LD	A,(U32_WORK+3)
	CP	(IX+3)
	RET	NZ
	LD	A,(U32_WORK+2)
	CP	(IX+2)
	RET	NZ
	LD	A,(U32_WORK+1)
	CP	(IX+1)
	RET	NZ
	LD	A,(U32_WORK)
	CP	(IX+0)
	RET

U32_WORK_SUB_IX
	LD	A,(U32_WORK)
	SUB	(IX+0)
	LD	(U32_WORK),A
	LD	A,(U32_WORK+1)
	SBC	A,(IX+1)
	LD	(U32_WORK+1),A
	LD	A,(U32_WORK+2)
	SBC	A,(IX+2)
	LD	(U32_WORK+2),A
	LD	A,(U32_WORK+3)
	SBC	A,(IX+3)
	LD	(U32_WORK+3),A
	RET

READ_INPUT
	CALL	CHECK_ABORT
	RET	C
	CALL	WIFI.UART_RX_PAUSE
	LD	A,(FH)
	LD	HL,DATA_BUF
	LD	DE,ZM_TX_CHUNK
	LD	C,DSS_READ_FILE
	RST	DSS
	RET	NC
	LD	A,1
	LD	(IO_ERROR),A
	SCF
	RET

SEEK_TO_HDR_POS
	LD	A,(FH)
	LD	B,0
	LD	HL,(HDR_P2)
	LD	IX,(HDR_P0)
	LD	C,DSS_MOVE_FP
	RST	DSS
	RET	C
	LD	(FPOS),IX
	LD	(FPOS+2),HL
	OR	A
	RET

COPY_FPOS_TO_TXP
	LD	HL,FPOS
	LD	DE,TXP
	LD	BC,4
	LDIR
	RET

WAIT_OO
.first
	CALL	GETBYTE
	RET	C
	CP	'O'
	JR	NZ,.first
	CALL	GETBYTE
	RET	C
	CP	'O'
	JR	NZ,.first
	OR	A
	RET

; ======================================================
; Stream input
; ======================================================

; GETBYTE: next Telnet-decoded TCP byte. Telnet represents a literal 0xFF as
; IAC IAC; option commands and subnegotiations are transport control and are
; removed from the Zmodem stream. Out: A=byte, CF=0; CF=1 on timeout/close.
GETBYTE
.again
	CALL	GET_RAWBYTE
	RET	C
	CP	ZM_IAC
	RET	NZ
	CALL	GET_RAWBYTE
	RET	C
	CP	ZM_IAC
	JR	Z,.literal_iac
	CP	ZM_SB
	JR	Z,.subneg
	CP	ZM_WILL
	JR	C,.again		; one-byte Telnet command
	CP	ZM_DONT+1
	JR	NC,.again
	CALL	GET_RAWBYTE		; WILL/WONT/DO/DONT option byte
	RET	C
	JR	.again
.subneg
	CALL	GET_RAWBYTE
	RET	C
	CP	ZM_IAC
	JR	NZ,.subneg
	CALL	GET_RAWBYTE
	RET	C
	CP	ZM_IAC
	JR	Z,.subneg		; escaped IAC inside SB
	CP	ZM_SE
	JR	NZ,.subneg
	JR	.again
.literal_iac
	LD	A,ZM_IAC
	OR	A
	RET

; GET_RAWBYTE: next byte from the +IPD payload before Telnet decoding.
GET_RAWBYTE
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
.raw
	CALL	GETBYTE
	RET	C
	CP	XON
	JR	Z,.raw
	CP	XOFF
	JR	Z,.raw
	CP	XON | 0x80
	JR	Z,.raw
	CP	XOFF | 0x80
	JR	Z,.raw
	CP	ZDLE
	JR	Z,.esc
	LD	B,0
	OR	A
	RET
.esc
	CALL	GETBYTE
	RET	C
	CP	XON
	JR	Z,.esc
	CP	XOFF
	JR	Z,.esc
	CP	XON | 0x80
	JR	Z,.esc
	CP	XOFF | 0x80
	JR	Z,.esc
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
	PUSH	AF
	AND	0x60
	CP	0x40
	POP	AF
	JR	NZ,.bad
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
.bad
	SCF
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
	LD	A,(HDR_TYPE)
	OR	A			; CF=0
	RET
.crcfail
.retry
	LD	A,(HDR_TRY)
	DEC	A
	LD	(HDR_TRY),A
	JR	NZ,.again
.fail
	SCF
	RET
.timeout
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
	RET	C
	CALL	GETBYTE			; trailing LF
	RET	C
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

; RECV_BIN32: CRC32 is deliberately unsupported and never advertised. Consume
; the complete header to keep framing aligned, then reject it.
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
	SCF
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
	JP	CRC_FINISH

; GET_HEXBYTE: two hex chars -> A=byte. CF=1 on stream error.
GET_HEXBYTE
	CALL	GETBYTE
	RET	C
	CALL	UNHEX
	RET	C
	RLCA
	RLCA
	RLCA
	RLCA
	AND	0xF0
	LD	C,A
	CALL	GETBYTE
	RET	C
	CALL	UNHEX
	RET	C
	OR	C
	OR	A			; CF=0
	RET

; ======================================================
; Data subpacket receive
; ======================================================

; RECV_SUBPACKET: buffer one complete subpacket, verify CRC, then commit it.
; Nothing reaches disk before CRC succeeds, so a retry cannot leave stale bytes
; beyond the eventual EOF. ZRINIT advertises the matching 8 KB maximum.
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
	; Data is held until CRC succeeds. Reject an oversized non-standard packet.
	LD	HL,(SP_LEN)
	LD	DE,ZM_DATA_SIZE
	OR	A
	SBC	HL,DE
	JR	C,.store		; len < size
	JR	.overflow
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
	CALL	CRC_FINISH		; Zmodem CRC-16 appends two zero bytes
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
	LD	A,(SP_TO_FILE)
	OR	A
	JR	Z,.metadata_ok
	CALL	FLUSH_BUF		; CRC ok -> commit the buffer tail now
	JR	C,.writeerr
	JR	.good
.metadata_ok
	LD	DE,(SP_LEN)
.good
	LD	A,(SP_TERM)
	OR	A			; CF=0
	RET
.crcbad
	SCF
	RET
.streamerr
	SCF
	RET
.writeerr
	SCF
	RET
.overflow
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
	CALL	WIFI.UART_RX_PAUSE	; remain paused until the next FILL
	LD	A,(FH)
	LD	HL,DATA_BUF
	POP	DE
	PUSH	DE
	LD	C,DSS_WRITE
	RST	DSS			; A=handle, HL=buf, DE=count
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
	LD	A,1
	LD	(IO_ERROR),A
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

; SEND_ZRINIT: advertise the complete verified-subpacket buffer in ZP0/ZP1,
; request control-byte escaping, CRC-16 and conservative non-overlapped I/O.
SEND_ZRINIT
	LD	A,low ZM_RX_WINDOW
	LD	(TXP+0),A
	LD	A,high ZM_RX_WINDOW
	LD	(TXP+1),A
	XOR	A
	LD	(TXP+2),A
	; Request CRC-16 and full control-byte escaping. CANOVIO is deliberately
	; clear: DSS disk I/O is slower than the UART and we want conservative flow.
	LD	A,CANFDX | ESCCTL
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

SEND_ZACK_ZERO
	XOR	A
	LD	(TXP+0),A
	LD	(TXP+1),A
	LD	(TXP+2),A
	LD	(TXP+3),A
	LD	A,ZACK
	JR	SEND_HDR

SEND_ZFIN
	XOR	A
	LD	(TXP+0),A
	LD	(TXP+1),A
	LD	(TXP+2),A
	LD	(TXP+3),A
	LD	A,ZFIN
	JR	SEND_HDR

SEND_HDR_WAIT
	LD	(HDR_TYPE_OUT),A
	LD	A,1
	LD	(HDR_WAIT),A
	LD	A,(HDR_TYPE_OUT)
	CALL	SEND_HDR
	PUSH	AF
	XOR	A
	LD	(HDR_WAIT),A
	POP	AF
	RET

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
	CALL	CRC_FINISH
	LD	A,H
	CALL	PUTHEX
	LD	A,L
	CALL	PUTHEX
	LD	A,0x0D
	CALL	PUT
	LD	A,0x8A			; standard Zmodem hex-header LF with parity bit
	CALL	PUT
	LD	A,(SEND_T)
	CP	ZFIN
	JR	Z,.built
	CP	ZACK
	JR	Z,.built
	LD	A,XON
	CALL	PUT
.built
	; length = TXP_DST - TXBUF
	LD	HL,(TXP_DST)
	LD	DE,TXBUF
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,TXBUF
	LD	A,(HDR_WAIT)
	OR	A
	JP	NZ,SEND_TCP_WAIT	; peer cannot reply before the following subpacket
	; Otherwise do not wait for SEND OK: it could consume the peer's reply.
	JP	SEND_TCP_NO_WAIT

; ESP command replies are also subject to RTS/CTS. Raise RTS before CIPSEND,
; then lower it immediately after the payload so protocol parsing and DSS I/O
; cannot overrun the UART FIFO.
SEND_TCP_NO_WAIT
	CALL	WIFI.UART_RX_RESUME
	CALL	TCP.SEND_BUFFER_NO_WAIT
	PUSH	AF
	CALL	WIFI.UART_RX_PAUSE
	POP	AF
	RET

SEND_TCP_WAIT
	CALL	WIFI.UART_RX_RESUME
	CALL	TCP.SEND_BUFFER
	PUSH	AF
	CALL	WIFI.UART_RX_PAUSE
	POP	AF
	RET

; SEND_SUBPACKET: encode BC bytes at HL with ZDLE quoting, append the requested
; terminator and CRC-16, then send as one TCP payload. Full control escaping
; honors ESCCTL; 0xFF uses ZRUB1 so no literal Telnet IAC reaches the wire.
SEND_SUBPACKET
	LD	(TX_TERM),A
	LD	(TX_SRC),HL
	LD	(TX_LEFT),BC
	LD	HL,TXDATA_BUF
	LD	(TXP_DST),HL
	LD	HL,0
	LD	(SEND_CRC),HL
.byte
	LD	HL,(TX_LEFT)
	LD	A,H
	OR	L
	JR	Z,.term
	DEC	HL
	LD	(TX_LEFT),HL
	LD	HL,(TX_SRC)
	LD	A,(HL)
	INC	HL
	LD	(TX_SRC),HL
	PUSH	AF
	LD	HL,(SEND_CRC)
	CALL	CRC_UPD
	LD	(SEND_CRC),HL
	POP	AF
	CALL	PUT_ESCAPED
	JR	.byte
.term
	LD	A,ZDLE
	CALL	PUT
	LD	A,(TX_TERM)
	CALL	PUT
	LD	HL,(SEND_CRC)
	CALL	CRC_UPD
	CALL	CRC_FINISH
	LD	(SEND_CRC),HL
	LD	A,H
	CALL	PUT_ESCAPED
	LD	HL,(SEND_CRC)
	LD	A,L
	CALL	PUT_ESCAPED
	LD	A,(TX_TERM)
	CP	ZCRCW
	JR	NZ,.built
	LD	A,XON
	CALL	PUT
.built
	LD	HL,(TXP_DST)
	LD	DE,TXDATA_BUF
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,TXDATA_BUF
	JP	SEND_TCP_NO_WAIT

PUT_ESCAPED
	CP	0x7F
	JR	Z,.rub0
	CP	0xFF
	JR	Z,.rub1
	LD	C,A
	AND	0x60
	LD	A,C
	JP	NZ,PUT
	LD	A,ZDLE
	CALL	PUT
	LD	A,C
	XOR	0x40
	JP	PUT
.rub0
	LD	A,ZDLE
	CALL	PUT
	LD	A,ZRUB0
	JP	PUT
.rub1
	LD	A,ZDLE
	CALL	PUT
	LD	A,ZRUB1
	JP	PUT

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

; UNHEX: hex char in A -> nibble (0..15), CF=0. CF=1 if invalid.
UNHEX
	CP	'0'
	JR	C,.bad
	CP	'9'+1
	JR	C,.digit
	CP	'A'
	JR	C,.bad
	CP	'F'+1
	JR	C,.upper
	CP	'a'
	JR	C,.bad
	CP	'f'+1
	JR	NC,.bad
	SUB	'a'-10
	OR	A
	RET
.upper
	SUB	'A'-10
	OR	A
	RET
.digit
	SUB	'0'
	OR	A
	RET
.bad
	SCF
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

; Zmodem transmits the CRC-16 remainder after advancing it with two zero bytes
; (unlike the shorter CRC calculation previously used here).
CRC_FINISH
	XOR	A
	CALL	CRC_UPD
	XOR	A
	JP	CRC_UPD

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

; OPEN_OUTPUT: keep only the offered basename, then create/overwrite it.
OPEN_OUTPUT
	LD	HL,DATA_BUF
	LD	DE,DATA_BUF
.scan
	LD	A,(HL)
	OR	A
	JR	Z,.copy_start
	CP	'/'
	JR	Z,.new_base
	CP	92
	JR	Z,.new_base
	CP	':'
	JR	NZ,.scan_next
.new_base
	PUSH	HL
	POP	DE
	INC	DE
.scan_next
	INC	HL
	JR	.scan
.copy_start
	EX	DE,HL
	LD	A,(HL)
	OR	A
	JR	Z,.bad_name
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
.bad_name
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
	CALL	SEND_TCP_WAIT
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

; ======================================================
; Messages
; ======================================================
MSG_DETECT
	DB "Zmodem detected (Esc aborts)...",0
MSG_DOWNLOAD
	DB "Zmodem download.",0
MSG_UPLOAD
	DB "Zmodem upload.",0
MSG_FILE_PROMPT
	DB "Local file: ",0
MSG_SENDING
	DB "Sending ",0
MSG_RECV
	DB "Receiving ",0
MSG_FILE_OK
	DB " OK",0
MSG_DONE
	DB "Zmodem done.",0
MSG_ABORT
	DB "Zmodem aborted.",0
MSG_SKIPPED
	DB "Remote skipped the file.",0
MSG_FILE_ERROR
	DB "Cannot open/read local file.",0

OO_SEQ
	DB "OO"
FILE_INFO_SUFFIX
	DB " 0 0 0 1 0",0
U32_POW10
	DD 1000000000
	DD 100000000
	DD 10000000
	DD 1000000
	DD 100000
	DD 10000
	DD 1000
	DD 100
	DD 10
	DD 1

CANSEQ
	DB 0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18
	DB 0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08
CANSEQ_LEN	EQU $-CANSEQ

; ======================================================
; Small state is initialised in the EXE. Large buffers are EQU maps in the
; DSS-allocated WIN2 page, so they do not bloat the executable.
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
HDR_WAIT	DB 0
HDR_TYPE_OUT	DB 0
SEND_CRC	DW 0
TXP_DST		DW 0
TXP		DS 4,0
FH		DB 0
FH_OPEN		DB 0
ABORTED		DB 0
IO_ERROR	DB 0
SP_TO_FILE	DB 0
FPOS		DS 4,0
FILE_SIZE	DS 4,0
INFO_LEN	DW 0
TX_COUNT	DW 0
TX_TERM		DB 0
TX_SRC		DW 0
TX_LEFT		DW 0
SEND_TRIES	DB 0
INPUT_PTR	DW 0
INPUT_LEN	DB 0
U32_WORK	DS 4,0
DEC_DIGIT	DB 0

RXBUF		EQU WIN2_BASE
DATA_BUF	EQU RXBUF + ZM_RXBUF_SIZE
TXDATA_BUF	EQU DATA_BUF + ZM_DATA_SIZE
TXBUF		EQU TXDATA_BUF		; hex headers reuse the encoded-TX staging area
FNAME		EQU TXDATA_BUF + ZM_TXDATA_SIZE
ZM_BSS_END	EQU FNAME + ZM_FNAME_SIZE

	ASSERT	TXBUF + ZM_TXBUF_SIZE <= FNAME
	ASSERT	ZM_BSS_END <= 0xC000

	ENDMODULE

	ENDIF

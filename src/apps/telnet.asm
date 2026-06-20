; ======================================================
; TELNET for Sprinter DSS Network Kit
; Phase 0: raw telnet client over ESP-AT TCP.
;
; Connects to a telnet host (default port 23), runs an interactive
; half-duplex loop that polls TCP.RECEIVE for incoming data and forwards
; typed keys with TCP.SEND_BUFFER. A minimal telnet IAC state machine
; answers option negotiation so BBSes do not stall. Output is rendered with
; ANSI escape sequences STRIPPED for now (a real ANSI/CP437 emulator is a
; later phase); printable text and CR/LF are shown.
;
; Quit with Alt+X. Every other key, including Esc, is forwarded to the BBS
; (many BBSes use Esc for navigation). Arrow keys are not yet mapped.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
; Per-iteration RX poll window. Bounds key latency AND must stay well under
; 200 ms: TCP.RECEIVE's internal Esc/Ctrl+Z cancel poll
; (WCOMMON.CHECK_CANCEL_IN_ISA) only fires after ~200 one-ms waits within a
; single byte read, so a sub-200 ms timeout keeps that poll dormant and leaves
; Esc free to reach the BBS instead of aborting the session.
RECV_POLL_MS		EQU 20
RECV_BUFFER_SIZE	EQU 512
HOST_SIZE		EQU 96
PORT_SIZE		EQU 8
NEG_BUF_SIZE		EQU 96			; batched IAC negotiation/subneg replies
OPEN_RETRIES		EQU 4			; CIPSTART retries (ESP "busy" right after NETUP)
OPEN_RETRY_DELAY	EQU 600			; ms between CIPSTART retries

; --- Telnet protocol bytes (RFC 854) ---
TN_IAC			EQU 255
TN_DONT			EQU 254
TN_DO			EQU 253
TN_WONT			EQU 252
TN_WILL			EQU 251
TN_SB			EQU 250
TN_SE			EQU 240
; --- Telnet options we react to ---
TNOPT_ECHO		EQU 1
TNOPT_SGA		EQU 3
TNOPT_TTYPE		EQU 24			; TERMINAL-TYPE (RFC 1091)
TNOPT_NAWS		EQU 31			; window size (RFC 1073)
TTYPE_IS		EQU 0
TTYPE_SEND		EQU 1

; --- Telnet RX state machine ---
S_NORMAL		EQU 0
S_IAC			EQU 1
S_NEG			EQU 2			; waiting for option byte; TN_CMD holds WILL..DONT
S_SB			EQU 3			; inside subnegotiation
S_SB_IAC		EQU 4			; saw IAC inside subnegotiation

; --- Output (ANSI-strip) state machine ---
O_NORMAL		EQU 0
O_ESC			EQU 1			; saw ESC, expect '['
O_CSI			EQU 2			; inside CSI, skip until final byte

; --- Screen layout ---
; Sprinter DSS_VMOD_T80 is an 80x32, 16-colour text mode. Width stays 80
; (BBS ANSI art is authored for 80 columns). The bottom STATUS_ROWS rows are
; reserved for a persistent status line; the BBS is told the remaining height
; via NAWS, and the Phase 2 emulator confines its scroll region to TERM_ROWS.
SCREEN_COLS		EQU 80
SCREEN_ROWS		EQU 32
STATUS_ROWS		EQU 1
TERM_COLS		EQU SCREEN_COLS
TERM_ROWS		EQU SCREEN_ROWS - STATUS_ROWS	; 31 rows offered to the BBS
STATUS_ROW		EQU SCREEN_ROWS - 1		; bottom row = persistent status
STATUS_ATTR		EQU 0x17			; white ink (7) on blue paper (1)
DEF_ATTR		EQU 0x07			; default white on black
MAX_PARAMS		EQU 8				; CSI parameters captured per sequence

; DSS text-screen functions (RST #10, C=func). Estex-DSS API numbers; the few
; already in dss.inc (CLEAR #56, PUTCHAR #5B) are reused from there.
DSS_LOCATE		EQU 0x52			; D=row, E=col  (set cursor)
DSS_SCROLL		EQU 0x55			; D=row E=col H=h L=w B=1up/2down A=0
DSS_WRCHAR		EQU 0x58			; D=row E=col A=char B=attr

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

START
	; DSS passes the command-line buffer pointer in IX at entry; capture it
	; before any CALL clobbers IX (load-#80 = 0x8080 is the default, not assumed).
	LD	(CMDLINE_PTR),IX
	CALL	ISA.ISA_RESET
	CALL	WCOMMON.INIT_VMODE
	PRINTLN	MSG_START

	CALL	INIT_DEFAULT_ARGS
	CALL	PARSE_CMD_LINE
	JP	C,USAGE

	PRINT	MSG_TARGET
	PRINT	HOST_BUFF
	PRINT	MSG_COLON
	PRINTLN	PORT_BUFF

	CALL	WIFI.UART_FIND
	JP	C,NO_WIFI
	CALL	WCOMMON.REQUIRE_NET_UP

	CALL	NETCFG.LOAD
	CALL	NETCFG.APPLY_UART_BAUD
	CALL	WIFI.UART_INIT

	LD	HL,CMD_AT
	CALL	SEND_CMD_RECOVER
	LD	HL,CMD_ECHO_OFF
	CALL	SEND_CMD
	LD	HL,CMD_CIPMUX_0
	CALL	SEND_CMD

	PRINT	MSG_CONNECTING
	PRINT	HOST_BUFF
	PRINTLN	WCOMMON.LINE_END
	CALL	CONNECT_TCP
	JP	C,CONNECT_FAILED

	PRINTLN	MSG_CONNECTED

	; Reset session state machines.
	XOR	A
	LD	(TN_STATE),A
	LD	(OUT_STATE),A
	LD	(NEG_LEN),A
	; Hand the screen over to the emulator: clear the terminal region and paint
	; the status row. From here output goes through WrChar, not the DSS console.
	CALL	INIT_SCREEN
	CALL	DRAW_STATUS

; ------------------------------------------------------
; Interactive loop: forward keys, render incoming data.
; ------------------------------------------------------
MAIN_LOOP
.DRAIN_KEYS
	CALL	HANDLE_KEY
	JR	C,QUIT				; Alt+X requested
	JR	NZ,.DRAIN_KEYS			; a key was handled - drain the rest of the buffer

	; Poll for incoming TCP data.
	LD	HL,RECV_BUFFER
	LD	BC,RECV_BUFFER_SIZE
	LD	DE,RECV_POLL_MS
	CALL	TCP.RECEIVE
	JR	C,.RX_NONE

	; Got BC bytes: pause ESP TX while we render, then process and flush
	; any negotiation replies the batch produced.
	LD	A,B
	OR	C
	JR	Z,MAIN_LOOP
	CALL	WIFI.UART_RX_PAUSE
	LD	HL,RECV_BUFFER
	CALL	PROCESS_RX
	CALL	WIFI.UART_RX_RESUME
	CALL	SYNC_CURSOR			; park the hardware cursor at the emulator cursor
	CALL	FLUSH_NEG
	JR	MAIN_LOOP

.RX_NONE
	; CF=1: either a plain poll timeout (no data) or the link closed. A holds
	; the TCP.RECEIVE result code.
	CP	RES_NOT_CONN
	JR	Z,REMOTE_CLOSED
	JR	MAIN_LOOP

REMOTE_CLOSED
	PRINT	WCOMMON.LINE_END
	PRINTLN	MSG_CLOSED
	LD	B,0
	JP	WCOMMON.EXIT

QUIT
	PRINT	WCOMMON.LINE_END
	CALL	TCP.CLOSE
	PRINTLN	MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

CONNECT_FAILED
	; CIPSTART came back ERROR/timeout: name did not resolve, host is down, or
	; the port refused the connection. Report it in plain language (exit 3 =
	; unreachable host per the kit's exit-status guidelines).
	PRINT	MSG_NO_CONNECT
	PRINT	HOST_BUFF
	PRINT	MSG_COLON
	PRINTLN	PORT_BUFF
	PRINTLN	MSG_NO_CONNECT_HINT
	LD	B,3
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN	MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

USAGE
	PRINTLN	MSG_USAGE
	LD	B,1
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; HANDLE_KEY: poll the keyboard once.
;   Out: CF=1            -> Alt+X pressed (quit).
;        CF=0, ZF=0 (NZ) -> a key was handled (caller drains for more).
;        CF=0, ZF=1 (Z)  -> no key pending.
; Alt+X is the ONLY quit; every other key is forwarded to the host: Enter as
; CR,LF and any other ASCII (including control codes such as Esc 0x1B, Tab,
; Backspace) as-is, so BBSes that navigate with Esc work. Keys with no ASCII
; (E=0) carry a scancode in D - arrows and Home/End/PgUp/PgDn/Del are mapped to
; their ANSI sequences (SEND_SPECIAL_KEY); anything else is consumed.
; ------------------------------------------------------
HANDLE_KEY
	DSS_EXEC	DSS_SCANKEY
	JR	Z,.NO_KEY			; no key pressed
	; Alt+X quits (scancode in D, same check as WTERM).
	LD	A,D
	CP	0xAB
	JR	NZ,.SEND
	LD	A,B
	AND	KB_ALT
	JR	Z,.SEND
	SCF					; quit
	RET
.SEND
	LD	A,E
	AND	A
	JR	Z,.SPECIAL			; no ASCII -> arrow/navigation key (scancode in D)
	CP	CR
	JR	Z,.SEND_CRLF
	LD	(TX_BUF),A
	LD	HL,TX_BUF
	LD	BC,1
	CALL	TCP.SEND_BUFFER
	JR	.HANDLED
.SPECIAL
	CALL	SEND_SPECIAL_KEY		; D = scancode; sends an ANSI seq if known
	JR	.HANDLED
.SEND_CRLF
	LD	A,CR
	LD	(TX_BUF),A
	LD	A,LF
	LD	(TX_BUF+1),A
	LD	HL,TX_BUF
	LD	BC,2
	CALL	TCP.SEND_BUFFER
.HANDLED
	OR	1				; ZF=0 (key handled), CF=0
	RET
.NO_KEY
	XOR	A				; ZF=1 (no key), CF=0
	RET

; ------------------------------------------------------
; SEND_SPECIAL_KEY: D = scancode of a non-ASCII key. If it is a known
; navigation key, transmit its ANSI escape sequence to the host; otherwise do
; nothing. Scancodes are the DSS values used by the Sprinter text editor.
; ------------------------------------------------------
SEND_SPECIAL_KEY
	LD	HL,KEYMAP
.scan
	LD	A,(HL)				; scancode entry (0 = end)
	OR	A
	RET	Z				; unknown key -> ignore
	CP	D
	JR	Z,.found
	INC	HL				; skip scancode + 2-byte seq pointer
	INC	HL
	INC	HL
	JR	.scan
.found
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)				; DE -> ASCIIZ sequence
	EX	DE,HL				; HL -> sequence
; SEND_ASCIIZ: transmit the ASCIIZ string at HL over TCP.
SEND_ASCIIZ
	PUSH	HL
	LD	BC,0
.len
	LD	A,(HL)
	OR	A
	JR	Z,.go
	INC	HL
	INC	BC
	JR	.len
.go
	POP	HL
	JP	TCP.SEND_BUFFER

; Scancode -> ANSI sequence map (terminated by scancode 0). Arrows use normal
; cursor-key mode (CSI), the form BBS menus expect.
KEYMAP
	DB	0x58
	DW	SEQ_UP
	DB	0x52
	DW	SEQ_DOWN
	DB	0x56
	DW	SEQ_RIGHT
	DB	0x54
	DW	SEQ_LEFT
	DB	0x57
	DW	SEQ_HOME
	DB	0x51
	DW	SEQ_END
	DB	0x59
	DW	SEQ_PGUP
	DB	0x53
	DW	SEQ_PGDN
	DB	0x4F
	DW	SEQ_DEL
	DB	0
SEQ_UP		DB 27,"[A",0
SEQ_DOWN	DB 27,"[B",0
SEQ_RIGHT	DB 27,"[C",0
SEQ_LEFT	DB 27,"[D",0
SEQ_HOME	DB 27,"[H",0
SEQ_END		DB 27,"[F",0
SEQ_PGUP	DB 27,"[5~",0
SEQ_PGDN	DB 27,"[6~",0
SEQ_DEL		DB 27,"[3~",0

; ------------------------------------------------------
; PROCESS_RX: run BC bytes at HL through the telnet IAC state machine.
; Plain data bytes go to OUTPUT_BYTE; negotiation replies are queued in NEG_BUF.
; ------------------------------------------------------
PROCESS_RX
.NEXT
	LD	A,B
	OR	C
	RET	Z
	LD	A,(HL)
	INC	HL
	DEC	BC
	PUSH	BC,HL
	LD	C,A				; C = current byte
	CALL	PROCESS_RX_BYTE
	POP	HL,BC
	JR	.NEXT

; In: C = byte. Dispatches on TN_STATE.
PROCESS_RX_BYTE
	LD	A,(TN_STATE)
	CP	S_IAC
	JR	Z,.ST_IAC
	CP	S_NEG
	JR	Z,.ST_NEG
	CP	S_SB
	JR	Z,.ST_SB
	CP	S_SB_IAC
	JR	Z,.ST_SB_IAC
; --- S_NORMAL ---
	LD	A,C
	CP	TN_IAC
	JR	Z,.TO_IAC
	JP	OUTPUT_BYTE
.TO_IAC
	LD	A,S_IAC
	LD	(TN_STATE),A
	RET
; --- S_IAC: byte after an IAC ---
.ST_IAC
	LD	A,C
	CP	TN_IAC
	JR	Z,.IAC_LITERAL			; IAC IAC -> literal 0xFF
	CP	TN_SB
	JR	Z,.IAC_SB
	CP	TN_WILL
	JR	C,.IAC_OTHER			; <251 (and !=250): 1-byte command, ignore
	CP	TN_DONT+1
	JR	NC,.IAC_OTHER			; >254: ignore
	; WILL/WONT/DO/DONT -> remember command, expect option next.
	LD	A,C
	LD	(TN_CMD),A
	LD	A,S_NEG
	LD	(TN_STATE),A
	RET
.IAC_LITERAL
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	LD	C,TN_IAC
	JP	OUTPUT_BYTE
.IAC_SB
	XOR	A
	LD	(SB_IDX),A			; start capturing the subnegotiation
	LD	A,S_SB
	LD	(TN_STATE),A
	RET
.IAC_OTHER
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	RET
; --- S_NEG: C = option byte, TN_CMD = WILL..DONT ---
.ST_NEG
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	JP	NEGOTIATE			; uses C = option
; --- S_SB: capture the first two data bytes (option, subcommand), skip the
; rest, until IAC SE. We only need <option><subcommand> to recognise the
; TERMINAL-TYPE SEND request. ---
.ST_SB
	LD	A,C
	CP	TN_IAC
	JR	Z,.SB_TO_IAC
	LD	A,(SB_IDX)
	CP	2
	RET	NC				; already captured option + subcommand
	LD	E,A
	LD	D,0
	LD	HL,SB_OPT			; SB_OPT, SB_SUB are consecutive
	ADD	HL,DE
	LD	(HL),C
	INC	A
	LD	(SB_IDX),A
	RET
.SB_TO_IAC
	LD	A,S_SB_IAC
	LD	(TN_STATE),A
	RET
.ST_SB_IAC
	LD	A,C
	CP	TN_SE
	JR	Z,.SB_END
	; IAC <other> inside SB (e.g. escaped IAC IAC) -> stay in SB.
	LD	A,S_SB
	LD	(TN_STATE),A
	RET
.SB_END
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	; TERMINAL-TYPE SEND -> answer with our terminal type ("ANSI").
	LD	A,(SB_OPT)
	CP	TNOPT_TTYPE
	RET	NZ
	LD	A,(SB_SUB)
	CP	TTYPE_SEND
	RET	NZ
	LD	HL,TTYPE_REPLY
	LD	B,TTYPE_REPLY_LEN
	JP	QUEUE_BYTES

; ------------------------------------------------------
; NEGOTIATE: respond to an option demand. In: TN_CMD = WILL/WONT/DO/DONT,
; C = option. Minimal converging policy (only demands get a reply):
;   WILL ECHO  -> DO ECHO    (let server echo our keys)
;   WILL SGA   -> DO SGA
;   WILL <x>   -> DONT <x>
;   DO   SGA   -> WILL SGA   (we will suppress go-ahead)
;   DO   TTYPE -> WILL TTYPE (then answer SB SEND with "ANSI" -> full ANSI art)
;   DO   NAWS  -> WILL NAWS  + send our 80x25 window size via SB
;   DO   <x>   -> WONT <x>
;   WONT/DONT  -> ignored    (acks; replying would risk a negotiation loop)
; Reply bytes are appended to NEG_BUF and sent later by FLUSH_NEG.
; ------------------------------------------------------
NEGOTIATE
	LD	A,(TN_CMD)
	CP	TN_WILL
	JR	Z,.ON_WILL
	CP	TN_DO
	JR	Z,.ON_DO
	RET					; WONT / DONT -> no reply
.ON_WILL
	LD	A,C
	CP	TNOPT_ECHO
	JR	Z,.REPLY_DO
	CP	TNOPT_SGA
	JR	Z,.REPLY_DO
	LD	A,TN_DONT
	JP	QUEUE_CMD
.REPLY_DO
	LD	A,TN_DO
	JP	QUEUE_CMD
.ON_DO
	LD	A,C
	CP	TNOPT_SGA
	JR	Z,.REPLY_WILL
	CP	TNOPT_TTYPE
	JR	Z,.REPLY_WILL
	CP	TNOPT_NAWS
	JR	Z,.DO_NAWS
	LD	A,TN_WONT
	JP	QUEUE_CMD
.REPLY_WILL
	LD	A,TN_WILL
	JP	QUEUE_CMD
.DO_NAWS
	LD	A,TN_WILL
	CALL	QUEUE_CMD			; IAC WILL NAWS
	LD	HL,NAWS_REPLY			; IAC SB NAWS 0 80 0 25 IAC SE
	LD	B,NAWS_REPLY_LEN
	JP	QUEUE_BYTES

; ------------------------------------------------------
; QUEUE_CMD: append a 3-byte option reply (IAC, cmd in A, opt in C) to NEG_BUF.
; QUEUE_BYTES: append B bytes from HL to NEG_BUF.
; NEG_PUT_BYTE: append the byte in A to NEG_BUF (dropped if full). All three
; preserve BC, DE, HL so callers can loop. NEG_PUT_BYTE clobbers A.
; ------------------------------------------------------
QUEUE_CMD
	PUSH	BC
	LD	B,A				; B = reply command
	LD	A,TN_IAC
	CALL	NEG_PUT_BYTE
	LD	A,B
	CALL	NEG_PUT_BYTE
	LD	A,C
	CALL	NEG_PUT_BYTE
	POP	BC
	RET

QUEUE_BYTES
	LD	A,B
	AND	A
	RET	Z
.LOOP
	LD	A,(HL)
	CALL	NEG_PUT_BYTE
	INC	HL
	DJNZ	.LOOP
	RET

NEG_PUT_BYTE
	PUSH	BC,DE,HL
	LD	C,A				; C = byte to store
	LD	A,(NEG_LEN)
	CP	NEG_BUF_SIZE
	JR	NC,.FULL			; no room - drop it
	LD	E,A
	LD	D,0
	LD	HL,NEG_BUF
	ADD	HL,DE
	LD	(HL),C
	INC	A
	LD	(NEG_LEN),A
.FULL
	POP	HL,DE,BC
	RET

; ------------------------------------------------------
; FLUSH_NEG: send queued negotiation replies (if any) and clear the buffer.
; ------------------------------------------------------
FLUSH_NEG
	LD	A,(NEG_LEN)
	AND	A
	RET	Z
	LD	C,A
	LD	B,0
	LD	HL,NEG_BUF
	CALL	TCP.SEND_BUFFER
	XOR	A
	LD	(NEG_LEN),A
	RET

; Subnegotiation reply templates.
TTYPE_REPLY
	DB	TN_IAC,TN_SB,TNOPT_TTYPE,TTYPE_IS,"ANSI",TN_IAC,TN_SE
TTYPE_REPLY_LEN	EQU $-TTYPE_REPLY
; IAC SB NAWS <width16> <height16> IAC SE. Values stay below 255, so none need
; the IAC-doubling NAWS would otherwise require.
NAWS_REPLY
	DB	TN_IAC,TN_SB,TNOPT_NAWS
	DB	high TERM_COLS, low TERM_COLS
	DB	high TERM_ROWS, low TERM_ROWS
	DB	TN_IAC,TN_SE
NAWS_REPLY_LEN	EQU $-NAWS_REPLY

; ======================================================
; ANSI/VT100 terminal emulator (Phase 2)
; Renders the post-telnet byte stream straight to the DSS text screen via
; WrChar(#58)/Clear(#56)/Scroll(#55). No shadow buffer: the cursor
; (CUR_ROW 0..TERM_ROWS-1, CUR_COL 0..TERM_COLS-1) and colour (CUR_ATTR,
; derived from FG/BG/BOLD/REV) are tracked here and characters are written at
; absolute positions. The status row (SCREEN_ROWS-1) is never touched.
; PROCESS_RX runs with the ISA window closed (TCP.RECEIVE closed it) and RTS
; deasserted, so DSS calls are safe and the ESP is paused while we render.
; ======================================================

; OUTPUT_BYTE: feed one data byte (C) through the emulator state machine.
OUTPUT_BYTE
	LD	A,(OUT_STATE)
	CP	O_ESC
	JR	Z,.IN_ESC
	CP	O_CSI
	JP	Z,.IN_CSI
; --- O_NORMAL ---
	LD	A,C
	CP	0x1B				; ESC -> start an escape sequence
	JR	Z,.TO_ESC
	JP	TERM_CHAR			; printable byte or C0 control
.TO_ESC
	LD	A,O_ESC
	LD	(OUT_STATE),A
	RET
; --- O_ESC: expect '[' for a CSI; any other ESC<x> is ignored ---
.IN_ESC
	LD	A,C
	CP	'['
	JR	Z,.TO_CSI
	LD	A,O_NORMAL			; ESC <x>: drop the single byte
	LD	(OUT_STATE),A
	RET
.TO_CSI
	CALL	CSI_RESET
	LD	A,O_CSI
	LD	(OUT_STATE),A
	RET
; --- O_CSI: collect parameters, dispatch on the final byte ---
.IN_CSI
	LD	A,C
	CP	'?'
	JR	Z,.PRIV
	CP	'>'
	JR	Z,.PRIV
	CP	'='
	JR	Z,.PRIV
	CP	'<'
	JR	Z,.PRIV
	CP	'0'
	JR	C,.PUNCT
	CP	'9'+1
	JR	NC,.PUNCT
	JR	.DIGIT
.PUNCT
	CP	';'
	JR	Z,.SEP
	CP	0x40
	JR	C,.IGNORE_INT			; 0x20..0x3F intermediate -> ignore, stay
	CP	0x7F
	JR	NC,.CSI_END			; > 0x7E -> abort
	CALL	CSI_DISPATCH			; 0x40..0x7E final byte (C)
.CSI_END
	LD	A,O_NORMAL
	LD	(OUT_STATE),A
	RET
.PRIV
	LD	A,1
	LD	(CSI_PRIV),A
	RET
.IGNORE_INT
	RET
.SEP
	LD	A,1
	LD	(CSI_ANY),A
	LD	A,(CSI_IDX)
	CP	MAX_PARAMS-1
	RET	NC
	INC	A
	LD	(CSI_IDX),A
	RET
.DIGIT
	LD	A,1
	LD	(CSI_ANY),A
	LD	A,(CSI_IDX)
	LD	L,A
	LD	H,0
	LD	DE,CSI_PARAMS
	ADD	HL,DE				; HL -> params[idx]
	LD	A,C
	SUB	'0'
	LD	E,A				; E = new digit
	LD	A,(HL)				; D = old value, A *= 10
	LD	D,A
	ADD	A,A
	JR	C,.DCLAMP
	ADD	A,A
	JR	C,.DCLAMP
	ADD	A,D
	JR	C,.DCLAMP
	ADD	A,A
	JR	C,.DCLAMP
	ADD	A,E
	JR	C,.DCLAMP
	LD	(HL),A
	RET
.DCLAMP
	LD	(HL),255
	RET

; Reset the CSI parameter parser.
CSI_RESET
	XOR	A
	LD	(CSI_IDX),A
	LD	(CSI_PRIV),A
	LD	(CSI_ANY),A
	LD	HL,CSI_PARAMS
	LD	B,MAX_PARAMS
.Z	LD	(HL),0
	INC	HL
	DJNZ	.Z
	RET

; GET_PARAM: A = index -> A = CSI_PARAMS[index].
GET_PARAM
	LD	L,A
	LD	H,0
	LD	DE,CSI_PARAMS
	ADD	HL,DE
	LD	A,(HL)
	RET

; PARAM0_OR1: A = params[0], or 1 if it is 0 (default count).
PARAM0_OR1
	XOR	A
	CALL	GET_PARAM
	OR	A
	RET	NZ
	INC	A
	RET

; CSI_DISPATCH: act on final byte in C. Private (?,>,=,<) sequences are ignored.
CSI_DISPATCH
	LD	A,(CSI_PRIV)
	OR	A
	RET	NZ
	LD	A,C
	CP	'H'
	JP	Z,CUP
	CP	'f'
	JP	Z,CUP
	CP	'A'
	JP	Z,CUU
	CP	'B'
	JP	Z,CUD
	CP	'C'
	JP	Z,CUF
	CP	'D'
	JP	Z,CUB
	CP	'J'
	JP	Z,ED
	CP	'K'
	JP	Z,EL
	CP	'm'
	JP	Z,SGR
	CP	's'
	JP	Z,SCP
	CP	'u'
	JP	Z,RCP
	RET					; unhandled final byte

; --- Cursor movement ---
CUP						; ESC[r;cH / f
	XOR	A
	CALL	GET_PARAM			; row (1-based; 0 = default)
	OR	A
	JR	NZ,.R
	INC	A
.R	DEC	A
	LD	(CUR_ROW),A
	LD	A,1
	CALL	GET_PARAM			; col
	OR	A
	JR	NZ,.C
	INC	A
.C	DEC	A
	LD	(CUR_COL),A
	JP	CLAMP_CURSOR
CUU						; up
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_ROW)
	SUB	B
	JR	NC,.OK
	XOR	A
.OK	LD	(CUR_ROW),A
	RET
CUD						; down
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_ROW)
	ADD	A,B
	CP	TERM_ROWS
	JR	C,.OK
	LD	A,TERM_ROWS-1
.OK	LD	(CUR_ROW),A
	RET
CUF						; right
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_COL)
	ADD	A,B
	CP	TERM_COLS
	JR	C,.OK
	LD	A,TERM_COLS-1
.OK	LD	(CUR_COL),A
	RET
CUB						; left
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_COL)
	SUB	B
	JR	NC,.OK
	XOR	A
.OK	LD	(CUR_COL),A
	RET

CLAMP_CURSOR
	LD	A,(CUR_ROW)
	CP	TERM_ROWS
	JR	C,.ROW_OK
	LD	A,TERM_ROWS-1
	LD	(CUR_ROW),A
.ROW_OK
	LD	A,(CUR_COL)
	CP	TERM_COLS
	RET	C
	LD	A,TERM_COLS-1
	LD	(CUR_COL),A
	RET

SCP						; save cursor
	LD	A,(CUR_ROW)
	LD	(SAVED_ROW),A
	LD	A,(CUR_COL)
	LD	(SAVED_COL),A
	RET
RCP						; restore cursor
	LD	A,(SAVED_ROW)
	LD	(CUR_ROW),A
	LD	A,(SAVED_COL)
	LD	(CUR_COL),A
	RET

; --- Erase ---
ED						; ESC[nJ erase in display
	XOR	A
	CALL	GET_PARAM
	OR	A
	JR	Z,.FROM_CUR			; 0: cursor..end
	CP	1
	JR	Z,.TO_CUR			; 1: start..cursor
	CP	2
	RET	NZ
	; 2: clear whole terminal region and home (ANSI.SYS behaviour)
	LD	D,0
	LD	E,0
	LD	H,TERM_ROWS
	LD	L,TERM_COLS
	CALL	CLEAR_RECT
	XOR	A
	LD	(CUR_ROW),A
	LD	(CUR_COL),A
	RET
.FROM_CUR
	CALL	EL_FROM_CUR
	LD	A,(CUR_ROW)
	INC	A
	CP	TERM_ROWS
	RET	NC				; nothing below the cursor row
	LD	D,A
	LD	E,0
	LD	A,TERM_ROWS
	SUB	D
	LD	H,A
	LD	L,TERM_COLS
	JP	CLEAR_RECT
.TO_CUR
	LD	A,(CUR_ROW)
	OR	A
	JR	Z,.TC_LINE
	LD	D,0
	LD	E,0
	LD	H,A				; rows above
	LD	L,TERM_COLS
	CALL	CLEAR_RECT
.TC_LINE
	JP	EL_TO_CUR

EL						; ESC[nK erase in line
	XOR	A
	CALL	GET_PARAM
	OR	A
	JR	Z,EL_FROM_CUR
	CP	1
	JR	Z,EL_TO_CUR
	CP	2
	RET	NZ
	LD	A,(CUR_ROW)
	LD	D,A
	LD	E,0
	LD	H,1
	LD	L,TERM_COLS
	JP	CLEAR_RECT

EL_FROM_CUR					; current line: cursor..EOL
	LD	A,(CUR_ROW)
	LD	D,A
	LD	A,(CUR_COL)
	LD	E,A
	LD	H,1
	LD	A,TERM_COLS
	SUB	E
	LD	L,A
	JP	CLEAR_RECT
EL_TO_CUR					; current line: BOL..cursor
	LD	A,(CUR_ROW)
	LD	D,A
	LD	E,0
	LD	H,1
	LD	A,(CUR_COL)
	INC	A
	LD	L,A
	JP	CLEAR_RECT

; CLEAR_RECT: D=row E=col H=height L=width. Fills with spaces in CUR_ATTR.
CLEAR_RECT
	LD	A,H
	OR	A
	RET	Z
	LD	A,L
	OR	A
	RET	Z
	LD	A,(CUR_ATTR)
	LD	B,A
	LD	A,' '
	LD	C,DSS_CLEAR
	RST	DSS
	RET

; --- SGR colours ---
SGR
	LD	A,(CSI_ANY)
	OR	A
	JR	NZ,.HAVE
	XOR	A				; bare ESC[m == ESC[0m
	CALL	SGR_APPLY
	JP	RECALC_ATTR
.HAVE
	LD	B,0
.LOOP
	LD	A,B
	CALL	GET_PARAM
	CALL	SGR_APPLY
	LD	A,B
	LD	HL,CSI_IDX
	CP	(HL)
	JR	Z,.FIN
	INC	B
	JR	.LOOP
.FIN
	JP	RECALC_ATTR

; SGR_APPLY: fold one SGR code (A) into the FG/BG/BOLD/REV state.
SGR_APPLY
	OR	A
	JR	Z,.RESET
	CP	1
	JR	Z,.BOLD
	CP	2
	JR	Z,.NOBOLD
	CP	7
	JR	Z,.REV
	CP	22
	JR	Z,.NOBOLD
	CP	27
	JR	Z,.NOREV
	CP	39
	JR	Z,.DEFFG
	CP	49
	JR	Z,.DEFBG
	CP	30
	RET	C
	CP	38
	JR	C,.FG				; 30..37
	CP	40
	RET	C				; 38,39 handled/ignored
	CP	48
	JR	C,.BG				; 40..47
	CP	90
	RET	C
	CP	98
	JR	C,.FGBRT			; 90..97
	CP	100
	RET	C
	CP	108
	JR	C,.BGBRT			; 100..107
	RET
.RESET
	LD	A,7
	LD	(ATTR_FG),A
	XOR	A
	LD	(ATTR_BG),A
	LD	(ATTR_BOLD),A
	LD	(ATTR_REV),A
	RET
.BOLD
	LD	A,1
	LD	(ATTR_BOLD),A
	RET
.NOBOLD
	XOR	A
	LD	(ATTR_BOLD),A
	RET
.REV
	LD	A,1
	LD	(ATTR_REV),A
	RET
.NOREV
	XOR	A
	LD	(ATTR_REV),A
	RET
.DEFFG
	LD	A,7
	LD	(ATTR_FG),A
	RET
.DEFBG
	XOR	A
	LD	(ATTR_BG),A
	RET
.FG
	SUB	30
	CALL	ANSI2ZX
	LD	(ATTR_FG),A
	RET
.BG
	SUB	40
	CALL	ANSI2ZX
	LD	(ATTR_BG),A
	RET
.FGBRT
	SUB	90
	CALL	ANSI2ZX
	LD	(ATTR_FG),A
	LD	A,1
	LD	(ATTR_BOLD),A
	RET
.BGBRT
	SUB	100
	CALL	ANSI2ZX
	OR	8
	LD	(ATTR_BG),A
	RET

; ANSI2ZX: A = ANSI colour index 0..7 -> ZX palette index.
ANSI2ZX
	PUSH	HL
	LD	L,A
	LD	H,0
	LD	DE,ANSI2ZX_TAB
	ADD	HL,DE
	LD	A,(HL)
	POP	HL
	RET
ANSI2ZX_TAB
	DB	0,2,4,6,1,3,5,7			; blk,red,grn,yel,blu,mag,cyn,wht

; RECALC_ATTR: CUR_ATTR = (PAPER<<4)|INK from FG/BG/BOLD/REV.
RECALC_ATTR
	LD	A,(ATTR_FG)
	AND	0x07
	LD	B,A				; B = ink (fg)
	LD	A,(ATTR_BOLD)
	OR	A
	JR	Z,.NB
	LD	A,B
	OR	8
	LD	B,A				; bright ink
.NB
	LD	A,(ATTR_BG)
	AND	0x0F
	LD	C,A				; C = paper (bg)
	LD	A,(ATTR_REV)
	OR	A
	JR	Z,.NOREV2
	LD	A,B				; swap ink/paper
	LD	B,C
	LD	C,A
.NOREV2
	LD	A,C
	AND	0x0F
	RLCA
	RLCA
	RLCA
	RLCA					; paper -> high nibble
	LD	C,A
	LD	A,B
	AND	0x0F
	OR	C
	LD	(CUR_ATTR),A
	RET

; --- Character output ---
; TERM_CHAR: render a post-escape data byte (C). Printable bytes (incl. 0x80+
; box-drawing, which the CP866 font renders like CP437) are written at the
; cursor and advance it with auto-wrap; C0 controls move the cursor.
TERM_CHAR
	LD	A,C
	CP	0x20
	JR	C,.CTRL
	CALL	WRITE_GLYPH			; A = glyph
	LD	A,(CUR_COL)
	INC	A
	CP	TERM_COLS
	JR	C,.SETCOL
	XOR	A				; wrap to next line
	LD	(CUR_COL),A
	JP	TERM_LF
.SETCOL
	LD	(CUR_COL),A
	RET
.CTRL
	LD	A,C
	CP	CR
	JR	Z,.CR
	CP	LF
	JR	Z,TERM_LF
	CP	0x08
	JR	Z,.BS
	CP	0x09
	JR	Z,.TAB
	RET					; ignore BEL and other controls
.CR
	XOR	A
	LD	(CUR_COL),A
	RET
.BS
	LD	A,(CUR_COL)
	OR	A
	RET	Z
	DEC	A
	LD	(CUR_COL),A
	RET
.TAB
	LD	A,(CUR_COL)
	OR	7
	INC	A				; next multiple of 8
	CP	TERM_COLS
	JR	C,.TSET
	LD	A,TERM_COLS-1
.TSET
	LD	(CUR_COL),A
	RET

; TERM_LF: move the cursor down one line, scrolling the region if at the bottom.
TERM_LF
	LD	A,(CUR_ROW)
	INC	A
	CP	TERM_ROWS
	JR	C,.SET
	CALL	SCROLL_TERM
	LD	A,TERM_ROWS-1
.SET
	LD	(CUR_ROW),A
	RET

; WRITE_GLYPH: WrChar(A) at the cursor with CUR_ATTR (does not move the cursor).
WRITE_GLYPH
	PUSH	BC,DE,HL
	LD	C,A				; C = glyph
	LD	A,(CUR_ROW)
	LD	D,A
	LD	A,(CUR_COL)
	LD	E,A
	LD	A,(CUR_ATTR)
	LD	B,A
	LD	A,C
	LD	C,DSS_WRCHAR
	RST	DSS
	POP	HL,DE,BC
	RET

; SCROLL_TERM: scroll rows 0..TERM_ROWS-1 up by one and clear the new bottom
; row in the current attribute (so the scrolled-in line uses the right paper).
SCROLL_TERM
	PUSH	BC,DE,HL
	LD	D,0
	LD	E,0
	LD	H,TERM_ROWS
	LD	L,TERM_COLS
	LD	B,1				; scroll up
	XOR	A
	LD	C,DSS_SCROLL
	RST	DSS
	LD	D,TERM_ROWS-1
	LD	E,0
	LD	H,1
	LD	L,TERM_COLS
	CALL	CLEAR_RECT
	POP	HL,DE,BC
	RET

; SYNC_CURSOR: position the hardware text cursor at CUR_ROW/CUR_COL.
SYNC_CURSOR
	PUSH	BC,DE,HL
	LD	A,(CUR_ROW)
	LD	D,A
	LD	A,(CUR_COL)
	LD	E,A
	LD	C,DSS_LOCATE
	RST	DSS
	POP	HL,DE,BC
	RET

; INIT_SCREEN: reset attributes/cursor and clear the terminal region.
INIT_SCREEN
	XOR	A
	LD	(CUR_ROW),A
	LD	(CUR_COL),A
	LD	(ATTR_BOLD),A
	LD	(ATTR_REV),A
	LD	(ATTR_BG),A
	LD	A,7
	LD	(ATTR_FG),A
	CALL	RECALC_ATTR
	LD	D,0
	LD	E,0
	LD	H,TERM_ROWS
	LD	L,TERM_COLS
	JP	CLEAR_RECT

; DRAW_STATUS: paint the bottom status row (host:port + key hints).
DRAW_STATUS
	LD	D,STATUS_ROW
	LD	E,0
	LD	H,1
	LD	L,TERM_COLS
	LD	A,' '
	LD	B,STATUS_ATTR
	LD	C,DSS_CLEAR
	RST	DSS
	LD	D,STATUS_ROW
	LD	E,1
	LD	HL,HOST_BUFF
	CALL	PUTS_STATUS
	LD	A,':'
	CALL	PUTC_STATUS
	LD	HL,PORT_BUFF
	CALL	PUTS_STATUS
	LD	HL,MSG_STAT_HINT
	JP	PUTS_STATUS

; PUTS_STATUS: write ASCIIZ at HL onto the status row. In: D=row, E=col; E advances.
PUTS_STATUS
	LD	A,(HL)
	OR	A
	RET	Z
	CALL	PUTC_STATUS
	INC	HL
	JR	PUTS_STATUS
; PUTC_STATUS: write char A at (D,E) in STATUS_ATTR, then E++ (clipped at edge).
PUTC_STATUS
	PUSH	BC,HL
	LD	C,A				; C = char
	LD	A,E
	CP	TERM_COLS
	JR	NC,.DONE			; past the right edge: skip the write
	LD	A,C
	LD	B,STATUS_ATTR
	PUSH	DE
	LD	C,DSS_WRCHAR
	RST	DSS
	POP	DE
.DONE
	INC	E
	POP	HL,BC
	RET

; ------------------------------------------------------
; CONNECT_TCP: open the TCP link, retrying while the ESP is still "busy"
; bringing the IP stack up right after NETUP. Out: CF/A as TCP.OPEN.
; ------------------------------------------------------
CONNECT_TCP
	LD	A,OPEN_RETRIES
	LD	(OPEN_LEFT),A
.TRY
	LD	HL,HOST_BUFF
	LD	DE,PORT_BUFF
	CALL	TCP.OPEN
	RET	NC
	LD	(TCP_LAST_STATUS),A
	LD	A,(OPEN_LEFT)
	DEC	A
	LD	(OPEN_LEFT),A
	JR	Z,.FAIL
	LD	HL,OPEN_RETRY_DELAY
	CALL	UTIL.DELAY
	JR	.TRY
.FAIL
	LD	A,(TCP_LAST_STATUS)
	SCF
	RET

; ------------------------------------------------------
; Send command in HL with the default timeout, exit on error.
; ------------------------------------------------------
SEND_CMD
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN	MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL, reset the ESP once if it does not answer.
; ------------------------------------------------------
SEND_CMD_RECOVER
	PUSH	HL
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	JR	Z,.OK
	PRINTLN	MSG_RESETTING_ESP
	CALL	WIFI.ESP_RESET
	CALL	WIFI.UART_SET_DEFAULT_DIVISOR
	CALL	WIFI.UART_INIT
	POP	HL
	JP	SEND_CMD
.OK
	POP	HL
	RET

; ------------------------------------------------------
; Command line: TELNET.EXE host [port]   (default port 23)
; ------------------------------------------------------
INIT_DEFAULT_ARGS
	XOR	A
	LD	(HOST_BUFF),A			; empty host -> usage error if missing
	LD	HL,DEFAULT_PORT
	LD	DE,PORT_BUFF
	JP	COPY_ASCIIZ_DE

PARSE_CMD_LINE
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	AND	A
	JP	Z,.ERR				; host is required
	LD	B,A
	INC	HL
	CALL	SKIP_SPACES
	JR	NC,.HOST
	JR	.ERR
.HOST
	LD	DE,HOST_BUFF
	LD	C,HOST_SIZE-1
	CALL	COPY_ARG
	JR	C,.ERR
	CALL	SKIP_SPACES
	JR	NC,.PORT
	AND	A			; clear CF: host-only is valid -> keep default port
	RET
.PORT
	LD	DE,PORT_BUFF
	LD	C,PORT_SIZE-1
	CALL	COPY_ARG
	JR	C,.ERR
	CALL	VALIDATE_PORT
	JR	C,.ERR
	AND	A
	RET
.ERR
	SCF
	RET

SKIP_SPACES
	LD	A,B
	AND	A
	JR	Z,.ERR
	LD	A,(HL)
	CP	0x21
	RET	NC
	INC	HL
	DJNZ	SKIP_SPACES
.ERR
	SCF
	RET

COPY_ARG
	XOR	A
	LD	(ARG_LEN),A
.NEXT
	LD	A,B
	AND	A
	JR	Z,.END
	LD	A,(HL)
	CP	0x21
	JR	C,.END
	LD	A,C
	AND	A
	JR	Z,.ERR
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	DEC	C
	LD	A,(ARG_LEN)
	INC	A
	LD	(ARG_LEN),A
	JR	.NEXT
.END
	XOR	A
	LD	(DE),A
	LD	A,(ARG_LEN)
	AND	A
	RET	NZ
.ERR
	SCF
	RET

VALIDATE_PORT
	LD	HL,PORT_BUFF
.NEXT
	LD	A,(HL)
	AND	A
	RET	Z
	CP	'0'
	JR	C,.ERR
	CP	'9'+1
	JR	NC,.ERR
	INC	HL
	JR	.NEXT
.ERR
	SCF
	RET

COPY_ASCIIZ_DE
	LD	A,(HL)
	LD	(DE),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	COPY_ASCIIZ_DE

; ------------------------------------------------------
; Messages and constants
; ------------------------------------------------------
MSG_START
	DB "TELNET "
	PACKAGE_VERSION_TAG
	DB " - ESP-AT telnet client"
	DB 0
MSG_USAGE
	DB "Usage: TELNET.EXE host [port]   (default port 23)",13,10
	DB "  Alt+X to quit (Esc and other keys go to the BBS).",0
MSG_TARGET
	DB "Target ",0
MSG_COLON
	DB ":",0
MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found!",0
MSG_RESETTING_ESP
	DB "ESP did not answer, resetting module.",0
MSG_CONNECTING
	DB "Connecting to ",0
MSG_CONNECTED
	DB "Connected. Alt+X to quit.",13,10,0
MSG_CLOSED
	DB "Remote host closed the connection.",0
MSG_NO_CONNECT
	DB "Could not connect to ",0
MSG_NO_CONNECT_HINT
	DB "Host may be down, refusing the port, or the name did not",13,10
	DB "resolve (DNS). Check the address/port and your connection.",0
MSG_DONE
	DB "TELNET done.",0
MSG_STAT_HINT
	DB "   Alt+X quit   Esc->BBS",0
MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_CIPMUX_0
	DB "AT+CIPMUX=0",13,10,0
DEFAULT_PORT
	DB "23",0

; ------------------------------------------------------
; Small initialised state (kept in the EXE image; tiny).
; ------------------------------------------------------
ARG_LEN		DB 0
CMDLINE_PTR	DW 0			; arg buffer ptr captured from IX at entry
TCP_LAST_STATUS	DB 0			; last TCP result code (RES_NOT_CONN etc.)
OPEN_LEFT	DB 0
TN_STATE	DB 0
TN_CMD		DB 0
SB_IDX		DB 0			; bytes captured so far in the current subnegotiation
SB_OPT		DB 0			; SB option byte (SB_OPT, SB_SUB must stay consecutive)
SB_SUB		DB 0			; SB subcommand byte
OUT_STATE	DB 0
NEG_LEN		DB 0
TX_BUF		DB 0,0
NEG_BUF		DS NEG_BUF_SIZE,0

; --- ANSI emulator state ---
CUR_ROW		DB 0			; cursor row 0..TERM_ROWS-1
CUR_COL		DB 0			; cursor col 0..TERM_COLS-1
CUR_ATTR	DB DEF_ATTR		; current attribute byte (PAPER<<4 | INK)
SAVED_ROW	DB 0			; ESC[s / ESC[u
SAVED_COL	DB 0
ATTR_FG		DB 7			; base ink 0..7
ATTR_BG		DB 0			; paper 0..15
ATTR_BOLD	DB 0			; SGR 1 -> bright ink
ATTR_REV	DB 0			; SGR 7 -> swap ink/paper
CSI_IDX		DB 0			; index of the current/last CSI parameter
CSI_PRIV	DB 0			; non-zero if a private (?,>,=,<) CSI
CSI_ANY		DB 0			; non-zero if any digit/';' was seen
CSI_PARAMS	DS MAX_PARAMS,0		; parsed CSI parameters

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esp_tcp.asm"
	INCLUDE "esplib.asm"

	MODULE MAIN

; App receive buffer above the (overlapping) NETCFG/TCP BSS chains.
HOST_BUFF	EQU NETCFG.NETCFG_BSS_END
PORT_BUFF	EQU HOST_BUFF + HOST_SIZE
RECV_BUFFER	EQU PORT_BUFF + PORT_SIZE
TELNET_BSS_END	EQU RECV_BUFFER + RECV_BUFFER_SIZE

	ENDMODULE

	END MAIN.START

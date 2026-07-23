; ======================================================
; UNETTEST - backend-neutral smoke test for the UNET network DLL.
;
;   UNETTEST [-d FILE.DLL] HOST [PORT]
;
; Loads a UNET DLL (default UNETESP.DLL) via libman into window 1, then walks
; the API: l_info, GETCAPS, SETOPT, STATUS, NETINIT, GETINFO, RESOLVE, PING,
; CONNECT, SEND (HTTP HEAD), a short RECV loop, CLOSE, NETDONE, l_free.
; Because the whole exercise goes through the DLL, the SAME binary tests any
; backend - point -d at UNETRTL.DLL to exercise the RTL card.
;
; This is a diagnostic tool (excluded from the ZIP package). It lives at
; ORG 0x8100 (window 2) so the DLL can own window 1; the stack and all buffers
; stay in window 2, below 0xC000 and outside the DLL's window.
;
; Exit codes: 0 ok, 1 usage, 2 hardware not found, 3 comm/protocol error,
;             4 network not configured.
; ======================================================

EXE_VERSION	EQU 1

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"
	INCLUDE "unet.inc"

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080			; code file offset
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START			; load address
	DW START			; entry point
	DW STACK_TOP			; initial stack
	DS 106, 0

	ORG 0x8100

START
	; DSS passes the command-line buffer pointer in IX at entry.
	LD	(CMDLINE_PTR),IX
	LD	SP,STACK_TOP

	LD	HL,MSG_BANNER
	CALL	PUTS_LN

	CALL	PARSE_ARGS

	; --- load the DLL into window 1 ---
	LD	HL,MSG_LOADING
	CALL	PUTS
	LD	HL,DLL_NAME
	CALL	PUTS_LN

	LD	HL,DLL_NAME
	LD	A,1				; window 1
	CALL	LIBMAN.l_load
	JP	C,ERR_LOAD
	LD	(HANDLE),HL

	; --- l_info: print name + version ---
	LD	HL,(HANDLE)
	LD	DE,INFO_BUF
	CALL	LIBMAN.l_info
	JP	C,ERR_LOAD
	LD	HL,MSG_DLL
	CALL	PUTS
	LD	HL,INFO_BUF + 16		; header name field
	CALL	PUTS
	LD	HL,MSG_VER
	CALL	PUTS
	LD	A,(INFO_BUF + 15)		; version high (major)
	CALL	PUT_DEC_A
	LD	A,'.'
	CALL	PUT_CHAR
	LD	A,(INFO_BUF + 14)		; version low (minor)
	CALL	PUT_DEC_A
	CALL	CRLF

	; --- GETCAPS ---
	LD	B,UNET_FN_GETCAPS
	CALL	DO_CALL				; -> DE=caps, IX=abi
	LD	(CAPS),DE
	LD	HL,MSG_CAPS
	CALL	PUTS
	LD	DE,(CAPS)
	CALL	PUT_HEX16
	CALL	CRLF

	; --- SETOPT CANCELKEYS=1 (allow Esc/Ctrl+Z to abort blocking calls) ---
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,1
	LD	B,UNET_FN_SETOPT
	CALL	DO_CALL

	; --- STATUS 0xFF: network state without touching hardware ---
	LD	A,0xFF
	LD	B,UNET_FN_STATUS
	CALL	DO_CALL				; -> A, DE=bits
	LD	HL,MSG_NETSTAT
	CALL	PUTS				; preserves DE (the status bits)
	CALL	PRINT_STATUS_BITS
	CALL	CRLF

	; --- NETINIT ---
	LD	B,UNET_FN_NETINIT
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_NETINIT
	LD	HL,MSG_NETUP
	CALL	PUTS_LN

	; --- GETINFO: station IP ---
	LD	A,UNET_IF_IP
	LD	DE,STR_BUF
	LD	IX,STR_BUF_SIZE
	LD	B,UNET_FN_GETINFO
	CALL	DO_CALL
	LD	HL,MSG_IP
	CALL	PUTS
	LD	HL,STR_BUF
	CALL	PUTS_LN

	; --- RESOLVE host (optional; degrades to unsupported) ---
	LD	HL,MSG_RESOLVE
	CALL	PUTS
	LD	DE,HOST_BUFF
	LD	IX,STR_BUF
	LD	B,UNET_FN_RESOLVE
	CALL	DO_CALL
	CP	NERR_OK
	JR	NZ,.res_bad
	LD	HL,STR_BUF
	CALL	PUTS_LN
	JR	.after_resolve
.res_bad
	CP	NERR_NOTSUP
	JR	NZ,.res_err
	LD	HL,MSG_UNSUP
	CALL	PUTS_LN
	JR	.after_resolve
.res_err
	LD	HL,MSG_FAILED
	CALL	PUTS_LN
.after_resolve

	; --- PING host ---
	LD	HL,MSG_PING
	CALL	PUTS
	LD	DE,HOST_BUFF
	LD	IY,3000
	LD	B,UNET_FN_PING
	CALL	DO_CALL				; -> A, DE=ms
	OR	A
	JR	NZ,.ping_bad
	LD	(TMP16),DE
	LD	DE,(TMP16)
	PUSH	DE
	POP	HL
	CALL	PUT_DEC_HL
	LD	HL,MSG_MS
	CALL	PUTS_LN
	JR	.after_ping
.ping_bad
	LD	HL,MSG_FAILED
	CALL	PUTS_LN
.after_ping

	; --- CONNECT host:port ---
	LD	HL,MSG_CONNECT
	CALL	PUTS
	LD	HL,HOST_BUFF
	CALL	PUTS
	LD	A,':'
	CALL	PUT_CHAR
	LD	HL,PORT_BUFF
	CALL	PUTS_LN
	XOR	A				; channel 0
	LD	DE,HOST_BUFF
	LD	IX,PORT_BUFF
	LD	B,UNET_FN_CONNECT
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_CONNECT

	; --- SEND an HTTP HEAD request ---
	CALL	BUILD_REQUEST			; -> REQ_BUF, BC=length
	LD	(REQ_LEN),BC
	XOR	A				; channel 0
	LD	DE,REQ_BUF
	LD	IX,(REQ_LEN)
	LD	B,UNET_FN_SEND
	CALL	DO_CALL				; -> A, DE=sent
	OR	A
	JP	NZ,ERR_SEND
	LD	HL,MSG_SENT
	CALL	PUTS_LN

	; --- RECV loop (up to RECV_MAX_BLOCKS blocks) ---
	LD	A,RECV_MAX_BLOCKS
	LD	(RECV_LEFT),A
	LD	HL,MSG_REPLY
	CALL	PUTS_LN
.recv_loop
	LD	A,(RECV_LEFT)
	AND	A
	JR	Z,.recv_done
	DEC	A
	LD	(RECV_LEFT),A
	XOR	A				; channel 0
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE - 1
	LD	IY,4000
	LD	B,UNET_FN_RECV
	CALL	DO_CALL				; -> A, DE=got
	CP	NERR_OK
	JR	Z,.recv_ok
	CP	NERR_CLOSED
	JR	Z,.recv_closed_data
	; error
	LD	HL,MSG_RECV_ERR
	CALL	PUTS_LN
	JR	.recv_done
.recv_ok
	LD	A,D
	OR	E
	JR	Z,.recv_loop			; timeout, nothing this round
	CALL	PRINT_RECV
	JR	.recv_loop
.recv_closed_data
	LD	A,D
	OR	E
	JR	Z,.recv_closed
	CALL	PRINT_RECV
.recv_closed
	LD	HL,MSG_CLOSED
	CALL	PUTS_LN
.recv_done

	; --- CLOSE / NETDONE / free ---
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	B,UNET_FN_NETDONE
	CALL	DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_free

	LD	HL,MSG_DONE
	CALL	PUTS_LN
	LD	B,0
	JP	EXIT

; ======================================================
; Error exits
; ======================================================
ERR_LOAD
	LD	HL,MSG_ERR_LOAD
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT
ERR_NETINIT
	; map A (NERR_*) to an exit code and message
	CP	NERR_NONET
	JR	Z,.cfg
	CP	NERR_HW
	JR	Z,.hw
	LD	HL,MSG_ERR_NETINIT
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	LD	B,3
	JP	EXIT
.cfg
	LD	HL,MSG_ERR_NONET
	CALL	PUTS_LN
	LD	B,4
	JP	EXIT
.hw
	LD	HL,MSG_ERR_HW
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT
ERR_CONNECT
	LD	HL,MSG_ERR_CONNECT
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT
ERR_SEND
	LD	HL,MSG_ERR_SEND
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT

USAGE_EXIT
	LD	HL,MSG_USAGE
	CALL	PUTS_LN
	LD	B,1
	JP	EXIT

; Best-effort close + free after a mid-session error.
FREE_AND_DONE
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_free
	RET

; Print LASTERR tail for diagnostics.
DUMP_LASTERR
	LD	HL,MSG_LASTERR
	CALL	PUTS
	LD	DE,STR_BUF
	LD	IX,STR_BUF_SIZE
	LD	B,UNET_FN_LASTERR
	CALL	DO_CALL
	LD	HL,STR_BUF
	CALL	PUTS_LN
	RET

EXIT
	LD	C,DSS_EXIT
	RST	DSS

; ======================================================
; libman call helper: args already in A/DE/IX/IY, B = function number.
; ======================================================
DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_call
	RET

; ======================================================
; Build "HEAD / HTTP/1.0\r\nHost: <host>\r\nConnection: close\r\n\r\n"
; into REQ_BUF. Out: BC = length (no terminator sent).
; ======================================================
BUILD_REQUEST
	LD	HL,REQ_BUF
	LD	DE,REQ_HEAD
	CALL	APPEND
	LD	DE,HOST_BUFF
	CALL	APPEND
	LD	DE,REQ_TAIL
	CALL	APPEND
	; length = HL - REQ_BUF
	LD	DE,REQ_BUF
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	RET

; Append ASCIIZ (DE) to buffer (HL). Out: HL at terminator.
APPEND
	LD	A,(DE)
	AND	A
	RET	Z
	LD	(HL),A
	INC	HL
	INC	DE
	JR	APPEND

; ======================================================
; Command-line parsing:  [-d FILE.DLL] HOST [PORT]
; ======================================================
PARSE_ARGS
	; defaults
	LD	HL,DEF_DLL
	LD	DE,DLL_NAME
	CALL	STRCPY
	LD	HL,DEF_HOST
	LD	DE,HOST_BUFF
	CALL	STRCPY
	LD	HL,DEF_PORT
	LD	DE,PORT_BUFF
	CALL	STRCPY
	; init parse state
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	LD	(PARSE_LEFT),A
	INC	HL
	LD	(PARSE_PTR),HL
	; first token
	LD	DE,TOKEN_BUF
	LD	C,TOKEN_BUF_SIZE
	CALL	NEXT_TOKEN
	RET	C				; no args -> defaults
	; "-d" ?
	LD	HL,TOKEN_BUF
	LD	DE,STR_DASH_D
	CALL	STREQ
	JR	NZ,.host_is_tok
	; DLL name = next token
	LD	DE,DLL_NAME
	LD	C,DLL_NAME_SIZE
	CALL	NEXT_TOKEN
	JP	C,USAGE_EXIT			; -d without a file name
	; host = next token
	LD	DE,HOST_BUFF
	LD	C,HOST_BUFF_SIZE
	CALL	NEXT_TOKEN
	RET	C
	JR	.maybe_port
.host_is_tok
	LD	A,(TOKEN_BUF)
	CP	'-'
	JP	Z,USAGE_EXIT			; unknown flag
	LD	HL,TOKEN_BUF
	LD	DE,HOST_BUFF
	CALL	STRCPY
.maybe_port
	LD	DE,PORT_BUFF
	LD	C,PORT_BUFF_SIZE
	CALL	NEXT_TOKEN			; optional; ignore CF
	RET

; Copy next whitespace-delimited token from the parse state to (DE),
; truncated to C-1 chars (C = destination size incl NUL).
; Out: CF=1 if no token remains.
NEXT_TOKEN
	PUSH	DE
	DEC	C				; capacity without the NUL
.skip
	LD	A,(PARSE_LEFT)
	AND	A
	JR	Z,.none
	LD	HL,(PARSE_PTR)
	LD	A,(HL)
	CP	0x21
	JR	NC,.start
	CALL	.advance
	JR	.skip
.start
	POP	DE
	PUSH	DE
.copy
	LD	A,(PARSE_LEFT)
	AND	A
	JR	Z,.end
	LD	HL,(PARSE_PTR)
	LD	A,(HL)
	CP	0x21
	JR	C,.end
	INC	C
	DEC	C				; capacity left?
	JR	Z,.nostore			; truncate: keep consuming the token
	LD	(DE),A
	INC	DE
	DEC	C
.nostore
	CALL	.advance
	JR	.copy
.end
	XOR	A
	LD	(DE),A
	POP	DE
	AND	A				; CF=0
	RET
.none
	POP	DE
	SCF
	RET
.advance
	LD	HL,(PARSE_PTR)
	INC	HL
	LD	(PARSE_PTR),HL
	LD	A,(PARSE_LEFT)
	DEC	A
	LD	(PARSE_LEFT),A
	RET

; ======================================================
; Small string / print helpers
; ======================================================
STRCPY
	LD	A,(HL)
	LD	(DE),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	STRCPY

; Compare ASCIIZ (HL) and (DE). Out: ZF=1 if equal.
STREQ
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	CP	C
	RET	NZ
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	STREQ

; Print ASCIIZ (HL).
PUTS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	RET

; Print ASCIIZ (HL) + CRLF.
PUTS_LN
	CALL	PUTS
CRLF
	LD	HL,MSG_CRLF
	JR	PUTS

; Print one char (A).
PUT_CHAR
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	RET

; Print DE as 4 hex digits.
PUT_HEX16
	LD	A,D
	CALL	PUT_HEX8
	LD	A,E
PUT_HEX8
	PUSH	AF
	RRA
	RRA
	RRA
	RRA
	CALL	PUT_NIB
	POP	AF
PUT_NIB
	AND	0x0F
	ADD	A,0x90
	DAA
	ADC	A,0x40
	DAA
	JP	PUT_CHAR

; Print A as unsigned decimal (0..255).
PUT_DEC_A
	LD	L,A
	LD	H,0
	; fall through
; Print HL as unsigned decimal.
PUT_DEC_HL
	LD	DE,DEC_BUF + 6
	XOR	A
	LD	(DE),A
.next
	DEC	DE
	CALL	DIV10_HL
	ADD	A,'0'
	LD	(DE),A
	LD	A,H
	OR	L
	JR	NZ,.next
	EX	DE,HL
	JP	PUTS

; HL /= 10, remainder in A.
DIV10_HL
	PUSH	BC
	LD	BC,0x0D0A
	XOR	A
	ADD	HL,HL
	RLA
	ADD	HL,HL
	RLA
	ADD	HL,HL
	RLA
.dl1
	ADD	HL,HL
	RLA
	CP	C
	JR	C,.dl2
	SUB	C
	INC	L
.dl2
	DJNZ	.dl1
	POP	BC
	RET

; Print "cfg=<0/1> init=<0/1>" from status bits in DE.
PRINT_STATUS_BITS
	PUSH	DE
	LD	HL,MSG_CFG
	CALL	PUTS
	POP	DE
	PUSH	DE
	LD	A,E
	AND	1
	CALL	PUT_BIT
	LD	HL,MSG_INIT
	CALL	PUTS
	POP	DE
	LD	A,E
	AND	2
	JR	Z,.zero
	LD	A,1
.zero
	JP	PUT_BIT

PUT_BIT
	ADD	A,'0'
	JP	PUT_CHAR

; Print RECV_BUF as text, DE = byte count. NUL-terminate then print.
PRINT_RECV
	LD	H,D
	LD	L,E
	LD	DE,RECV_BUF
	ADD	HL,DE				; HL = RECV_BUF + count
	LD	(HL),0				; terminate
	LD	HL,RECV_BUF
	JP	PUTS

; ======================================================
; Strings
; ======================================================
MSG_BANNER	DB "UNETTEST - universal network DLL smoke test",0
MSG_USAGE	DB "Usage: UNETTEST [-d FILE.DLL] [HOST [PORT]]",0
MSG_LOADING	DB "Loading ",0
MSG_DLL		DB "DLL: ",0
MSG_VER		DB "  v",0
MSG_CAPS	DB "caps=0x",0
MSG_NETSTAT	DB "net: ",0
MSG_CFG		DB "cfg=",0
MSG_INIT	DB " init=",0
MSG_NETUP	DB "NETINIT ok",0
MSG_IP		DB "IP: ",0
MSG_RESOLVE	DB "resolve: ",0
MSG_UNSUP	DB "unsupported (emulator/firmware gap)",0
MSG_PING	DB "ping: ",0
MSG_MS		DB " ms",0
MSG_CONNECT	DB "connect ",0
MSG_SENT	DB "request sent",0
MSG_REPLY	DB "--- reply ---",0
MSG_CLOSED	DB "--- closed ---",0
MSG_DONE	DB "done.",0
MSG_FAILED	DB "failed",0
MSG_RECV_ERR	DB "receive error",0
MSG_LASTERR	DB "lasterr: ",0
MSG_ERR_LOAD	DB "Cannot load DLL (check name/window).",0
MSG_ERR_NETINIT	DB "NETINIT failed.",0
MSG_ERR_NONET	DB "Network not configured - run NETUP first.",0
MSG_ERR_HW	DB "Network hardware not found.",0
MSG_ERR_CONNECT	DB "Connect failed.",0
MSG_ERR_SEND	DB "Send failed.",0
MSG_CRLF	DB 13,10,0

DEF_DLL		DB "UNETESP.DLL",0
DEF_HOST	DB "example.com",0
DEF_PORT	DB "80",0
STR_DASH_D	DB "-d",0

REQ_HEAD	DB "HEAD / HTTP/1.0",13,10,"Host: ",0
REQ_TAIL	DB 13,10,"Connection: close",13,10,13,10,0

	ENDMODULE

; ======================================================
; Embedded libman 1.3 loader
; ======================================================
	INCLUDE "libman13.asm"

; ======================================================
; BSS (runtime buffers) - placed after all code, inside window 2.
; ======================================================
	MODULE MAIN

RECV_BUF_SIZE	EQU 512
STR_BUF_SIZE	EQU 96
REQ_BUF_SIZE	EQU 160
TOKEN_BUF_SIZE	EQU 64
DLL_NAME_SIZE	EQU 24
HOST_BUFF_SIZE	EQU 64
PORT_BUFF_SIZE	EQU 16

BSS_BASE	EQU $
HANDLE		EQU BSS_BASE
CAPS		EQU HANDLE + 2
TMP16		EQU CAPS + 2
REQ_LEN		EQU TMP16 + 2
RECV_LEFT	EQU REQ_LEN + 2
CMDLINE_PTR	EQU RECV_LEFT + 1
PARSE_PTR	EQU CMDLINE_PTR + 2
PARSE_LEFT	EQU PARSE_PTR + 2
DEC_BUF		EQU PARSE_LEFT + 1
INFO_BUF	EQU DEC_BUF + 8
DLL_NAME	EQU INFO_BUF + 32
HOST_BUFF	EQU DLL_NAME + DLL_NAME_SIZE
PORT_BUFF	EQU HOST_BUFF + HOST_BUFF_SIZE
TOKEN_BUF	EQU PORT_BUFF + PORT_BUFF_SIZE
STR_BUF		EQU TOKEN_BUF + TOKEN_BUF_SIZE
REQ_BUF		EQU STR_BUF + STR_BUF_SIZE
RECV_BUF	EQU REQ_BUF + REQ_BUF_SIZE
BSS_END		EQU RECV_BUF + RECV_BUF_SIZE

STACK_BOTTOM	EQU BSS_END
STACK_TOP	EQU STACK_BOTTOM + 0x600

RECV_MAX_BLOCKS	EQU 4

	ASSERT STACK_TOP <= 0xC000

	ENDMODULE

	END MAIN.START

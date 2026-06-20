; ======================================================
; PING for Sprinter DSS Network Kit
; Host reachability diagnostic using ESP-AT AT+PING.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
PING_TIMEOUT		EQU 8000
PING_BUSY_RETRIES	EQU 8			; AT+PING retries while the ESP answers "busy"
PING_BUSY_DELAY		EQU 400			; ms between busy retries
PING_WARMUP_RETRIES	EQU 3			; AT+PING retries while the route is still warming up ("+timeout")
PING_WARMUP_DELAY	EQU 600			; ms between warmup retries
HOST_SIZE		EQU 96
CMD_SIZE		EQU 128

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
	PRINTLN MSG_START

	CALL	PARSE_HOST
	JP	C,USAGE

	CALL	WIFI.UART_FIND
	JP	C,NO_WIFI
	CALL	WCOMMON.REQUIRE_NET_UP

	CALL	NETCFG.LOAD
	CALL	NETCFG.APPLY_UART_BAUD
	CALL	WIFI.UART_INIT
	PRINTLN MSG_UART_READY

	LD	HL,CMD_AT
	CALL	SEND_CMD_RECOVER

	LD	HL,CMD_ECHO_OFF
	CALL	SEND_CMD

	PRINT MSG_PINGING
	PRINT HOST_BUFF
	PRINT WCOMMON.LINE_END

	CALL	BUILD_PING_CMD
	; Right after NETUP's join the ESP IP stack may still be coming up, so it
	; answers a network command (AT+PING) with "busy p..." (which reads as a
	; timeout) even though plain AT works. Retry on busy for a short while; a
	; manual run works only because the human pause already covers this window.
	LD	A,PING_BUSY_RETRIES
	LD	(PING_RETRY),A
	LD	A,PING_WARMUP_RETRIES
	LD	(PING_WRETRY),A
.PING_TRY
	LD	HL,CMD_BUFF
	LD	DE,WIFI.RS_BUFF
	LD	BC,PING_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	JP	Z,.PING_OK
	LD	(PING_STATUS),A
	; "busy p..." -> the ESP IP stack is still coming up; quick retry.
	LD	HL,LIT_BUSY
	CALL	RESP_CONTAINS			; CF=1 if ESP replied "busy"
	JR	NC,.CHK_WARMUP
	LD	A,(PING_RETRY)
	OR	A
	JR	Z,.PING_NZ			; out of busy retries -> report
	DEC	A
	LD	(PING_RETRY),A
	LD	HL,PING_BUSY_DELAY
	CALL	UTIL.DELAY
	JR	.PING_TRY
.CHK_WARMUP
	; Right after NETUP the route/ARP may not be ready yet, so the first pings
	; come back "+timeout" (or no reply at all). Retry a few times before
	; declaring the host unreachable - a manual run avoids this via the human
	; pause. A genuinely down host still fails once the retries are spent.
	CALL	RESP_IS_PING_TIMEOUT		; CF=1 if "+timeout" or silent timeout
	JR	NC,.PING_NZ
	LD	A,(PING_WRETRY)
	OR	A
	JR	Z,.PING_NZ			; out of warmup retries -> report
	DEC	A
	LD	(PING_WRETRY),A
	LD	HL,PING_WARMUP_DELAY
	CALL	UTIL.DELAY
	JR	.PING_TRY
.PING_NZ
	LD	A,(PING_STATUS)
	CALL	PRINT_PING_RESULT
	JR	NC,.SUCCESS

	; A genuine ping timeout (host unreachable) is not the same as an ESP that
	; does not support AT+PING - report it accordingly.
	CALL	RESP_IS_PING_TIMEOUT
	JR	C,.TIMED_OUT
	LD	A,(PING_STATUS)
	CP	RES_ERROR
	JR	Z,.UNSUPPORTED
	CP	RES_FAIL
	JR	Z,.UNSUPPORTED
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

.TIMED_OUT
	PRINTLN MSG_PING_TIMEOUT
	LD	B,3
	JP	WCOMMON.EXIT

.UNSUPPORTED
	PRINTLN MSG_PING_UNSUPPORTED
	LD	B,3
	JP	WCOMMON.EXIT

.PING_OK
	CALL	PRINT_PING_RESULT
	JR	NC,.SUCCESS
	LD	B,3
	JP	WCOMMON.EXIT

.SUCCESS
	PRINTLN MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

USAGE
	PRINTLN MSG_USAGE
	LD	B,1
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Parse first command-line argument into HOST_BUFF.
; Out: CF=0 - host parsed, CF=1 - missing/invalid argument.
; ------------------------------------------------------
PARSE_HOST
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	AND	A
	JR	Z,.NO_ARG
	LD	B,A
	INC	HL
.SKIP
	LD	A,B
	AND	A
	JR	Z,.NO_ARG
	LD	A,(HL)
	CP	0x21
	JR	NC,.START_COPY
	INC	HL
	DJNZ	.SKIP
	JR	.NO_ARG

.START_COPY
	LD	DE,HOST_BUFF
	LD	C,HOST_SIZE-1
.COPY
	LD	A,B
	AND	A
	JR	Z,.END
	LD	A,(HL)
	CP	0x21
	JR	C,.END
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	DEC	C
	JR	NZ,.COPY
.END
	XOR	A
	LD	(DE),A
	LD	A,(HOST_BUFF)
	AND	A
	JR	Z,.NO_ARG
	AND	A
	RET
.NO_ARG
	SCF
	RET

; ------------------------------------------------------
; Send command in HL with default timeout.
; ------------------------------------------------------
SEND_CMD
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL. Reset ESP once if it does not answer.
; ------------------------------------------------------
SEND_CMD_RECOVER
	PUSH	HL
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	JR	Z,.OK

	PRINTLN MSG_RESETTING_ESP
	CALL	WIFI.ESP_RESET
	CALL	WIFI.UART_SET_DEFAULT_DIVISOR
	CALL	WIFI.UART_INIT
	POP	HL
	JP	SEND_CMD

.OK
	POP	HL
	RET

; ------------------------------------------------------
; Build AT+PING command from HOST_BUFF.
; ------------------------------------------------------
BUILD_PING_CMD
	LD	HL,CMD_BUFF
	LD	DE,CMD_PING_PREFIX
	CALL	APPEND_STR
	LD	IX,HOST_BUFF
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ------------------------------------------------------
; Print parsed +PING response or raw ESP response if +PING is missing.
; Accepts both ESP-AT forms seen in the field:
;   +PING:<ms>
;   +<ms>
; Out: CF=0 - valid ping response found, CF=1 - no ping result.
; ------------------------------------------------------
PRINT_PING_RESULT
	LD	HL,WIFI.RS_BUFF
.NEXT
	LD	A,(HL)
	AND	A
	JR	Z,.RAW
	LD	DE,RESP_PING_PREFIX
	CALL	UTIL.STARTSWITH
	JR	Z,.FOUND_PING
	LD	A,(HL)
	CP	'+'
	JR	Z,.FOUND_SHORT
	CALL	SKIP_LINE
	JR	.NEXT
.FOUND_PING
	LD	BC,6
	ADD	HL,BC
	JR	.FOUND_DECIMAL
.FOUND_SHORT
	INC	HL
.FOUND_DECIMAL
	CALL	FIND_DECIMAL_FIELD
	JR	C,.RAW
	PUSH	HL
	PRINT MSG_REPLY
	POP	HL
	XOR	A
	LD	(PING_DIGITS),A
	CALL	PRINT_DECIMAL_FIELD
	LD	A,(PING_DIGITS)
	AND	A
	JR	Z,.RAW
	PRINTLN MSG_MS
	AND	A
	RET
.RAW
	PRINTLN MSG_NO_PING_RESULT
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE
	SCF
	RET

FIND_DECIMAL_FIELD
	LD	A,(HL)
	CP	' '
	JR	Z,.SKIP
	CP	9
	JR	Z,.SKIP
	CP	'0'
	JR	C,.ERR
	CP	'9'+1
	JR	NC,.ERR
	AND	A
	RET
.SKIP
	INC	HL
	JR	FIND_DECIMAL_FIELD
.ERR
	SCF
	RET

; ------------------------------------------------------
; Skip current LF-separated response line.
; ------------------------------------------------------
SKIP_LINE
	LD	A,(HL)
	AND	A
	RET	Z
	INC	HL
	CP	10
	RET	Z
	JR	SKIP_LINE

; ------------------------------------------------------
; Print ESP response buffer with LF -> CRLF conversion.
; ------------------------------------------------------
PRINT_ESP_RESPONSE
	LD	A,(HL)
	AND	A
	JR	Z,.DONE
	CP	10
	JR	NZ,.PUT_CHAR
	LD	A,13
	CALL	PUT_CHAR
	LD	A,10
.PUT_CHAR
	CALL	PUT_CHAR
	INC	HL
	JR	PRINT_ESP_RESPONSE
.DONE
	LD	A,13
	CALL	PUT_CHAR
	LD	A,10
	JP	PUT_CHAR

PRINT_DECIMAL_FIELD
	LD	A,(HL)
	CP	' '
	JR	Z,.SKIP
	CP	9
	JR	Z,.SKIP
	CP	'0'
	RET	C
	CP	'9'+1
	RET	NC
	CALL	PUT_CHAR
	LD	A,1
	LD	(PING_DIGITS),A
.SKIP
	INC	HL
	JR	PRINT_DECIMAL_FIELD

PUT_CHAR
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	RET

; ------------------------------------------------------
; Append ASCIIZ from DE to buffer at HL.
; ------------------------------------------------------
APPEND_STR
	LD	A,(DE)
	AND	A
	RET	Z
	LD	(HL),A
	INC	HL
	INC	DE
	JR	APPEND_STR

; ------------------------------------------------------
; Append ASCIIZ from IX to buffer at HL.
; ------------------------------------------------------
APPEND_IX_STR
	LD	A,(IX+0)
	AND	A
	RET	Z
	LD	(HL),A
	INC	HL
	INC	IX
	JR	APPEND_IX_STR

MSG_START
	DB "PING "
	PACKAGE_VERSION_TAG
	DB " - SprinterESP host diagnostic"
	DB 0
MSG_USAGE
	DB "Usage: PING.EXE host",0
MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found!",0
MSG_UART_READY
	DB "UART initialized.",0
MSG_RESETTING_ESP
	DB "ESP did not answer, resetting module.",0
MSG_PINGING
	DB "Pinging ",0
MSG_REPLY
	DB "Reply time: ",0
MSG_MS
	DB " ms",0
MSG_NO_PING_RESULT
	DB "No +PING result in ESP response:",0
MSG_PING_TIMEOUT
	DB "Host did not respond (timed out). It may be down, blocking",13,10
	DB "ping, or the network is still coming up - try again.",0
MSG_PING_UNSUPPORTED
	DB "ESP-AT PING failed or is not supported by firmware/emulator.",0
MSG_DONE
	DB "PING done.",0
MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_PING_PREFIX
	DB "AT+PING=",34,0
CMD_QUOTE_CRLF
	DB 34,13,10,0
RESP_PING_PREFIX
	DB "+PING:",0
LIT_BUSY
	DB "busy",0
LIT_TIMEOUT
	DB "timeout",0			; ESP AT+PING failure indicator ("+timeout")
PING_DIGITS
	DB 0
PING_STATUS
	DB 0
PING_RETRY
	DB 0
PING_WRETRY
	DB 0
CMDLINE_PTR
	DW 0			; arg buffer ptr captured from IX at entry

; ------------------------------------------------------
; RESP_IS_PING_TIMEOUT: CF=1 if the AT+PING response means "timed out" - either
; the ESP wrote "+timeout"/"timeout" into RS_BUFF, or it stayed silent so the
; UART layer returned RES_RS_TIMEOUT (PING_STATUS). Trashes A,B,DE,HL.
; ------------------------------------------------------
RESP_IS_PING_TIMEOUT
	LD	A,(PING_STATUS)
	CP	RES_RS_TIMEOUT
	JR	Z,.YES				; no reply at all -> a timeout
	LD	HL,LIT_TIMEOUT
	JP	RESP_CONTAINS			; CF per scan
.YES
	SCF
	RET

; ------------------------------------------------------
; RESP_CONTAINS: scan WIFI.RS_BUFF for the ASCIIZ needle at HL (e.g. "busy",
; "timeout"). Out: CF=1 if found, CF=0 if not. Trashes A,B,DE,HL.
; ------------------------------------------------------
RESP_CONTAINS
	PUSH	HL				; needle start
	LD	DE,WIFI.RS_BUFF
.SCAN
	LD	A,(DE)
	AND	A
	JR	Z,.NO
	POP	HL				; reload needle start
	PUSH	HL
	PUSH	DE				; save haystack position
.CMP
	LD	A,(HL)
	AND	A
	JR	Z,.YES				; whole needle matched
	LD	B,A
	LD	A,(DE)
	CP	B
	JR	NZ,.NEXT
	INC	HL
	INC	DE
	JR	.CMP
.NEXT
	POP	DE				; restore haystack position
	INC	DE
	JR	.SCAN
.YES
	POP	DE				; discard saved position
	POP	HL				; discard needle start
	SCF
	RET
.NO
	POP	HL				; discard needle start
	OR	A
	RET

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

	MODULE MAIN

HOST_BUFF	EQU NETCFG.NETCFG_BSS_END
CMD_BUFF	EQU HOST_BUFF + HOST_SIZE
PING_BSS_END	EQU CMD_BUFF + CMD_SIZE

	ENDMODULE

	END MAIN.START

; ======================================================
; PING for Sprinter DSS Network Kit
; Host reachability diagnostic using ESP-AT AT+PING.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
PING_TIMEOUT		EQU 8000
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
	CALL	ISA.ISA_RESET
	CALL	WCOMMON.INIT_VMODE
	PRINTLN MSG_START

	CALL	PARSE_HOST
	JP	C,USAGE

	CALL	WIFI.UART_FIND
	JP	C,NO_WIFI

	LD	A,(ISA.ISA_SLOT)
	ADD	A,'1'
	LD	(MSG_SLOT_NO),A
	PRINTLN MSG_WIFI_FOUND

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
	LD	HL,CMD_BUFF
	LD	DE,WIFI.RS_BUFF
	LD	BC,PING_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	JR	Z,.PING_OK

	CP	RES_ERROR
	JR	Z,.UNSUPPORTED
	CP	RES_FAIL
	JR	Z,.UNSUPPORTED
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
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
	LD	HL,0x8080
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
; Out: CF=0 - valid +PING response found, CF=1 - no +PING result.
; ------------------------------------------------------
PRINT_PING_RESULT
	LD	HL,WIFI.RS_BUFF
.NEXT
	LD	A,(HL)
	AND	A
	JR	Z,.RAW
	LD	DE,RESP_PING_PREFIX
	CALL	UTIL.STARTSWITH
	JR	Z,.FOUND
	CALL	SKIP_LINE
	JR	.NEXT
.FOUND
	LD	BC,6
	ADD	HL,BC
	PRINT MSG_REPLY
	CALL	PRINT_RESPONSE_LINE
	PRINTLN MSG_MS
	AND	A
	RET
.RAW
	PRINTLN MSG_NO_PING_RESULT
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE
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

PRINT_RESPONSE_LINE
	LD	A,(HL)
	AND	A
	RET	Z
	CP	10
	RET	Z
	CP	13
	RET	Z
	CALL	PUT_CHAR
	INC	HL
	JR	PRINT_RESPONSE_LINE

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
	DB "PING - SprinterESP host diagnostic",0
MSG_USAGE
	DB "Usage: PING.EXE host",0
MSG_WIFI_FOUND
	DB "Sprinter-WiFi found in ISA#"
MSG_SLOT_NO
	DB "n slot.",0
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

HOST_BUFF
	DS HOST_SIZE,0
CMD_BUFF
	DS CMD_SIZE,0

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "esplib.asm"

	END MAIN.START

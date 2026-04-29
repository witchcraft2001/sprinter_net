; ======================================================
; NETPROBE for Sprinter-WiFi / SprinterESP
; Minimal DSS diagnostic utility.
; ======================================================

; Version of EXE file, 1 for DSS 1.70+
EXE_VERSION		EQU 1

; Timeout to wait ESP response
DEFAULT_TIMEOUT		EQU 2000

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

	CALL	WIFI.UART_FIND
	JP	C, NO_WIFI

	LD	A,(ISA.ISA_SLOT)
	ADD	A,'1'
	LD	(MSG_SLOT_NO),A
	PRINTLN MSG_WIFI_FOUND

	CALL	WIFI.UART_INIT
	PRINTLN MSG_UART_READY

	LD	HL,CMD_AT
	CALL	SEND_PROBE_CMD_RECOVER

	LD	HL,CMD_ECHO_OFF
	CALL	SEND_PROBE_CMD_RECOVER

	LD	HL,CMD_GMR
	CALL	SEND_PROBE_CMD_RECOVER
	PRINTLN MSG_GMR_RESPONSE
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE

	PRINTLN MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL to ESP and exit on communication error.
; ------------------------------------------------------
SEND_PROBE_CMD
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
; Send command in HL. If ESP does not answer, reset ESP once and retry.
; This handles the common case where a previous terminal/debug session left the
; module or UART stream in a bad state.
; ------------------------------------------------------
SEND_PROBE_CMD_RECOVER
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
	JP	SEND_PROBE_CMD

.OK
	POP	HL
	RET

; ------------------------------------------------------
; Print ESP response buffer. WIFI.UART_TX_CMD strips CR and keeps LF as a line
; separator, but DSS text output needs CR+LF for a new console line.
; In: HL - zero-ended response buffer.
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

PUT_CHAR
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	RET

MSG_START
	DB "NETPROBE for SprinterESP / Sprinter-WiFi",0

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

MSG_GMR_RESPONSE
	DB "ESP firmware response:",0

MSG_DONE
	DB "NETPROBE done.",0

MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_GMR
	DB "AT+GMR",13,10,0

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "esplib.asm"

	END MAIN.START

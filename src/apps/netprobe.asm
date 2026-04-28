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
	CALL	SEND_PROBE_CMD

	LD	HL,CMD_ECHO_OFF
	CALL	SEND_PROBE_CMD

	LD	HL,CMD_GMR
	CALL	SEND_PROBE_CMD
	PRINTLN MSG_GMR_RESPONSE
	PRINTLN WIFI.RS_BUFF

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

MSG_START
	DB "NETPROBE for SprinterESP / Sprinter-WiFi",13,10,0

MSG_WIFI_FOUND
	DB "Sprinter-WiFi found in ISA#"
MSG_SLOT_NO
	DB "n slot.",0

MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found!",0

MSG_UART_READY
	DB "UART initialized.",0

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

; ======================================================
; WTERM terminal for Sprinter-WiFi ISA Card
; For Sprinter computer DSS
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; License: BSD 3-Clause
; ======================================================

; Define to turn debug ON with DeZog VSCode plugin
;DEFINE               EQU 0

; Define to output TRACE messages
	DEFINE			TRACE


; Version of EXE file, 1 for DSS 1.70+
EXE_VERSION         EQU 1

; Timeout to wait ESP response
DEFAULT_TIMEOUT		EQU	2000

	;DEFDEVICE SPRINTER, 0x4000, 256, 0,1,2,3
    SLDOPT COMMENT WPMEM, LOGPOINT, ASSERTION
    DEVICE NOSLOT64K
	
    IFDEF	DEBUG
		INCLUDE "dss.asm"
		DB 0
		ALIGN 16384, 0
        DS 0x80, 0
    ENDIF

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	;INCLUDE "sprinter.inc"

	MODULE	MAIN

    ORG	0x8080
; ------------------------------------------------------
EXE_HEADER
    DB  "EXE"
    DB  EXE_VERSION                                     ; EXE Version
    DW  0x0080                                          ; Code offset
    DW  0
    DW  0                                               ; Primary loader size
    DW  0                                               ; Reserved
    DW  0
    DW  0
    DW  START                                           ; Loading Address
    DW  START                                           ; Entry Point
    DW  STACK_TOP                                       ; Stack address
    DS  106, 0                                          ; Reserved

    ORG 0x8100
@STACK_TOP
	
; ------------------------------------------------------
START
	
    IFDEF	DEBUG
    	; LD 		IX,CMD_LINE1
		LD		SP, STACK_TOP
		JP MAIN_LOOP
    ENDIF

	CALL 	ISA.ISA_RESET
	
	CALL	WCOMMON.INIT_VMODE

    PRINTLN MSG_START

	CALL	@WCOMMON.FIND_SWF

	PRINTLN WCOMMON.MSG_UART_INIT
	CALL	NETCFG.LOAD
	CALL	WIFI.UART_INIT

	PRINTLN WCOMMON.MSG_ESP_RESET
	CALL	WIFI.ESP_RESET

	CALL	WCOMMON.INIT_ESP

	PRINTLN MSG_HLP

	CALL	WIFI.UART_EMPTY_RS

MAIN_LOOP
	; handle key pressed
	DSS_EXEC	DSS_SCANKEY
	JP		Z,HANDLE_RECEIVE							; if no key pressed
	LD		A,D
	CP		0xAB
	JR		NZ, NO_QUIT
	LD		A,B
	AND		KB_ALT
	JP		NZ, OK_EXIT

NO_QUIT

OUT_CHAR
	LD		A, E
	CP		CR
	JR		NZ, CHK_PRINTABLE
	CALL	PUT_A_CHAR
	LD		A,LF
	CALL	PUT_A_CHAR
	JR		TX_SYMBOL

CHK_PRINTABLE
	CP		0x20
	JP		M, HANDLE_RECEIVE							; do not print < ' '	
	CALL	PUT_A_CHAR

	; transmitt symbol
TX_SYMBOL
	CALL    @WIFI.UART_TX_BYTE
	JP		C,TX_WARN
	LD		A, E
	CP		CR
	JR		NZ,HANDLE_RECEIVE
	; Transmitt LF after CR
	LD		E,LF
	CALL    @WIFI.UART_TX_BYTE
	JP		C,TX_WARN
 
	; check receiver and handle received bytes
HANDLE_RECEIVE
	; check receiver status
	LD		HL,REG_LSR
	CALL	WIFI.UART_READ
	LD		D,A
	; Read pending data first. LSR_RCVE may be set while valid bytes are
	; still waiting in FIFO; flushing here truncates long ESP replies.
	LD		A,D
	AND		LSR_DR
	JP		Z, CHECK_RX_ERROR
	; rx queue is not empty, read
	LD		HL,REG_RBR
	CALL	WIFI.UART_READ
	LD		E,A
	CP		CR
	JR		NZ, CHK_1F
	; print CR+LF
	CALL	PUT_RX_CHAR
	LD		A,LF
	CALL	PUT_RX_CHAR
	JP		HANDLE_RECEIVE

	; check for printable symbol, and print
CHK_1F
	CP		0x20
	CALL	P, PUT_RX_CHAR
	
	; reset error counter if received symbol withoud error
	XOR		A
	LD		(RX_ERR),A
	JP		HANDLE_RECEIVE

CHECK_RX_ERROR
	LD		A,D
	AND		LSR_RCVE
	JP		NZ, RX_WARN

CHECK_FOR_END
	; LD		A,(Q_POS)
	; CP		5
	; JP		Z, OK_EXITDEFDEVICE <deviceid>, <slot_size $100..$10000>, <page_count 1..1024>[, <slot_0_initial_page>[, ...]]
	JP		MAIN_LOOP

RX_WARN
	LD		C,A
	LD		DE,MSG_LSR_VALUE
	CALL	@UTIL.HEXB
	PRINTLN	MSG_RX_ERROR
	LD		HL,RX_ERR
	INC		(HL)
	LD		A,(HL)
	CP		100	
	JP		M,MAIN_LOOP
	; too many RX errors
	PRINTLN MSG_MANY_RX_ERROR
	LD		B,5
	JP		WCOMMON.EXIT
	


TX_WARN
	PRINTLN MSG_TX_ERROR	
	JP		MAIN_LOOP

PUT_A_CHAR
	PUSH	BC,DE
	DSS_EXEC	DSS_PUTCHAR
	POP		DE,BC
	RET

PUT_RX_CHAR
	CALL	WIFI.UART_RX_PAUSE
	CALL	PUT_A_CHAR
	JP		WIFI.UART_RX_RESUME

; ------------------------------------------------------
; Do Some
; ------------------------------------------------------

OK_EXIT
	LD		B,0
	JP		WCOMMON.EXIT


; ------------------------------------------------------
; Custom messages
; ------------------------------------------------------

MSG_START
	DB "Terminal for Sprinter-WiFi by Sprinter Team. v1.0 beta3, ", __DATE__,0
MSG_HLP
	DB 13,10,"Enter ESP AT command or Alt+x to close terminal.",0
MSG_EXIT

MSG_TX_ERROR
	DB "Transmitter not ready",0

MSG_RX_ERROR
	DB "Receiver error LSR: 0x"
MSG_LSR_VALUE	
	DB "xx",0

MSG_MANY_RX_ERROR
	DB "Too many receiver errors!",0


MSG_ALT
	DB "Pressed ALT+"
MSG_ALT_KEY
	DB "xx",0

; TX_DATA
; 	DB  " ",0
; ------------------------------------------------------
; Custom commands
; ------------------------------------------------------
CMD_QUIT 
    DB "QUIT",13,0

RX_ERR
	DB 0

	IFDEF DEBUG
CMD_TEST1	DB "ATE0",13,10,0
BUFF_TEST1	DS RS_BUFF_SIZE,0
	ENDIF

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	;INCLUDE "util.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

    END ;MAIN.START

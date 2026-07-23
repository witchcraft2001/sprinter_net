; ======================================================
; Common code for Sprinter-WiFi utilities
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; License: BSD 3-Clause
; ======================================================
	IFNDEF	_WCOMMON
	DEFINE	_WCOMMON



ENABLE_RTS_CTR	EQU 1

	MODULE WCOMMON

; ------------------------------------------------------
; Check UART result (A=RES_*): print message and exit when A is non-zero.
; UART_TX_CMD also mirrors this state in Carry, but testing A keeps this
; handler correct for callers which preserve only the documented result code.
; ------------------------------------------------------
	;;IFUSED CHECK_ERROR
CHECK_ERROR
	OR		A
	RET		Z
	ADD		A,'0'
	LD		(COMM_ERROR_NO), A
	PRINTLN	MSG_COMM_ERROR
	IFDEF	TRACE
	CALL	DUMP_UART_REGS
	ENDIF
	LD		B,3
	POP		HL											; ret addr reset
	;;ENDIF

; ------------------------------------------------------
;	Program exit point
; ------------------------------------------------------
EXIT
	CALL	REST_VMODE
    DSS_EXEC	DSS_EXIT
; ------------------------------------------------------
; Search Sprinter WiFi card
; ------------------------------------------------------
	;;IFUSED FIND_SWF
FIND_SWF
	; Find Sprinter-WiFi
	CALL    @WIFI.UART_FIND
	JP		C, NO_TL_FOUND
	LD		A,(ISA.ISA_SLOT)
	ADD		A,'1'
	LD      (MSG_SLOT_NO),A
	PRINTLN	MSG_SWF_FOUND
	RET

NO_TL_FOUND
	POP 	BC
	PRINTLN MSG_SWF_NOF
	LD		B,2
	JP		EXIT
	;;ENDIF

; ------------------------------------------------------
; Dump all UTL16C550 registers to screen for debug
; ------------------------------------------------------
	;;IFUSED DUMP_UART_REGS
	IFDEF	TRACE
DUMP_UART_REGS
	; Dump, DLAB=0 registers
	LD		BC, 0x0800
	CALL	DUMP_REGS

	; Dump, DLAB=1 registers
	LD		HL, REG_LCR
	LD		E, LCR_DLAB | LCR_WL8
	CALL	WIFI.UART_WRITE

	LD		BC, 0x0210
	CALL	DUMP_REGS

	LD		HL, REG_LCR
	LD		E, LCR_WL8
	JP		WIFI.UART_WRITE
	;CALL	WIFI.UART_WRITE
	;RET

DUMP_REGS
	LD		HL, PORT_UART_A

DR_NEXT
	LD		DE,MSG_DR_RN
	CALL	@UTIL.HEXB
	INC		C

	CALL    WIFI.UART_READ
	PUSH    BC
	LD		C,A
	LD		DE,MSG_DR_RV
	CALL	@UTIL.HEXB
	PUSH 	HL

	PRINTLN MSG_DR

	POP		HL,BC
	INC		HL
	DJNZ	DR_NEXT
	RET
	ENDIF
	;;ENDIF

; ------------------------------------------------------
; Non-blocking check for user cancel: Esc (E=0x1B / 0x07) or Ctrl+Z (E=0x1A
; with any Ctrl modifier held). Calls DSS_SCANKEY and consumes the matching
; key from the buffer. On cancel sets WCOMMON.CANCELLED so callers nested
; inside UART/ISA loops can propagate up via existing error paths and the
; top-level error handler can redirect to CANCEL_EXIT.
; Out: CF=1 - cancel pressed, CF=0 - no cancel.
; Preserves A, BC, DE, HL.
; Caller must NOT have ISA window open; SCANKEY may switch memory pages.
; ------------------------------------------------------
	;;IFUSED CHECK_CANCEL
CHECK_CANCEL
	PUSH	AF,BC,DE,HL
	DSS_EXEC	DSS_SCANKEY
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	CP	0x07
	JR	Z,.CANCEL
	CP	0x1A
	JR	NZ,.NO_KEY
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	POP	HL,DE,BC,AF
	SCF
	RET
.NO_KEY
	POP	HL,DE,BC,AF
	AND	A
	RET
	;;ENDIF

; ------------------------------------------------------
; Same as CHECK_CANCEL but allowed to be called while ISA window is open.
; Closes ISA, polls keyboard, reopens ISA.
; Out: CF=1 if cancel pressed.
; Preserves all registers including A.
; ------------------------------------------------------
CHECK_CANCEL_IN_ISA
	PUSH	AF,BC,DE,HL
	CALL	@ISA.ISA_CLOSE
	DSS_EXEC	DSS_SCANKEY
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	CP	0x07
	JR	Z,.CANCEL
	CP	0x1A
	JR	NZ,.NO_KEY
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	POP	HL,DE,BC,AF
	SCF
	RET
.NO_KEY
	; Optional idle callback (e.g. a clock tick), run here while ISA is CLOSED so
	; the callback may use DSS/BIOS safely. Zero by default -> no-op for apps that
	; don't set it. The callback must return with a plain RET and may clobber
	; registers (we restore them below).
	LD	HL,(IDLE_CB)
	LD	A,H
	OR	L
	CALL	NZ,.CALL_CB
	CALL	@ISA.ISA_OPEN
	POP	HL,DE,BC,AF
	AND	A
	RET
.CALL_CB
	JP	(HL)			; call IDLE_CB (it RETs to the CALL NZ site)

; Cancellation flag. Set by CHECK_CANCEL when Esc/Ctrl+Z detected.
; Top-level error handlers in apps check this and redirect to CANCEL_EXIT.
CANCELLED	DB 0
; Idle callback pointer, invoked from CHECK_CANCEL_IN_ISA while ISA is closed
; (so it can call DSS/BIOS). Apps set it to a routine; 0 = none.
IDLE_CB		DW 0

; ------------------------------------------------------
; Store old video mode and set 80x32 without clearing the console.
; ------------------------------------------------------
	;;IFUSED INIT_VMODE
INIT_VMODE
	PUSH	BC,DE,HL
	; Store previous vmode
	LD		C,DSS_GETVMOD
	RST		DSS
	LD		(SAVE_VMODE),A
	CP		DSS_VMOD_T80
	; Set vmode 80x32
	JR		Z, IVM_ALRDY_80
	LD		C,DSS_SETVMOD
	LD		A,DSS_VMOD_T80
	RST		DSS
IVM_ALRDY_80
	POP		HL,DE,BC
	RET
	;;ENDIF
; ------------------------------------------------------
; Restore saved video mode
; ------------------------------------------------------
	;;IFUSED	REST_VMODE
REST_VMODE
	PUSH	BC
	LD		A,(SAVE_VMODE)
	CP		DSS_VMOD_T80
	JR		Z, RVM_SAME
	; Restore mode
	PRINTLN MSG_PRESS_AKEY

	LD		C, DSS_WAITKEY
	RST		DSS

	LD		C,DSS_SETVMOD
	RST		DSS
RVM_SAME
	POP		BC
	RET
	;;ENDIF

; ------------------------------------------------------
; Init basic parameters of ESP
; ------------------------------------------------------
	;;IFUSED INIT_ESP
INIT_ESP
	PUSH	BC, DE
	LD		DE, @WIFI.RS_BUFF
	LD		BC, DEFAULT_TIMEOUT

   	TRACELN	MSG_ECHO_OFF
	SEND_CMD CMD_ECHO_OFF

   	TRACELN MSG_STATIOJN_MODE
	SEND_CMD CMD_STATION_MODE

   	TRACELN MSG_NO_SLEEP
	SEND_CMD CMD_NO_SLEEP

	IF ENABLE_RTS_CTR
   		TRACELN MSG_SET_UART
		IFDEF	_NETCFG
		CALL	SETUP_UART_FLOW
		ELSE
		SEND_CMD CMD_SET_SPEED
		ENDIF
	ENDIF

   	TRACELN MSG_SET_OPT
	SEND_CMD CMD_CWLAP_OPT
	POP		DE,BC
	RET
	;;ENDIF
; ------------------------------------------------------
; Build "AT+UART_CUR=<baud>,8,1,0,3\r\n" using current NET.CFG baud
; into UART_FLOW_CMD_BUFF. Out: HL = pointer to ASCIIZ command.
; Hardcoding the baud (e.g. 115200) breaks utilities when NET.CFG selects a
; non-default speed: UART_INIT has already switched the local 16550 to that
; speed, so a static "AT+UART_CUR=115200,..." would arrive at ESP at the
; wrong baud and brick the UART link.
; Only assembled when NETCFG library is included (utilities that need
; per-config flow control: wget, tftp, udptest, etc.).
; ------------------------------------------------------
	IFDEF _NETCFG
BUILD_UART_FLOW_CMD
	PUSH	BC,DE
	LD		HL,UART_FLOW_CMD_BUFF
	LD		DE,UART_FLOW_PREFIX
	CALL	.APPEND
	; NETCFG.GET_UART_BAUD_TEXT: out HL = ASCIIZ baud text (e.g. "38400").
	; Move HL→DE to use as source, restore destination from saved.
	PUSH	HL								; save dest
	CALL	@NETCFG.GET_UART_BAUD_TEXT
	EX		DE,HL							; DE = baud text source
	POP		HL								; HL = dest
	CALL	.APPEND
	LD		DE,UART_FLOW_SUFFIX
	CALL	.APPEND
	LD		HL,UART_FLOW_CMD_BUFF
	POP		DE,BC
	RET

; Append ASCIIZ string at DE to buffer at HL. Out: HL = terminator pos.
.APPEND
	LD		A,(DE)
	AND		A
	RET		Z
	LD		(HL),A
	INC		HL
	INC		DE
	JR		.APPEND

UART_FLOW_PREFIX
	DB	"AT+UART_CUR=",0
UART_FLOW_SUFFIX
	DB	",8,1,0,3",13,10,0
UART_FLOW_VERIFY_CMD
	DB	"AT",13,10,0

UART_FLOW_CMD_BUFF
	DS	40,0

; ------------------------------------------------------
; Send AT+UART_CUR with NET.CFG baud + flow=3, then re-apply local 16550
; baud divisor and verify the link with AT.
; ESP-AT may emit the trailing OK at the *new* baud (not the old one), so
; the first send is best-effort: we don't trust its success status. After
; the send we switch local UART to the configured baud and use a fresh AT
; round-trip to confirm both sides agreed on the new framing.
; Out: A=0 on success, A=non-zero ESP result on failure.
; ------------------------------------------------------
SETUP_UART_FLOW
	PUSH	BC,DE,HL
	CALL	BUILD_UART_FLOW_CMD					; HL=cmd buffer
	LD		DE,@WIFI.RS_BUFF
	LD		BC,DEFAULT_TIMEOUT
	CALL	@WIFI.UART_TX_CMD					; ignore status

	CALL	@NETCFG.APPLY_UART_BAUD				; switch local divisor
	CALL	@WIFI.UART_INIT						; re-init UART with new divisor + flow=on

	LD		HL,UART_FLOW_VERIFY_CMD
	LD		DE,@WIFI.RS_BUFF
	LD		BC,DEFAULT_TIMEOUT
	CALL	@WIFI.UART_TX_CMD					; verify at new baud
	POP		HL,DE,BC
	RET
	ENDIF

; ------------------------------------------------------
; Set DHCP mode
; Out: CF=1 if error
; ------------------------------------------------------
	;;IFUSED SET_DHCP_MODE
SET_DHCP_MODE
	PUSH	BC,DE
	LD		DE, WIFI.RS_BUFF
	LD		BC, DEFAULT_TIMEOUT
	TRACELN MSG_SET_DHCP
	SEND_CMD CMD_SET_DHCP
	POP		DE,BC
	RET
	;;ENDIF

; ------------------------------------------------------
; Close any TCP/UDP connection a previous (possibly aborted or crashed) run
; left open on the ESP, and flush stale UART bytes. ESP-AT rejects AT+CIPMUX
; with ERROR while a connection is still established, which made wget/ftp/telnet
; fail with "communication error #1" on their first command after such a
; leftover (ping is immune because it never touches CIPMUX). Call this once,
; after AT/ATE0 and before AT+CIPMUX. Every step ignores its result: with no
; connection (or the other mux mode) the close just returns ERROR, which is
; expected and harmless. Trashes A,BC,DE,HL.
; ------------------------------------------------------
; Compact: send close-all, then fall through to send close-one. UART_TX_CMD
; already empties the RX FIFO before each send, so the next command (AT+CIPMUX)
; starts clean without an explicit flush here.
CLEAN_ESP_LINKS
	LD	HL,CMD_CIPCLOSE_ALL		; close all links (id 5) - multi-conn mode
	CALL	.tx
	LD	HL,CMD_CIPCLOSE_ONE		; close the single connection - single mode
.tx
	LD	DE,@WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	JP	@WIFI.UART_TX_CMD

CMD_CIPCLOSE_ALL
	DB	"AT+CIPCLOSE=5",13,10,0
CMD_CIPCLOSE_ONE
	DB	"AT+CIPCLOSE",13,10,0

; ------------------------------------------------------
; Require that NETUP has brought the network up: env NET must equal "WIFI" and
; NET_ESP_HW must be set (both published by NETUP). On failure print a hint and
; exit with B=4 (config error). Network-dependent tools call this before any
; ESP/TCP operation. Reads env via DSS ENVIRON (#46/#01).
; ------------------------------------------------------
REQUIRE_NET_UP
	LD	HL,N_NET_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.FAIL				; NET not set
	LD	HL,ENV_VAL_BUF
	LD	DE,V_WIFI
	CALL	.STRMATCH
	JR	NZ,.FAIL			; NET != WIFI
	LD	HL,N_ESP_HW_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.FAIL				; NET_ESP_HW not set
	LD	A,(ENV_VAL_BUF)
	OR	A
	JR	Z,.FAIL				; NET_ESP_HW empty
	RET
.FAIL
	PRINTLN MSG_NET_NOT_UP
	LD	B,4
	JP	EXIT
; Compare ASCIIZ at HL and DE. Out: Z if equal. Trashes A,C,HL,DE.
.STRMATCH
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	CP	C
	RET	NZ
	OR	A
	RET	Z
	INC	HL
	INC	DE
	JR	.STRMATCH

N_NET_KEY	DB "NET",0
N_ESP_HW_KEY	DB "NET_ESP_HW",0
V_WIFI		DB "WIFI",0
MSG_NET_NOT_UP	DB "Network is not up - run NETUP first.",0
ENV_VAL_BUF	DS 32,0

; ------------------------------------------------------
; Messages
; ------------------------------------------------------
	;;IFUSED FIND_SWF
MSG_SWF_NOF
	DB "Sprinter-WiFi not found!",0
MSG_SWF_FOUND
	DB "Sprinter-WiFi found in ISA#"
MSG_SLOT_NO
	DB "n slot.",0
	;;ENDIF

MSG_COMM_ERROR
	DB "Error communication with Sprinter-WiFi #"

COMM_ERROR_NO
	DB "n!",0

MSG_PRESS_AKEY
	DB "Press any key to continue...",0

MSG_ESP_RESET
	DB "Reset ESP module.",0

MSG_UART_INIT
	DB "Reset UART.",0

LINE_END
	DB 13,10,0

	;;IFUSED INIT_VMODE
SAVE_VMODE
	DB 0
	;;ENDIF

; ------------------------------------------------------
; Debug messages
; ------------------------------------------------------
	IFDEF TRACE
MSG_DR
	DB	"Reg[0x"
MSG_DR_RN
	DB	"vv]=0x"
MSG_DR_RV
	DB	"vv",0

MSG_ECHO_OFF
	DB "Echo off",0

MSG_STATIOJN_MODE
	DB "Station mode",0

MSG_NO_SLEEP
	DB "No sleep",0

MSG_SET_UART
	DB "Setup uart",0

MSG_SET_OPT
	DB "Set options",0

MSG_SET_DHCP
	DB	"Set DHCP mode",0

	ENDIF

; ------------------------------------------------------
; Commands
; ------------------------------------------------------
; CMD_QUIT
;     DB "QUIT\r",0

CMD_VERSION
	DB "AT+GMR",13,10,0
CMD_SET_SPEED
	DB	"AT+UART_CUR=115200,8,1,0,3",13,10,0
CMD_ECHO_OFF
	DB	"ATE0",13,10,0
CMD_STATION_MODE
	DB	"AT+CWMODE=1",13,10,0
CMD_NO_SLEEP
	DB	"AT+SLEEP=0",13,10,0
CMD_CHECK_CONN_AP
	DB	"AT+CWJAP?",13,10,0
CMD_CWLAP_OPT
	DB	"AT+CWLAPOPT=1,23",13,10,0
CMD_GET_AP_LIST
	DB "AT+CWLAP",13,10,0
CMD_GET_DHCP
	DB "AT+CWDHCP?",13,10,0
CMD_SET_DHCP
	DB	"AT+CWDHCP=1,1",13,10,0
CMD_GET_IP
	DB "AT+CIPSTA?",13,10,0


	ENDMODULE

	ENDIF

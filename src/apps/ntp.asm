; ======================================================
; NTP for Sprinter ESP Network Kit
; Minimal NTPv3 client over UDP (firmware-independent).
;
; Sends a 48-byte client query to UDP port 123 through the
; Sprinter-WiFi ESP (AT+CIPSTART="UDP",...), reads the reply,
; converts the transmit timestamp (seconds since 1900) to UTC,
; applies the NET.CFG timezone, and writes local time to the DSS
; clock via DSS_SETTIME.
;
; This replaces the old AT+CIPSNTPCFG/AT+CIPSNTPTIME approach,
; which is not usable on the real ESP12-F / ESP-AT V2.2.1 board.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
NTP_TIMEOUT		EQU 8000
RECV_BUFFER_SIZE	EQU 96

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

	XOR	A
	LD	(SOCKET_OPEN),A

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

	CALL	WCOMMON.SETUP_UART_FLOW
	AND	A
	JR	Z,.FLOW_OK
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT
.FLOW_OK

	CALL	WCOMMON.CLEAN_ESP_LINKS		; drop any link a prior run left open
	LD	HL,CMD_CIPMUX_0
	CALL	SEND_CMD

	PRINT	MSG_QUERY
	PRINT	NETCFG.CFG_NTP
	PRINT	WCOMMON.LINE_END

	; --- Open UDP socket to <server>:123 -------------------
	LD	HL,NETCFG.CFG_NTP
	LD	DE,PORT_123
	CALL	UDP.OPEN
	JP	C,NET_ERROR_A
	LD	A,1
	LD	(SOCKET_OPEN),A

	; --- Send the 48-byte NTP client request ---------------
	CALL	BUILD_NTP_REQUEST
	LD	HL,NTP_REQUEST
	LD	BC,48
	CALL	UDP.SEND_BUFFER
	JP	C,NET_ERROR_A

	; --- Receive the reply ---------------------------------
	LD	HL,RECV_BUFFER
	LD	BC,RECV_BUFFER_SIZE
	LD	DE,NTP_TIMEOUT
	CALL	UDP.RECEIVE
	JP	C,NET_ERROR_A
	LD	(RECV_LEN),BC

	CALL	UDP.CLOSE
	XOR	A
	LD	(SOCKET_OPEN),A

	; A valid reply carries the transmit timestamp at bytes 40..43,
	; so we need at least 44 bytes of payload.
	LD	HL,(RECV_LEN)
	LD	DE,44
	AND	A
	SBC	HL,DE
	JP	C,BAD_REPLY

	; Capture transmit timestamp (NTP bytes 40..43, big-endian).
	LD	HL,RECV_BUFFER + 40
	LD	DE,NTP_TX_SECS
	LD	BC,4
	LDIR

	; --- Convert and set the clock -------------------------
	CALL	NTP_TO_UNIX			; WORK_SECS = Unix UTC seconds
	CALL	SAVE_UTC_BACKUP
	CALL	UNIX_TO_DATE			; -> PARSED_* (UTC)
	PRINT	MSG_UTC
	CALL	PRINT_DATE
	PRINT	WCOMMON.LINE_END

	CALL	RESTORE_FROM_UTC_BACKUP
	CALL	APPLY_TZ_FROM_CFG
	CALL	UNIX_TO_DATE			; -> PARSED_* (local)
	PRINT	MSG_LOCAL
	CALL	PRINT_DATE
	PRINT	MSG_TZ_PRE
	CALL	PRINT_TZ_LABEL
	PRINT	MSG_TZ_POST
	PRINT	WCOMMON.LINE_END

	CALL	SET_DSS_TIME
	JR	C,.SET_ERROR
	PRINTLN MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

.SET_ERROR
	PRINTLN MSG_SET_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

BAD_REPLY
	PRINTLN MSG_BAD_REPLY
	LD	B,3
	JP	WCOMMON.EXIT

; CF=1 entry with A = ESP/UDP result code. Closes the socket if open.
NET_ERROR_A
	PUSH	AF
	LD	A,(SOCKET_OPEN)
	AND	A
	CALL	NZ,UDP.CLOSE
	XOR	A
	LD	(SOCKET_OPEN),A
	POP	AF
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL, treat any non-zero result as fatal.
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
; Synchronize non-destructively, then send the command.
; ------------------------------------------------------
SEND_CMD_RECOVER
	PUSH	HL
	CALL	WCOMMON.SYNC_ESP_COMMAND
	POP	HL
	JP	SEND_CMD

; ------------------------------------------------------
; Build the 48-byte NTPv3 client request in BSS.
; Byte 0 = 0x1B (LI=0, VN=3, Mode=3 client); the rest zero.
; ------------------------------------------------------
BUILD_NTP_REQUEST
	LD	HL,NTP_REQUEST
	LD	D,H
	LD	E,L
	INC	DE
	LD	(HL),0
	LD	BC,47
	LDIR
	LD	A,0x1B
	LD	(NTP_REQUEST),A
	RET

; ------------------------------------------------------
; NTP_TO_UNIX: NTP_TX_SECS (4 bytes BE) -> WORK_SECS (4 bytes LE),
; with the NTP-Unix offset (2208988800 = 0x83AA7E80) subtracted.
; ------------------------------------------------------
NTP_TO_UNIX
	LD	A,(NTP_TX_SECS + 3)
	LD	(WORK_SECS + 0),A
	LD	A,(NTP_TX_SECS + 2)
	LD	(WORK_SECS + 1),A
	LD	A,(NTP_TX_SECS + 1)
	LD	(WORK_SECS + 2),A
	LD	A,(NTP_TX_SECS + 0)
	LD	(WORK_SECS + 3),A
	LD	HL,NTP_OFFSET_LE
	JP	SUB32_HL_FROM_WORK

; WORK_SECS -= [HL] (4 bytes LE). CF=1 on borrow. Advances HL by 4.
SUB32_HL_FROM_WORK
	LD	A,(WORK_SECS + 0)
	SUB	(HL)
	LD	(WORK_SECS + 0),A
	INC	HL
	LD	A,(WORK_SECS + 1)
	SBC	A,(HL)
	LD	(WORK_SECS + 1),A
	INC	HL
	LD	A,(WORK_SECS + 2)
	SBC	A,(HL)
	LD	(WORK_SECS + 2),A
	INC	HL
	LD	A,(WORK_SECS + 3)
	SBC	A,(HL)
	LD	(WORK_SECS + 3),A
	INC	HL
	RET

; Subtract [HL] (4-byte LE) from WORK_SECS only if it does not underflow.
; Out: CF=0 if taken, CF=1 if it would underflow (WORK_SECS unchanged).
TRY_SUB32
	LD	DE,WORK_SECS
	LD	BC,SAVE_SECS
	PUSH	HL
	LD	A,(DE)
	LD	(BC),A
	INC	DE
	INC	BC
	LD	A,(DE)
	LD	(BC),A
	INC	DE
	INC	BC
	LD	A,(DE)
	LD	(BC),A
	INC	DE
	INC	BC
	LD	A,(DE)
	LD	(BC),A
	POP	HL
	CALL	SUB32_HL_FROM_WORK
	RET	NC
	LD	BC,SAVE_SECS
	LD	DE,WORK_SECS
	LD	A,(BC)
	LD	(DE),A
	INC	BC
	INC	DE
	LD	A,(BC)
	LD	(DE),A
	INC	BC
	INC	DE
	LD	A,(BC)
	LD	(DE),A
	INC	BC
	INC	DE
	LD	A,(BC)
	LD	(DE),A
	SCF
	RET

; ------------------------------------------------------
; UNIX_TO_DATE: split WORK_SECS (Unix seconds, LE) into the
; PARSED_* date/time fields by repeated subtraction.
; ------------------------------------------------------
UNIX_TO_DATE
	LD	HL,1970
	LD	(PARSED_YEAR),HL
.YEAR_LOOP
	LD	HL,(PARSED_YEAR)
	CALL	IS_LEAP
	OR	A
	JR	NZ,.LEAP_YEAR
	LD	HL,YEAR_SECS_REGULAR
	JR	.TRY_YEAR
.LEAP_YEAR
	LD	HL,YEAR_SECS_LEAP
.TRY_YEAR
	CALL	TRY_SUB32
	JR	C,.YEAR_DONE
	LD	HL,(PARSED_YEAR)
	INC	HL
	LD	(PARSED_YEAR),HL
	JR	.YEAR_LOOP
.YEAR_DONE

	LD	A,1
	LD	(PARSED_MONTH),A
.MONTH_LOOP
	LD	HL,(PARSED_YEAR)
	CALL	IS_LEAP
	OR	A
	JR	Z,.NORM_MONTH
	LD	HL,MONTH_DAYS_LEAP
	JR	.HAVE_MONTHS
.NORM_MONTH
	LD	HL,MONTH_DAYS_REGULAR
.HAVE_MONTHS
	LD	A,(PARSED_MONTH)
	DEC	A
	LD	C,A
	LD	B,0
	ADD	HL,BC
	LD	A,(HL)				; days in this month
	; TMP_SECS = days * 86400 (repeated add; <= 31*86400 fits 24-bit).
	LD	B,A
	LD	HL,TMP_SECS
	XOR	A
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
.MUL_LP
	LD	A,B
	OR	A
	JR	Z,.MUL_DONE
	LD	HL,DAY_SECS_LE
	PUSH	BC
	LD	A,(TMP_SECS + 0)
	ADD	A,(HL)
	LD	(TMP_SECS + 0),A
	INC	HL
	LD	A,(TMP_SECS + 1)
	ADC	A,(HL)
	LD	(TMP_SECS + 1),A
	INC	HL
	LD	A,(TMP_SECS + 2)
	ADC	A,(HL)
	LD	(TMP_SECS + 2),A
	INC	HL
	LD	A,(TMP_SECS + 3)
	ADC	A,(HL)
	LD	(TMP_SECS + 3),A
	POP	BC
	DEC	B
	JR	.MUL_LP
.MUL_DONE
	LD	HL,TMP_SECS
	CALL	TRY_SUB32
	JR	C,.MONTH_DONE
	LD	A,(PARSED_MONTH)
	INC	A
	LD	(PARSED_MONTH),A
	JR	.MONTH_LOOP
.MONTH_DONE

	XOR	A
	LD	(PARSED_DAY),A
.DAY_LOOP
	LD	HL,DAY_SECS_LE
	CALL	TRY_SUB32
	JR	C,.DAY_DONE
	LD	A,(PARSED_DAY)
	INC	A
	LD	(PARSED_DAY),A
	JR	.DAY_LOOP
.DAY_DONE
	LD	A,(PARSED_DAY)
	INC	A				; 1-based
	LD	(PARSED_DAY),A

	XOR	A
	LD	(PARSED_HOUR),A
.HOUR_LOOP
	LD	HL,HOUR_SECS_LE
	CALL	TRY_SUB32
	JR	C,.HOUR_DONE
	LD	A,(PARSED_HOUR)
	INC	A
	LD	(PARSED_HOUR),A
	JR	.HOUR_LOOP
.HOUR_DONE

	XOR	A
	LD	(PARSED_MINUTE),A
.MIN_LOOP
	LD	HL,MIN_SECS_LE
	CALL	TRY_SUB32
	JR	C,.MIN_DONE
	LD	A,(PARSED_MINUTE)
	INC	A
	LD	(PARSED_MINUTE),A
	JR	.MIN_LOOP
.MIN_DONE
	LD	A,(WORK_SECS + 0)
	LD	(PARSED_SECOND),A
	RET

; IS_LEAP: HL = year -> A=1 if leap, else 0. Trashes BC,DE,HL.
IS_LEAP
	LD	D,H
	LD	E,L
	CALL	MOD_HL_400
	LD	A,H
	OR	L
	JR	Z,.LEAP
	LD	H,D
	LD	L,E
	CALL	MOD_HL_100
	LD	A,H
	OR	L
	JR	Z,.NOT_LEAP
	LD	A,E
	AND	3
	JR	Z,.LEAP
.NOT_LEAP
	XOR	A
	RET
.LEAP
	LD	A,1
	RET

MOD_HL_100
	LD	BC,100
.LP
	OR	A
	SBC	HL,BC
	JR	NC,.LP
	ADD	HL,BC
	RET

MOD_HL_400
	LD	BC,400
.LP
	OR	A
	SBC	HL,BC
	JR	NC,.LP
	ADD	HL,BC
	RET

SAVE_UTC_BACKUP
	LD	HL,WORK_SECS
	LD	DE,UTC_BACKUP
	LD	BC,4
	LDIR
	RET

RESTORE_FROM_UTC_BACKUP
	LD	HL,UTC_BACKUP
	LD	DE,WORK_SECS
	LD	BC,4
	LDIR
	RET

; ------------------------------------------------------
; APPLY_TZ_FROM_CFG: read NET.CFG TZ in the form
; "[+|-]H" or "[+|-]H:MM" (e.g. "3", "+5:30", "-3:30",
; "5:45"), then add the signed offset to WORK_SECS.
; Minute offsets exist for several zones (IST +5:30,
; NPT +5:45, ACST +9:30, ...). Missing / empty /
; unparseable TZ => no-op (UTC).
; ------------------------------------------------------
APPLY_TZ_FROM_CFG
	XOR	A
	LD	(TZ_NEG),A
	LD	(TZ_HOURS),A
	LD	(TZ_MINS),A
	LD	HL,NETCFG.CFG_TZ
	LD	A,(HL)
	OR	A
	JR	Z,APPLY_TZ_OFFSET
	CP	'-'
	JR	Z,.NEG
	CP	'+'
	JR	NZ,.HOURS
	INC	HL
	JR	.HOURS
.NEG
	LD	A,1
	LD	(TZ_NEG),A
	INC	HL
.HOURS
	LD	A,(HL)
	SUB	'0'
	JR	C,.AFTER_HOURS
	CP	10
	JR	NC,.AFTER_HOURS
	LD	B,A
	LD	A,(TZ_HOURS)
	ADD	A,A
	LD	C,A
	ADD	A,A
	ADD	A,A
	ADD	A,C
	ADD	A,B
	LD	(TZ_HOURS),A
	INC	HL
	JR	.HOURS
.AFTER_HOURS
	LD	A,(HL)
	CP	':'
	JR	NZ,APPLY_TZ_OFFSET
	INC	HL
.MINUTES
	LD	A,(HL)
	SUB	'0'
	JR	C,APPLY_TZ_OFFSET
	CP	10
	JR	NC,APPLY_TZ_OFFSET
	LD	B,A
	LD	A,(TZ_MINS)
	ADD	A,A
	LD	C,A
	ADD	A,A
	ADD	A,A
	ADD	A,C
	ADD	A,B
	LD	(TZ_MINS),A
	INC	HL
	JR	.MINUTES

; WORK_SECS += sign(TZ_NEG) * (TZ_HOURS*3600 + TZ_MINS*60).
; Max abs offset 14:00 -> 50400 (+ up to 59 min) < 65536, so HL suffices.
APPLY_TZ_OFFSET
	LD	HL,0
	LD	A,(TZ_HOURS)
	OR	A
	JR	Z,.MINS
	LD	B,A
	LD	DE,3600
.MULH
	ADD	HL,DE
	DJNZ	.MULH
.MINS
	LD	A,(TZ_MINS)
	OR	A
	JR	Z,.HAVE
	LD	B,A
	LD	DE,60
.MULM
	ADD	HL,DE
	DJNZ	.MULM
.HAVE
	LD	A,H
	OR	L
	RET	Z				; zero offset -> stay UTC
	LD	A,(TZ_NEG)
	OR	A
	JR	NZ,.NEGATIVE
	LD	A,(WORK_SECS + 0)
	ADD	A,L
	LD	(WORK_SECS + 0),A
	LD	A,(WORK_SECS + 1)
	ADC	A,H
	LD	(WORK_SECS + 1),A
	LD	A,(WORK_SECS + 2)
	ADC	A,0
	LD	(WORK_SECS + 2),A
	LD	A,(WORK_SECS + 3)
	ADC	A,0
	LD	(WORK_SECS + 3),A
	RET
.NEGATIVE
	LD	A,(WORK_SECS + 0)
	SUB	L
	LD	(WORK_SECS + 0),A
	LD	A,(WORK_SECS + 1)
	SBC	A,H
	LD	(WORK_SECS + 1),A
	LD	A,(WORK_SECS + 2)
	SBC	A,0
	LD	(WORK_SECS + 2),A
	LD	A,(WORK_SECS + 3)
	SBC	A,0
	LD	(WORK_SECS + 3),A
	RET

; Print sign + hours, plus ":MM" when the minute offset is non-zero.
PRINT_TZ_LABEL
	LD	A,(TZ_NEG)
	OR	A
	JR	NZ,.NEG
	LD	A,'+'
	JR	.SIGN
.NEG
	LD	A,'-'
.SIGN
	CALL	PUT_CHAR
	LD	A,(TZ_HOURS)
	LD	L,A
	LD	H,0
	CALL	PRINT_HL_DEC
	LD	A,(TZ_MINS)
	OR	A
	RET	Z
	LD	A,':'
	CALL	PUT_CHAR
	LD	A,(TZ_MINS)
	JP	PRINT_A_2

; ------------------------------------------------------
; DSS_SETTIME (syscall #22): D=day, E=month, IX=year,
; H=hour, L=minute, B=second. DSS computes day-of-week.
; ------------------------------------------------------
SET_DSS_TIME
	LD	A,(PARSED_DAY)
	LD	D,A
	LD	A,(PARSED_MONTH)
	LD	E,A
	LD	HL,(PARSED_YEAR)
	PUSH	HL
	POP	IX
	LD	A,(PARSED_HOUR)
	LD	H,A
	LD	A,(PARSED_MINUTE)
	LD	L,A
	LD	A,(PARSED_SECOND)
	LD	B,A
	LD	C,DSS_SETTIME
	RST	DSS
	RET

; PRINT_DATE: "YYYY-MM-DD HH:MM:SS" from PARSED_* (no newline).
PRINT_DATE
	LD	HL,(PARSED_YEAR)
	CALL	PRINT_HL_DEC
	LD	A,'-'
	CALL	PUT_CHAR
	LD	A,(PARSED_MONTH)
	CALL	PRINT_A_2
	LD	A,'-'
	CALL	PUT_CHAR
	LD	A,(PARSED_DAY)
	CALL	PRINT_A_2
	LD	A,' '
	CALL	PUT_CHAR
	LD	A,(PARSED_HOUR)
	CALL	PRINT_A_2
	LD	A,':'
	CALL	PUT_CHAR
	LD	A,(PARSED_MINUTE)
	CALL	PRINT_A_2
	LD	A,':'
	CALL	PUT_CHAR
	LD	A,(PARSED_SECOND)
	JP	PRINT_A_2

; PRINT_A_2: print A as a zero-padded 2-digit decimal.
PRINT_A_2
	LD	L,A
	LD	H,0
	LD	DE,NUM_BUFF
	CALL	UTIL.UTOA
	LD	A,(NUM_BUFF+1)
	AND	A
	JR	NZ,.PRINT
	LD	A,'0'
	CALL	PUT_CHAR
.PRINT
	PRINT	NUM_BUFF
	RET

PRINT_HL_DEC
	LD	DE,NUM_BUFF
	CALL	UTIL.UTOA
	PRINT	NUM_BUFF
	RET

PUT_CHAR
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	RET

; ------------------------------------------------------
; Strings
; ------------------------------------------------------
MSG_START
	DB "NTP "
	PACKAGE_VERSION_TAG
	DB " - set DSS time over UDP NTP"
	DB 0
MSG_UART_READY
	DB "UART initialized.",0
MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found.",0
MSG_QUERY
	DB "Querying NTP server: ",0
MSG_UTC
	DB "UTC time:   ",0
MSG_LOCAL
	DB "Local time: ",0
MSG_TZ_PRE
	DB " (TZ ",0
MSG_TZ_POST
	DB ")",0
MSG_DONE
	DB "DSS clock updated.",0
MSG_BAD_REPLY
	DB "Short or invalid NTP reply.",0
MSG_SET_ERROR
	DB "Failed to set DSS time.",0
MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "0!",0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_CIPMUX_0
	DB "AT+CIPMUX=0",13,10,0
PORT_123
	DB "123",0

; ------------------------------------------------------
; Date constants (32-bit LE; sjasmplus DD emits little-endian).
; ------------------------------------------------------
NTP_OFFSET_LE		DD 2208988800		; 1900..1970 epoch offset
YEAR_SECS_REGULAR	DD 31536000		; 365*86400
YEAR_SECS_LEAP		DD 31622400		; 366*86400
DAY_SECS_LE		DD 86400
HOUR_SECS_LE		DD 3600
MIN_SECS_LE		DD 60

MONTH_DAYS_REGULAR	DB 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
MONTH_DAYS_LEAP		DB 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

	ENDMODULE

; Keep ESP helper scratch buffers outside NTP code/data; the default TCP base
; depends on WIFI.RS_BUFF, which is defined in esplib.asm after the TCP/UDP
; helpers are assembled here (same pattern as udptest/tftp).
	DEFINE ESP_TCP_BSS_BASE_OVERRIDE
ESP_TCP_BSS_BASE	EQU 0xB000

	INCLUDE "netcfg_lib.asm"
	DEFINE WCOMMON_USE_NETCFG
	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "esp_tcp.asm"
	INCLUDE "esp_udp.asm"
	INCLUDE "esplib.asm"

	MODULE MAIN

; Runtime-only buffers/state, placed after the TCP/UDP helper BSS so nothing
; overlaps the UDP command/receive scratch.
NUM_BUFF	EQU UDP.UDP_BSS_END		; UTOA scratch (8)
SOCKET_OPEN	EQU NUM_BUFF + 8		; 1
RECV_LEN	EQU SOCKET_OPEN + 1		; 2
NTP_REQUEST	EQU RECV_LEN + 2		; 48
RECV_BUFFER	EQU NTP_REQUEST + 48		; RECV_BUFFER_SIZE
NTP_TX_SECS	EQU RECV_BUFFER + RECV_BUFFER_SIZE	; 4 (BE seconds since 1900)
WORK_SECS	EQU NTP_TX_SECS + 4		; 4
SAVE_SECS	EQU WORK_SECS + 4		; 4
UTC_BACKUP	EQU SAVE_SECS + 4		; 4
TMP_SECS	EQU UTC_BACKUP + 4		; 4
TZ_NEG		EQU TMP_SECS + 4		; 1
TZ_HOURS	EQU TZ_NEG + 1			; 1
TZ_MINS		EQU TZ_HOURS + 1		; 1
PARSED_YEAR	EQU TZ_MINS + 1			; 2
PARSED_MONTH	EQU PARSED_YEAR + 2		; 1
PARSED_DAY	EQU PARSED_MONTH + 1		; 1
PARSED_HOUR	EQU PARSED_DAY + 1		; 1
PARSED_MINUTE	EQU PARSED_HOUR + 1		; 1
PARSED_SECOND	EQU PARSED_MINUTE + 1		; 1
NTP_BSS_END	EQU PARSED_SECOND + 1

	ENDMODULE

	END MAIN.START

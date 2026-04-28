; ======================================================
; Shared NET.CFG parser for Sprinter DSS Network Kit
; ======================================================

	IFNDEF _NETCFG
	DEFINE _NETCFG

	MODULE NETCFG

CFG_BUFF_SIZE	EQU 2048
DSS_CREATE_OVERWRITE	EQU 0x0A

; ------------------------------------------------------
; Load NET.CFG from current directory and parse it.
; Out: CF=0 - loaded and parsed
;      CF=1 - DSS error in A, defaults remain active
; ------------------------------------------------------
LOAD
	CALL	SET_DEFAULTS

	LD	HL,CFG_FILE
	LD	A,FM_READ
	LD	C,DSS_OPEN_FILE
	RST	DSS
	RET	C

	LD	(CFG_FH),A
	LD	HL,CFG_BUFF
	LD	DE,CFG_BUFF_SIZE-1
	LD	C,DSS_READ_FILE
	RST	DSS
	JR	C,.READ_ERROR

	; Zero-terminate at actual read size.
	LD	HL,CFG_BUFF
	ADD	HL,DE
	LD	(HL),0

	LD	A,(CFG_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	RET	C

	LD	HL,CFG_BUFF
	CALL	PARSE
	XOR	A
	RET

.READ_ERROR
	PUSH	AF
	LD	A,(CFG_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	POP	AF
	SCF
	RET

; ------------------------------------------------------
; Save current config values to NET.CFG.
; Out: CF=0 - saved
;      CF=1 - DSS error in A
; ------------------------------------------------------
SAVE
	CALL	BUILD_SAVE_BUFFER
	PUSH	HL
	LD	HL,CFG_FILE
	LD	C,DSS_CREATE_OVERWRITE
	RST	DSS
	POP	HL
	RET	C

	LD	(CFG_FH),A

	LD	DE,CFG_BUFF
	AND	A
	SBC	HL,DE
	EX	DE,HL						; DE = length

	LD	A,(CFG_FH)
	LD	HL,CFG_BUFF
	LD	C,DSS_WRITE
	RST	DSS
	JR	C,.WRITE_ERROR

	LD	A,(CFG_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	RET

.WRITE_ERROR
	PUSH	AF
	LD	A,(CFG_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	POP	AF
	SCF
	RET

; ------------------------------------------------------
; Set safe default values.
; ------------------------------------------------------
SET_DEFAULTS
	LD	HL,EMPTY
	LD	DE,CFG_SSID
	LD	B,CFG_SSID_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,EMPTY
	LD	DE,CFG_PASS
	LD	B,CFG_PASS_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,DEFAULT_DHCP
	LD	DE,CFG_DHCP
	LD	B,CFG_FLAG_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,EMPTY
	LD	DE,CFG_IP
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,EMPTY
	LD	DE,CFG_GATEWAY
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,EMPTY
	LD	DE,CFG_NETMASK
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,DEFAULT_DNS1
	LD	DE,CFG_DNS1
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,DEFAULT_DNS2
	LD	DE,CFG_DNS2
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,DEFAULT_TZ
	LD	DE,CFG_TZ
	LD	B,CFG_TZ_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,DEFAULT_NTP
	LD	DE,CFG_NTP
	LD	B,CFG_NTP_SIZE
	CALL	COPY_ASCIIZ

	LD	HL,DEFAULT_AUTOJOIN
	LD	DE,CFG_AUTOJOIN
	LD	B,CFG_FLAG_SIZE
	JP	COPY_ASCIIZ

; ------------------------------------------------------
; Parse zero-ended config buffer.
; In: HL - buffer
; ------------------------------------------------------
PARSE
.LINE
	CALL	SKIP_LINE_PREFIX
	LD	A,(HL)
	AND	A
	RET	Z
	CP	13
	JR	Z,.NEXT_CHAR
	CP	10
	JR	Z,.NEXT_CHAR
	CP	'#'
	JR	Z,.SKIP_LINE

	LD	DE,KEY_SSID
	CALL	@UTIL.STARTSWITH
	JP	Z,.SSID
	LD	DE,KEY_PASS
	CALL	@UTIL.STARTSWITH
	JP	Z,.PASS
	LD	DE,KEY_DHCP
	CALL	@UTIL.STARTSWITH
	JP	Z,.DHCP
	LD	DE,KEY_IP
	CALL	@UTIL.STARTSWITH
	JP	Z,.IP
	LD	DE,KEY_GATEWAY
	CALL	@UTIL.STARTSWITH
	JP	Z,.GATEWAY
	LD	DE,KEY_NETMASK
	CALL	@UTIL.STARTSWITH
	JP	Z,.NETMASK
	LD	DE,KEY_DNS1
	CALL	@UTIL.STARTSWITH
	JP	Z,.DNS1
	LD	DE,KEY_DNS2
	CALL	@UTIL.STARTSWITH
	JP	Z,.DNS2
	LD	DE,KEY_TZ
	CALL	@UTIL.STARTSWITH
	JP	Z,.TZ
	LD	DE,KEY_NTP
	CALL	@UTIL.STARTSWITH
	JP	Z,.NTP
	LD	DE,KEY_AUTOJOIN
	CALL	@UTIL.STARTSWITH
	JP	Z,.AUTOJOIN

.SKIP_LINE
	CALL	SKIP_TO_NEXT_LINE
	JR	.LINE

.NEXT_CHAR
	INC	HL
	JR	.LINE

.SSID
	LD	BC,5
	ADD	HL,BC
	LD	DE,CFG_SSID
	LD	B,CFG_SSID_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.PASS
	LD	BC,5
	ADD	HL,BC
	LD	DE,CFG_PASS
	LD	B,CFG_PASS_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.DHCP
	LD	BC,5
	ADD	HL,BC
	LD	DE,CFG_DHCP
	LD	B,CFG_FLAG_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.IP
	LD	BC,3
	ADD	HL,BC
	LD	DE,CFG_IP
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.GATEWAY
	LD	BC,8
	ADD	HL,BC
	LD	DE,CFG_GATEWAY
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.NETMASK
	LD	BC,8
	ADD	HL,BC
	LD	DE,CFG_NETMASK
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.DNS1
	LD	BC,5
	ADD	HL,BC
	LD	DE,CFG_DNS1
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_VALUE
	JR	.SKIP_LINE
.DNS2
	LD	BC,5
	ADD	HL,BC
	LD	DE,CFG_DNS2
	LD	B,CFG_ADDR_SIZE
	CALL	COPY_VALUE
	JP	.SKIP_LINE
.TZ
	LD	BC,3
	ADD	HL,BC
	LD	DE,CFG_TZ
	LD	B,CFG_TZ_SIZE
	CALL	COPY_VALUE
	JP	.SKIP_LINE
.NTP
	LD	BC,4
	ADD	HL,BC
	LD	DE,CFG_NTP
	LD	B,CFG_NTP_SIZE
	CALL	COPY_VALUE
	JP	.SKIP_LINE
.AUTOJOIN
	LD	BC,9
	ADD	HL,BC
	LD	DE,CFG_AUTOJOIN
	LD	B,CFG_FLAG_SIZE
	CALL	COPY_VALUE
	JP	.SKIP_LINE

; ------------------------------------------------------
; Skip leading spaces and tabs on a line.
; ------------------------------------------------------
SKIP_LINE_PREFIX
	LD	A,(HL)
	CP	' '
	JR	Z,.SKIP
	CP	9
	RET	NZ
.SKIP
	INC	HL
	JR	SKIP_LINE_PREFIX

; ------------------------------------------------------
; Move HL to next line or string end.
; ------------------------------------------------------
SKIP_TO_NEXT_LINE
	LD	A,(HL)
	AND	A
	RET	Z
	INC	HL
	CP	10
	RET	Z
	JR	SKIP_TO_NEXT_LINE

; ------------------------------------------------------
; Copy ASCIIZ from HL to DE. B is destination size including zero.
; ------------------------------------------------------
COPY_ASCIIZ
	DEC	B
.NEXT
	LD	A,(HL)
	AND	A
	JR	Z,.END
	LD	(DE),A
	INC	HL
	INC	DE
	DJNZ	.NEXT
.END
	XOR	A
	LD	(DE),A
	RET

; ------------------------------------------------------
; Copy config value from HL to DE. B is destination size including zero.
; Stops at CR, LF, # or string end.
; ------------------------------------------------------
COPY_VALUE
	DEC	B
.NEXT
	LD	A,(HL)
	AND	A
	JR	Z,.END
	CP	13
	JR	Z,.END
	CP	10
	JR	Z,.END
	CP	'#'
	JR	Z,.END
	LD	(DE),A
	INC	HL
	INC	DE
	DJNZ	.NEXT
.END
	XOR	A
	LD	(DE),A
	RET

; ------------------------------------------------------
; Build NET.CFG text in CFG_BUFF.
; Out: HL - end of data
; ------------------------------------------------------
BUILD_SAVE_BUFFER
	LD	HL,CFG_BUFF

	LD	DE,SAVE_HEADER
	CALL	APPEND_STR

	LD	DE,KEY_SSID
	LD	IX,CFG_SSID
	CALL	APPEND_FIELD

	LD	DE,KEY_PASS
	LD	IX,CFG_PASS
	CALL	APPEND_FIELD

	LD	DE,KEY_DHCP
	LD	IX,CFG_DHCP
	CALL	APPEND_FIELD

	LD	DE,KEY_IP
	LD	IX,CFG_IP
	CALL	APPEND_FIELD

	LD	DE,KEY_GATEWAY
	LD	IX,CFG_GATEWAY
	CALL	APPEND_FIELD

	LD	DE,KEY_NETMASK
	LD	IX,CFG_NETMASK
	CALL	APPEND_FIELD

	LD	DE,KEY_DNS1
	LD	IX,CFG_DNS1
	CALL	APPEND_FIELD

	LD	DE,KEY_DNS2
	LD	IX,CFG_DNS2
	CALL	APPEND_FIELD

	LD	DE,KEY_TZ
	LD	IX,CFG_TZ
	CALL	APPEND_FIELD

	LD	DE,KEY_NTP
	LD	IX,CFG_NTP
	CALL	APPEND_FIELD

	LD	DE,KEY_AUTOJOIN
	LD	IX,CFG_AUTOJOIN
	CALL	APPEND_FIELD
	RET

; ------------------------------------------------------
; Append key in DE, value in IX and CRLF to buffer at HL.
; Out: HL - new end
; ------------------------------------------------------
APPEND_FIELD
	CALL	APPEND_STR
	CALL	APPEND_IX_STR
	JP	APPEND_CRLF

; ------------------------------------------------------
; Append ASCIIZ from DE to buffer at HL.
; Out: HL - new end
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
; Out: HL - new end
; ------------------------------------------------------
APPEND_IX_STR
	LD	A,(IX+0)
	AND	A
	RET	Z
	LD	(HL),A
	INC	HL
	INC	IX
	JR	APPEND_IX_STR

APPEND_CRLF
	LD	(HL),13
	INC	HL
	LD	(HL),10
	INC	HL
	RET

CFG_FILE	DB "NET.CFG",0
EMPTY		DB 0

DEFAULT_DHCP		DB "1",0
DEFAULT_DNS1		DB "1.1.1.1",0
DEFAULT_DNS2		DB "8.8.8.8",0
DEFAULT_TZ		DB "+6",0
DEFAULT_NTP		DB "pool.ntp.org",0
DEFAULT_AUTOJOIN	DB "1",0

KEY_SSID	DB "SSID=",0
KEY_PASS	DB "PASS=",0
KEY_DHCP	DB "DHCP=",0
KEY_IP		DB "IP=",0
KEY_GATEWAY	DB "GATEWAY=",0
KEY_NETMASK	DB "NETMASK=",0
KEY_DNS1	DB "DNS1=",0
KEY_DNS2	DB "DNS2=",0
KEY_TZ		DB "TZ=",0
KEY_NTP		DB "NTP=",0
KEY_AUTOJOIN	DB "AUTOJOIN=",0

SAVE_HEADER
	DB "# Sprinter DSS Network Kit configuration",13,10
	DB "# Password is stored in clear text.",13,10,0

CFG_SSID_SIZE		EQU 33
CFG_PASS_SIZE		EQU 65
CFG_FLAG_SIZE		EQU 2
CFG_ADDR_SIZE		EQU 16
CFG_TZ_SIZE		EQU 6
CFG_NTP_SIZE		EQU 64

CFG_FH		DB 0
CFG_SSID	DS CFG_SSID_SIZE,0
CFG_PASS	DS CFG_PASS_SIZE,0
CFG_DHCP	DS CFG_FLAG_SIZE,0
CFG_IP		DS CFG_ADDR_SIZE,0
CFG_GATEWAY	DS CFG_ADDR_SIZE,0
CFG_NETMASK	DS CFG_ADDR_SIZE,0
CFG_DNS1	DS CFG_ADDR_SIZE,0
CFG_DNS2	DS CFG_ADDR_SIZE,0
CFG_TZ		DS CFG_TZ_SIZE,0
CFG_NTP		DS CFG_NTP_SIZE,0
CFG_AUTOJOIN	DS CFG_FLAG_SIZE,0

CFG_BUFF	DS CFG_BUFF_SIZE,0

	ENDMODULE

	ENDIF

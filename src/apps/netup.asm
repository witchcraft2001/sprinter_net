; ======================================================
; NETUP for Sprinter DSS Network Kit
; Bring SprinterESP Wi-Fi connection up from NET.CFG.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
JOIN_TIMEOUT		EQU 30000

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

	CALL	NETCFG.LOAD
	JR	NC,.CFG_LOADED
	CP	E_FILE_NOT_FOUND
	JR	NZ,.DSS_ERROR
	PRINTLN MSG_NO_CFG
	LD	B,4
	JP	WCOMMON.EXIT

.DSS_ERROR
	CALL	PRINT_CONFIG_DSS_ERROR
	LD	B,4
	JP	WCOMMON.EXIT

.CFG_LOADED
	LD	A,(NETCFG.CFG_SSID)
	AND	A
	JR	NZ,.HAVE_SSID
	PRINTLN MSG_NO_SSID
	LD	B,4
	JP	WCOMMON.EXIT

.HAVE_SSID
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

	PRINTLN MSG_STATION
	LD	HL,CMD_CWMODE_CUR
	LD	DE,CMD_CWMODE_LEGACY
	CALL	SEND_CMD_WITH_FALLBACK

	PRINTLN MSG_NO_SLEEP
	LD	HL,CMD_SLEEP_OFF
	CALL	SEND_CMD

	CALL	APPLY_IP_MODE

	PRINT MSG_JOINING
	PRINT NETCFG.CFG_SSID
	PRINT WCOMMON.LINE_END
	CALL	BUILD_CWJAP_CMD_CUR
	LD	HL,CMD_BUFF
	LD	BC,JOIN_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	JR	Z,.JOINED
	PRINTLN MSG_FALLBACK
	CALL	BUILD_CWJAP_CMD_LEGACY
	LD	HL,CMD_BUFF
	LD	BC,JOIN_TIMEOUT
	CALL	SEND_CMD_TIMEOUT
.JOINED

	CALL	APPLY_DNS_OPTIONAL

	PRINTLN MSG_IP_INFO
	CALL	PRINT_IP_INFO_OPTIONAL

	PRINTLN MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Print NET.CFG DSS load error without letting DSS_ERROR.EPRINT choose the exit
; status. NETUP uses status 4 for all configuration problems.
; In: A - DSS error code.
; ------------------------------------------------------
PRINT_CONFIG_DSS_ERROR
	PUSH	AF
	PRINT	MSG_CFG_DSS_ERROR
	POP	AF
	CALL	DSS_ERROR.GET_ERR_MSG
	PRINTLN_HL
	RET

; ------------------------------------------------------
; Apply DHCP or static station IP mode.
; ------------------------------------------------------
APPLY_IP_MODE
	LD	A,(NETCFG.CFG_DHCP)
	CP	'0'
	JR	Z,.STATIC

	PRINTLN MSG_DHCP
	LD	HL,CMD_DHCP_ON
	LD	DE,CMD_DHCP_ON_LEGACY
	JP	SEND_CMD_WITH_FALLBACK

.STATIC
	PRINTLN MSG_STATIC
	CALL	BUILD_CIPSTA_CMD_CUR
	LD	HL,CMD_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	RET	Z
	PRINTLN MSG_FALLBACK
	CALL	BUILD_CIPSTA_CMD_LEGACY
	LD	HL,CMD_BUFF
	JP	SEND_CMD

; ------------------------------------------------------
; Apply DNS if DNS1 is configured. DNS setup is not mandatory because ESP-AT
; command variants differ between firmware builds.
; ------------------------------------------------------
APPLY_DNS_OPTIONAL
	LD	A,(NETCFG.CFG_DNS1)
	AND	A
	RET	Z
	PRINTLN MSG_DNS
	CALL	BUILD_CIPDNS_CMD_CUR
	LD	HL,CMD_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	RET	Z
	PRINTLN MSG_FALLBACK
	CALL	BUILD_CIPDNS_CMD_LEGACY
	LD	HL,CMD_BUFF
	CALL	SEND_CMD_OPTIONAL
	RET

; ------------------------------------------------------
; Send command in HL with default timeout.
; ------------------------------------------------------
SEND_CMD
	LD	BC,DEFAULT_TIMEOUT
	JP	SEND_CMD_TIMEOUT

SEND_CMD_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	RET	Z
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL with timeout in BC.
; Out: A = ESP result code, 0 means OK.
; ------------------------------------------------------
SEND_CMD_STATUS_TIMEOUT
	LD	DE,WIFI.RS_BUFF
	CALL	WIFI.UART_TX_CMD
	RET

; ------------------------------------------------------
; Send primary command in HL. If it fails, send fallback command in DE.
; ------------------------------------------------------
SEND_CMD_WITH_FALLBACK
	PUSH	DE
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	JR	Z,.OK
	POP	HL
	PRINTLN MSG_FALLBACK
	JP	SEND_CMD
.OK
	POP	DE
	RET

; ------------------------------------------------------
; Send non-critical command. Print a warning and continue on failure.
; ------------------------------------------------------
SEND_CMD_OPTIONAL
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	ADD	A,'0'
	LD	(MSG_WARN_NO),A
	PRINTLN MSG_OPTIONAL_WARN
	RET

; ------------------------------------------------------
; Send command in HL and print response buffer.
; ------------------------------------------------------
SEND_CMD_PRINT
	CALL	SEND_CMD
	LD	HL,WIFI.RS_BUFF
	JP	PRINT_ESP_RESPONSE

; ------------------------------------------------------
; Print station IP information. This is diagnostic only, so try several ESP-AT
; variants and warn only if every query fails.
; ------------------------------------------------------
PRINT_IP_INFO_OPTIONAL
	LD	HL,CMD_CIFSR
	CALL	SEND_CMD_PRINT_STATUS
	AND	A
	RET	Z
	LD	HL,CMD_CIPSTA_CUR_QUERY
	CALL	SEND_CMD_PRINT_STATUS
	AND	A
	RET	Z
	LD	HL,CMD_CIPSTA_QUERY
	CALL	SEND_CMD_PRINT_STATUS
	AND	A
	RET	Z
	ADD	A,'0'
	LD	(MSG_WARN_NO),A
	PRINTLN MSG_OPTIONAL_WARN
	RET

; ------------------------------------------------------
; Send command in HL and print response on success.
; Out: A = ESP result code, 0 means response was printed.
; ------------------------------------------------------
SEND_CMD_PRINT_STATUS
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	NZ
.PRINT
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE
	XOR	A
	RET

; ------------------------------------------------------
; Send command in HL. If ESP does not answer, reset once and retry.
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
; Build AT+CWJAP_CUR command from config.
; ------------------------------------------------------
BUILD_CWJAP_CMD_CUR
	LD	DE,CMD_CWJAP_CUR_PREFIX
	JR	BUILD_CWJAP_CMD

; ------------------------------------------------------
; Build legacy AT+CWJAP command from config.
; ------------------------------------------------------
BUILD_CWJAP_CMD_LEGACY
	LD	DE,CMD_CWJAP_LEGACY_PREFIX

BUILD_CWJAP_CMD
	LD	HL,CMD_BUFF
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_SSID
	CALL	APPEND_IX_STR
	LD	DE,CMD_CWJAP_MIDDLE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_PASS
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ------------------------------------------------------
; Build AT+CIPSTA_CUR command from config.
; ------------------------------------------------------
BUILD_CIPSTA_CMD_CUR
	LD	DE,CMD_CIPSTA_CUR_PREFIX
	JR	BUILD_CIPSTA_CMD

; ------------------------------------------------------
; Build legacy AT+CIPSTA command from config.
; ------------------------------------------------------
BUILD_CIPSTA_CMD_LEGACY
	LD	DE,CMD_CIPSTA_LEGACY_PREFIX

BUILD_CIPSTA_CMD
	LD	HL,CMD_BUFF
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_IP
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_COMMA_QUOTE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_GATEWAY
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_COMMA_QUOTE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_NETMASK
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ------------------------------------------------------
; Build AT+CIPDNS_CUR command from config.
; ------------------------------------------------------
BUILD_CIPDNS_CMD_CUR
	LD	DE,CMD_CIPDNS_CUR_PREFIX
	JR	BUILD_CIPDNS_CMD

; ------------------------------------------------------
; Build legacy AT+CIPDNS command from config.
; ------------------------------------------------------
BUILD_CIPDNS_CMD_LEGACY
	LD	DE,CMD_CIPDNS_LEGACY_PREFIX

BUILD_CIPDNS_CMD
	LD	HL,CMD_BUFF
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_DNS1
	CALL	APPEND_IX_STR
	LD	A,(NETCFG.CFG_DNS2)
	AND	A
	JR	Z,.END
	LD	DE,CMD_QUOTE_COMMA_QUOTE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_DNS2
	CALL	APPEND_IX_STR
.END
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

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

PUT_CHAR
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	RET

MSG_START
	DB "NETUP - bring SprinterESP network up",0
MSG_NO_CFG
	DB "NET.CFG not found. Run NETCFG /W first.",0
MSG_NO_SSID
	DB "SSID is empty. Run NETCFG /W first.",0
MSG_CFG_DSS_ERROR
	DB "NET.CFG error: ",0
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
MSG_STATION
	DB "Setting station mode.",0
MSG_NO_SLEEP
	DB "Disabling ESP sleep.",0
MSG_DHCP
	DB "Enabling DHCP.",0
MSG_STATIC
	DB "Applying static IP settings.",0
MSG_DNS
	DB "Applying DNS settings (optional).",0
MSG_FALLBACK
	DB "Primary ESP command failed, trying fallback.",0
MSG_JOINING
	DB "Connecting to SSID: ",0
MSG_IP_INFO
	DB "IP information:",0
MSG_DONE
	DB "NETUP done.",0
MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0
MSG_OPTIONAL_WARN
	DB "Optional ESP command failed #"
MSG_WARN_NO
	DB "n, continuing.",0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_CWMODE_CUR
	DB "AT+CWMODE_CUR=1",13,10,0
CMD_CWMODE_LEGACY
	DB "AT+CWMODE=1",13,10,0
CMD_SLEEP_OFF
	DB "AT+SLEEP=0",13,10,0
CMD_DHCP_ON
	DB "AT+CWDHCP_CUR=1,1",13,10,0
CMD_DHCP_ON_LEGACY
	DB "AT+CWDHCP=1,1",13,10,0
CMD_CIFSR
	DB "AT+CIFSR",13,10,0
CMD_CIPSTA_CUR_QUERY
	DB "AT+CIPSTA_CUR?",13,10,0
CMD_CIPSTA_QUERY
	DB "AT+CIPSTA?",13,10,0

CMD_CWJAP_CUR_PREFIX
	DB "AT+CWJAP_CUR=",34,0
CMD_CWJAP_LEGACY_PREFIX
	DB "AT+CWJAP=",34,0
CMD_CWJAP_MIDDLE
	DB 34,",",34,0
CMD_CIPSTA_CUR_PREFIX
	DB "AT+CIPSTA_CUR=",34,0
CMD_CIPSTA_LEGACY_PREFIX
	DB "AT+CIPSTA=",34,0
CMD_CIPDNS_CUR_PREFIX
	DB "AT+CIPDNS_CUR=1,",34,0
CMD_CIPDNS_LEGACY_PREFIX
	DB "AT+CIPDNS=1,",34,0
CMD_QUOTE_COMMA_QUOTE
	DB 34,",",34,0
CMD_QUOTE_CRLF
	DB 34,13,10,0

CMD_BUFF
	DS 256,0

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

	END MAIN.START

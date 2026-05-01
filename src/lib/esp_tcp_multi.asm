; ======================================================
; ESP-AT multi-connection TCP helpers for Sprinter DSS Network Kit
; Include after esp_tcp.asm only in tools that require AT+CIPMUX=1.
; Single-connection tools should not include this file.
; ======================================================

	IFNDEF	_ESP_TCP_MULTI
	DEFINE	_ESP_TCP_MULTI

	MODULE TCP

; ------------------------------------------------------
; Open a TCP connection in ESP-AT multi-connection mode.
; In: A - link id, HL - host ASCIIZ, DE - port ASCIIZ.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; Caller must enable AT+CIPMUX=1 before using this routine.
; ------------------------------------------------------
OPEN_LINK
	LD	(LINK_ID),A
	LD	(PTR_HOST),HL
	LD	(PTR_PORT),DE
	LD	HL,0
	LD	(PAYLOAD_LEFT),HL
	XOR	A
	LD	(LSR_ACCUM),A

	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSTART_LINK_PREFIX
	CALL	APPEND_STR
	LD	A,(LINK_ID)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_CIPSTART_LINK_MIDDLE
	CALL	APPEND_STR
	LD	IX,(PTR_HOST)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CIPSTART_MIDDLE
	CALL	APPEND_STR
	LD	IX,(PTR_PORT)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CRLF
	CALL	APPEND_STR

	LD	HL,CMD_BUFFER
	LD	DE,WIFI.RS_BUFF
	LD	BC,TCP_OPEN_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	SCF
	RET

; ------------------------------------------------------
; Close a TCP link in ESP-AT multi-connection mode.
; In: A - link id.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
CLOSE_LINK
	LD	(LINK_ID),A
	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPCLOSE_LINK_PREFIX
	CALL	APPEND_STR
	LD	A,(LINK_ID)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_CRLF
	CALL	APPEND_STR
	LD	HL,CMD_BUFFER
	LD	DE,WIFI.RS_BUFF
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	SCF
	RET

; ------------------------------------------------------
; Send a raw TCP payload through a multi-connection link.
; In: A - link id, HL - payload, BC - payload length.
; Out: CF=0/A=0 on success, CF=1/A=result code on failure.
; ------------------------------------------------------
SEND_BUFFER_LINK
	CALL	START_SEND_BUFFER_LINK
	RET	C
	JP	WAIT_SEND_OK_LINK

; ------------------------------------------------------
; Send a raw TCP payload through a multi-connection link and return
; immediately after UART transmit.
; In: A - link id, HL - payload, BC - payload length.
; Out: CF=0/A=0 after bytes were accepted by the UART.
;      CF=1/A=result code on prompt/tx timeout.
; ------------------------------------------------------
SEND_BUFFER_LINK_NO_WAIT
	CALL	START_SEND_BUFFER_LINK
	RET

START_SEND_BUFFER_LINK
	LD	(LINK_ID),A
	LD	(SEND_PTR),HL
	LD	(SEND_LEN),BC

	LD	H,B
	LD	L,C
	LD	DE,NUM_BUFFER
	CALL	UTIL.UTOA

	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSEND_LINK_PREFIX
	CALL	APPEND_STR
	LD	A,(LINK_ID)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_COMMA
	CALL	APPEND_STR
	LD	DE,NUM_BUFFER
	CALL	APPEND_STR
	LD	DE,CMD_CRLF
	CALL	APPEND_STR

	CALL	WIFI.UART_EMPTY_RS
	LD	HL,CMD_BUFFER
	CALL	WIFI.UART_TX_STRING
	JR	C,.TX_TIMEOUT

	CALL	WAIT_PROMPT
	RET	C

	LD	HL,(SEND_PTR)
	LD	BC,(SEND_LEN)
	CALL	WIFI.UART_TX_BUFFER
	JR	C,.TX_TIMEOUT

	XOR	A
	RET

.TX_TIMEOUT
	LD	A,RES_TX_TIMEOUT
	SCF
	RET

; ------------------------------------------------------
; Receive one +IPD payload block in multi-connection mode.
; In: HL - destination buffer, BC - max stored bytes, DE - timeout ms.
; Out: CF=0/A=0/BC=stored bytes on success.
;      LAST_IPD_LINK contains the ESP-AT link id.
;      CF=1/A=result code on timeout or protocol error.
; Notes:
; - Caller must enable AT+CIPMUX=1.
; - This consumes the next link-aware +IPD block from any link. The caller
;   dispatches by LAST_IPD_LINK.
; ------------------------------------------------------
RECEIVE_ANY_LINK
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL

	CALL	ISA.ISA_OPEN
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.CONTINUE_PAYLOAD
	CALL	WAIT_IPD_HEADER
	JR	C,.DONE
	CALL	READ_IPD_LINK_LEN
	JR	C,.DONE
.CONTINUE_PAYLOAD
	CALL	READ_PAYLOAD
.DONE
	CALL	ISA.ISA_CLOSE
	RET

; ------------------------------------------------------
; Wait until ESP reports SEND OK in multi-connection mode.
; Link-id responses may include text around SEND OK/FAIL.
; ------------------------------------------------------
WAIT_SEND_OK_LINK
	CALL	READ_LINE
	RET	C
	LD	HL,MSG_SEND_OK
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.OK
	LD	HL,LINE_BUFFER
	LD	DE,MSG_SEND_OK
	CALL	LINE_CONTAINS
	JR	NC,.OK
	LD	HL,MSG_OK
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,WAIT_SEND_OK_LINK
	LD	HL,MSG_ERROR
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.ERROR
	LD	HL,MSG_FAIL
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.FAIL
	LD	HL,LINE_BUFFER
	LD	DE,MSG_FAIL
	CALL	LINE_CONTAINS
	JR	NC,.FAIL
	JR	WAIT_SEND_OK_LINK
.OK
	XOR	A
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET
.FAIL
	LD	A,RES_FAIL
	SCF
	RET

; ------------------------------------------------------
; Read decimal multi-connection +IPD link id and payload length until ':'.
; Expected ESP-AT forms with CIPDINFO=0:
;   +IPD,<link>,<len>:<data>
; With CIPDINFO=1, extra remote info after <len> is skipped:
;   +IPD,<link>,<len>,<ip>,<port>:<data>
; ------------------------------------------------------
READ_IPD_LINK_LEN
	CALL	READ_DEC_FIELD
	JR	C,.ERROR
	LD	A,L
	LD	(LAST_IPD_LINK),A
	LD	(PAYLOAD_LINK),A
	LD	A,(IPD_DELIM)
	CP	','
	JR	NZ,.ERROR
	CALL	READ_DEC_FIELD
	JR	C,.ERROR
	LD	(PAYLOAD_LEFT),HL
	LD	(LAST_IPD_LEN),HL
	LD	A,(IPD_DELIM)
	CP	':'
	JR	Z,.OK
	CP	','
	JR	NZ,.ERROR
.SKIP_REMOTE_INFO
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	CP	':'
	JR	NZ,.SKIP_REMOTE_INFO
.OK
	XOR	A
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET

; ------------------------------------------------------
; Read decimal field until ',' or ':'.
; Out: HL=value, IPD_DELIM=delimiter.
; Requires at least one digit before the delimiter; an empty field
; (e.g., a digit lost to UART overrun in "+IPD,1,N:") is rejected as
; RES_ERROR rather than silently returning 0 and routing payload to
; the wrong link.
; ------------------------------------------------------
READ_DEC_FIELD
	LD	HL,0
	XOR	A
	LD	(DEC_HAS_DIGIT),A
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	CP	','
	JR	Z,.DELIM
	CP	':'
	JR	Z,.DELIM
	CP	'0'
	JR	C,.ERROR
	CP	'9'+1
	JR	NC,.ERROR
	PUSH	AF
	LD	A,1
	LD	(DEC_HAS_DIGIT),A
	POP	AF
	SUB	'0'
	LD	E,A
	LD	D,0
	LD	B,H
	LD	C,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,BC
	ADD	HL,HL
	ADD	HL,DE
	JR	.NEXT
.DELIM
	LD	(IPD_DELIM),A
	LD	A,(DEC_HAS_DIGIT)
	AND	A
	JR	Z,.ERROR_EMPTY
	XOR	A
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
.ERROR
	LD	(IPD_BAD_CHAR),A
.ERROR_EMPTY
	LD	A,RES_ERROR
	SCF
	RET

; Append one ESP-AT link id digit to command buffer.
; In: A - link id, HL - destination end.
APPEND_LINK_ID
	ADD	A,'0'
	LD	(HL),A
	INC	HL
	XOR	A
	LD	(HL),A
	RET

; Return CF=0 when ASCIIZ string at HL contains ASCIIZ substring at DE.
LINE_CONTAINS
	LD	A,(HL)
	AND	A
	JR	Z,.NO
	PUSH	HL
	PUSH	DE
.CMP
	LD	A,(DE)
	AND	A
	JR	Z,.FOUND
	LD	C,A
	LD	A,(HL)
	AND	A
	JR	Z,.RESTORE_NO
	CP	C
	JR	NZ,.RESTORE_NEXT
	INC	HL
	INC	DE
	JR	.CMP
.FOUND
	POP	DE
	POP	HL
	AND	A
	RET
.RESTORE_NEXT
	POP	DE
	POP	HL
	INC	HL
	JR	LINE_CONTAINS
.RESTORE_NO
	POP	DE
	POP	HL
.NO
	SCF
	RET

CMD_CIPSTART_LINK_PREFIX
	DB	"AT+CIPSTART=",0
CMD_CIPSTART_LINK_MIDDLE
	DB	",",34,"TCP",34,",",34,0
CMD_CIPSEND_LINK_PREFIX
	DB	"AT+CIPSEND=",0
CMD_CIPCLOSE_LINK_PREFIX
	DB	"AT+CIPCLOSE=",0
CMD_COMMA
	DB	",",0

LINK_ID		DB 0
LAST_IPD_LINK	DB 0
PAYLOAD_LINK	DB 0
IPD_DELIM	DB 0
DEC_HAS_DIGIT	DB 0

	ENDMODULE

	ENDIF

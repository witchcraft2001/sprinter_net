; ======================================================
; Transfer throughput / speed reporting for Sprinter ESP Network Kit.
; Measures wall-clock seconds via DSS_SYSTIME (seconds-of-day) and prints a
; "<bytes> bytes in <secs> sec, <rate>" summary. Ported from the rtl8019a CLI
; utilities so wget/ftp report download speed consistently.
;
; Usage:
;   CALL TPUT.START                 ; just before the transfer (ISA closed)
;   ... transfer ...
;   LD HL,(bytes_lo) / LD DE,(bytes_hi)
;   CALL TPUT.REPORT                ; after the transfer (ISA closed)
;
; DSS calls (SYSTIME / PUTCHAR / PCHARS) need the ISA window CLOSED, so callers
; must invoke these with ISA closed. IX is preserved across SYSTIME.
; ======================================================

	IFNDEF	_TPUT_LIB
	DEFINE	_TPUT_LIB

	MODULE TPUT

; ------------------------------------------------------
; NOW: read DSS_SYSTIME and return wall-clock time as 24-bit seconds-of-day.
;   Out: B = high 8 bits, HL = low 16 bits. Trashes A,BC,DE,HL. IX preserved.
; ------------------------------------------------------
NOW
	PUSH	IX
	LD	C,DSS_SYSTIME
	RST	DSS
	; H = hours, L = minutes, B = seconds.
	PUSH	BC
	PUSH	HL
	XOR	A
	LD	(SCRATCH+0),A
	LD	(SCRATCH+1),A
	LD	(SCRATCH+2),A
	POP	DE			; D = hours, E = minutes
	PUSH	DE
	LD	A,D
	OR	A
	JR	Z,.SKIP_HH
	LD	B,A
.HH_LP
	LD	HL,(SCRATCH)
	LD	DE,3600
	ADD	HL,DE
	LD	(SCRATCH),HL
	JR	NC,.NCHH
	LD	A,(SCRATCH+2)
	INC	A
	LD	(SCRATCH+2),A
.NCHH
	DJNZ	.HH_LP
.SKIP_HH
	POP	DE			; D = hours, E = minutes
	LD	A,E
	OR	A
	JR	Z,.SKIP_MM
	LD	B,A
.MM_LP
	LD	HL,(SCRATCH)
	LD	DE,60
	ADD	HL,DE
	LD	(SCRATCH),HL
	JR	NC,.NCMM
	LD	A,(SCRATCH+2)
	INC	A
	LD	(SCRATCH+2),A
.NCMM
	DJNZ	.MM_LP
.SKIP_MM
	POP	BC			; B = seconds
	LD	HL,(SCRATCH)
	LD	D,0
	LD	E,B
	ADD	HL,DE
	LD	(SCRATCH),HL
	JR	NC,.NCSS
	LD	A,(SCRATCH+2)
	INC	A
	LD	(SCRATCH+2),A
.NCSS
	LD	HL,(SCRATCH)
	LD	A,(SCRATCH+2)
	LD	B,A
	POP	IX
	RET

; ------------------------------------------------------
; START: capture the current seconds-of-day. Call once before the transfer.
; ------------------------------------------------------
START
	CALL	NOW
	LD	(T_START),HL
	LD	A,B
	LD	(T_START+2),A
	RET

; ------------------------------------------------------
; REPORT: print "  <bytes> bytes in <secs> sec[, <rate>]".
;   In: DE = high word, HL = low word of bytes transferred.
; Trashes everything.
; ------------------------------------------------------
REPORT
	LD	(HBUF),HL
	LD	(HBUF+2),DE
	CALL	NOW			; current SOD -> B:HL
	; elapsed = current - start (24-bit).
	LD	DE,(T_START)
	LD	A,L
	SUB	E
	LD	L,A
	LD	A,H
	SBC	A,D
	LD	H,A
	LD	A,(T_START+2)
	LD	E,A
	LD	A,B
	SBC	A,E
	LD	B,A
	JR	NC,.NO_WRAP
	; crossed midnight: add 86400 (0x015180).
	LD	DE,0x5180
	ADD	HL,DE
	LD	A,B
	ADC	A,1
	LD	B,A
.NO_WRAP
	LD	(T_ELAPSED),HL
	LD	A,B
	LD	(T_ELAPSED+2),A

	PRINT	S_PREFIX
	LD	HL,(HBUF)
	LD	DE,(HBUF+2)
	CALL	PRINT_DEC_32
	PRINT	S_BYTES_IN
	LD	HL,(T_ELAPSED)
	LD	A,(T_ELAPSED+2)
	LD	E,A
	LD	D,0
	CALL	PRINT_DEC_32
	PRINT	S_SEC

	; rate: skip if elapsed too large (>18h) or zero.
	LD	A,(T_ELAPSED+2)
	OR	A
	JP	NZ,.NL_ONLY
	LD	A,(T_ELAPSED)
	LD	B,A
	LD	A,(T_ELAPSED+1)
	OR	B
	JP	Z,.NL_ONLY

	; B/s = bytes / elapsed (in place).
	LD	HL,(HBUF)
	LD	(SCRATCH),HL
	LD	HL,(HBUF+2)
	LD	(SCRATCH+2),HL
	LD	DE,(T_ELAPSED)
	CALL	DIV32_BY_DE

	PRINT	S_COMMA
	; >= 1024 B/s -> KB/s, else B/s.
	LD	A,(SCRATCH+3)
	OR	A
	JR	NZ,.RATE_KB
	LD	A,(SCRATCH+2)
	OR	A
	JR	NZ,.RATE_KB
	LD	A,(SCRATCH+1)
	CP	4
	JR	NC,.RATE_KB

	LD	HL,(SCRATCH)
	LD	DE,(SCRATCH+2)
	CALL	PRINT_DEC_32
	PRINT	S_BPS
	JR	.NL_ONLY
.RATE_KB
	; KB/s = quotient >> 10.
	LD	HL,(SCRATCH)
	LD	DE,(SCRATCH+2)
	LD	L,H
	LD	H,E
	LD	E,D
	LD	D,0
	SRL	E
	RR	H
	RR	L
	SRL	E
	RR	H
	RR	L
	CALL	PRINT_DEC_32
	PRINT	S_KBS
.NL_ONLY
	PRINT	S_NL
	RET

; ------------------------------------------------------
; PRINT_DEC_32: print 32-bit value (HL=low, DE=high) as unsigned decimal.
; ------------------------------------------------------
PRINT_DEC_32
	LD	(SCRATCH),HL
	LD	(SCRATCH+2),DE
	LD	A,(SCRATCH)
	LD	B,A
	LD	A,(SCRATCH+1)
	OR	B
	LD	B,A
	LD	A,(SCRATCH+2)
	OR	B
	LD	B,A
	LD	A,(SCRATCH+3)
	OR	B
	JR	NZ,.NZ
	LD	A,'0'
	LD	C,DSS_PUTCHAR
	RST	DSS
	RET
.NZ
	LD	B,0			; digit count
.LP
	CALL	.DIV32_10
	ADD	A,'0'
	PUSH	AF
	INC	B
	LD	A,(SCRATCH)
	LD	C,A
	LD	A,(SCRATCH+1)
	OR	C
	LD	C,A
	LD	A,(SCRATCH+2)
	OR	C
	LD	C,A
	LD	A,(SCRATCH+3)
	OR	C
	JR	NZ,.LP
.OUT
	POP	AF
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	DJNZ	.OUT
	RET

; .DIV32_10: SCRATCH(32-bit LE) /= 10 in place; A = remainder. Preserves B.
.DIV32_10
	PUSH	BC
	PUSH	DE
	LD	HL,0
	LD	B,32
.DLP
	PUSH	HL
	LD	HL,SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	ADC	HL,HL
	LD	DE,10
	OR	A
	SBC	HL,DE
	JR	NC,.DSUB
	ADD	HL,DE
	JR	.DNEXT
.DSUB
	PUSH	HL
	LD	HL,SCRATCH
	SET	0,(HL)
	POP	HL
.DNEXT
	DJNZ	.DLP
	LD	A,L
	POP	DE
	POP	BC
	RET

; ------------------------------------------------------
; DIV32_BY_DE: in-place 32-bit / 16-bit unsigned division.
;   Dividend: SCRATCH (4 bytes LE), replaced by quotient. Divisor: DE (>0).
;   Out: HL = remainder. DE preserved.
; ------------------------------------------------------
DIV32_BY_DE
	LD	HL,0
	LD	B,32
.LP
	PUSH	HL
	LD	HL,SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	ADC	HL,HL
	JR	C,.SUB_FORCE
	OR	A
	SBC	HL,DE
	JR	C,.NOSUB
	JR	.SET
.SUB_FORCE
	OR	A
	SBC	HL,DE
.SET
	PUSH	HL
	LD	HL,SCRATCH
	SET	0,(HL)
	POP	HL
	JR	.NEXT
.NOSUB
	ADD	HL,DE
.NEXT
	DJNZ	.LP
	RET

; ------------------------------------------------------
; PROGRESS: in-place download progress line "<dlKB>KB / <totalKB>KB".
; Emits 0x0D first so repeated calls overwrite the same line (on this console
; 0x0D resets the X column, 0x0A is the line feed). No trailing newline; the
; caller prints a real newline (LINE_END) once the transfer is done.
; In: HL = ptr to downloaded byte count (4-byte LE),
;     DE = ptr to total byte count   (4-byte LE; all-zero -> shown as "?").
; Trashes everything.
; ------------------------------------------------------
PROGRESS
	; Rendering (two 32-bit divides + ~15 chars) is far slower than the old single
	; dot and, run every chunk, would stall the UART read long enough to overrun
	; the 16-byte RX FIFO. So pause ESP TX (drop RTS) around the render: the ESP
	; holds off while we are not reading, and resumes after. UART_RX_PAUSE/RESUME
	; preserve HL/DE. MUST return CF=0 — callers propagate CF as success/fail.
	CALL	@WIFI.UART_RX_PAUSE
	CALL	.RENDER
	CALL	@WIFI.UART_RX_RESUME
	OR	A			; CF=0 (success)
	RET
.RENDER
	PUSH	DE			; total ptr
	LD	A,0x0D			; reset X to column 0 (this console: 0x0D=CR, 0x0A=LF)
	LD	C,DSS_PUTCHAR
	RST	DSS
	CALL	.KB_AT_HL		; downloaded KB
	LD	HL,S_PROG_MID		; "KB / "
	CALL	.PUTS
	POP	HL			; total ptr
	LD	A,(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	DEC	HL
	DEC	HL
	DEC	HL
	JR	NZ,.HAVE_TOTAL
	LD	A,'?'			; total unknown
	LD	C,DSS_PUTCHAR
	RST	DSS
	JR	.TAIL
.HAVE_TOTAL
	CALL	.KB_AT_HL		; total KB
.TAIL
	LD	HL,S_PROG_KB		; "KB"
	JP	.PUTS

; Print the 4-byte LE value at (HL) divided by 1024 (i.e. in KB).
.KB_AT_HL
	LD	DE,SCRATCH
	LD	BC,4
	LDIR
	LD	DE,1024
	CALL	DIV32_BY_DE
	LD	HL,(SCRATCH)
	LD	DE,(SCRATCH+2)
	JP	PRINT_DEC_32

.PUTS
	LD	A,(HL)
	AND	A
	RET	Z
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	INC	HL
	JR	.PUTS

S_PROG_MID	DB "KB / ",0
S_PROG_KB	DB "KB",0

S_PREFIX	DB "  ",0
S_BYTES_IN	DB " bytes in ",0
S_SEC		DB " sec",0
S_COMMA		DB ", ",0
S_KBS		DB " KB/s",0
S_BPS		DB " B/s",0
S_NL		DB 13,10,0

; Small in-image scratch/state (not large runtime buffers).
T_START		DS 3,0
T_ELAPSED	DS 3,0
HBUF		DS 4,0
SCRATCH		DS 4,0

	ENDMODULE

	ENDIF

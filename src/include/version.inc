; ======================================================
; Sprinter ESP Network Kit package version.
; Keep this as the single source for banner version text.
; ======================================================

	IFNDEF	_VERSION_INC
	DEFINE	_VERSION_INC

PACKAGE_VERSION_MAJOR	EQU 0
PACKAGE_VERSION_MINOR	EQU 1

	; Emit "v.<major>.<minor>" built from the constants above, so the version
	; lives in exactly one place. Placed right after the tool name in each
	; banner, e.g. "FTP v.0.1 - ...". Assumes single-digit major/minor (the
	; +'0' turns each into its ASCII digit); revisit if a component reaches 10.
	; No surrounding spaces or trailing 0 - the banner supplies those.
	MACRO	PACKAGE_VERSION_TAG
	DB "v.", PACKAGE_VERSION_MAJOR+'0', ".", PACKAGE_VERSION_MINOR+'0'
	ENDM

	ENDIF

; ======================================================
; Sprinter DSS Network Kit package version.
; Keep this as the single source for banner version text.
; ======================================================

	IFNDEF	_VERSION_INC
	DEFINE	_VERSION_INC

PACKAGE_VERSION_MAJOR	EQU 0
PACKAGE_VERSION_MINOR	EQU 1

	MACRO	PACKAGE_VERSION_SUFFIX
	DB " package 0.1"
	ENDM

	ENDIF

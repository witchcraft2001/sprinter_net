;; unetll.s - register-marshaling trampoline for the UNET C binding.
;;
;; void unet_raw_call(u16 target, unet_regs *r);
;;   struct unet_regs { u8 a; u16 de; u16 ix; u16 iy; };  (offsets 0,1,3,5)
;;
;; Loads A/DE/IX/IY from *r, calls the DLL function at `target`, then stores the
;; returned A/DE/IX/IY back into *r. HL/BC are scratch (the libman convention
;; consumes them); IX/IY are saved for the C caller.

        .module unetll
        .globl  _unet_raw_call

        .area   _DATA
ut_target:  .ds 2
ut_rptr:    .ds 2
ut_iy:      .ds 2
ut_a:       .ds 1

        .area   _CODE

_unet_raw_call::
        push    ix
        push    iy
        ld      iy, #6          ; skip saved ix(2)+iy(2)+return(2)
        add     iy, sp
        ;; target
        ld      l, 0 (iy)
        ld      h, 1 (iy)
        ld      (ut_target), hl
        ;; r pointer
        ld      l, 2 (iy)
        ld      h, 3 (iy)
        ld      (ut_rptr), hl
        ;; load inputs from *r (HL = r)
        ld      a, (hl)         ; +0 a
        ld      (ut_a), a
        inc     hl
        ld      e, (hl)         ; +1 de.l
        inc     hl
        ld      d, (hl)         ; +2 de.h
        inc     hl
        ld      c, (hl)         ; +3 ix.l
        inc     hl
        ld      b, (hl)         ; +4 ix.h
        inc     hl
        ld      a, (hl)         ; +5 iy.l
        ld      (ut_iy), a
        inc     hl
        ld      a, (hl)         ; +6 iy.h
        ld      (ut_iy + 1), a
        push    bc
        pop     ix              ; IX = input ix
        ld      iy, (ut_iy)     ; IY = input iy
        ld      a, (ut_a)       ; A  = input a  (DE already loaded)
        ld      hl, (ut_target)
        call    jphl            ; call DLL function; returns here
        ;; capture outputs before they are clobbered
        ld      (ut_a), a       ; A
        push    ix
        pop     bc              ; BC = returned ix
        push    iy
        pop     hl
        ld      (ut_iy), hl     ; returned iy
        ;; store into *r (DE still holds the returned de)
        ld      hl, (ut_rptr)
        ld      a, (ut_a)
        ld      (hl), a         ; +0 a
        inc     hl
        ld      (hl), e         ; +1 de.l
        inc     hl
        ld      (hl), d         ; +2 de.h
        inc     hl
        ld      (hl), c         ; +3 ix.l
        inc     hl
        ld      (hl), b         ; +4 ix.h
        inc     hl
        ld      a, (ut_iy)
        ld      (hl), a         ; +5 iy.l
        inc     hl
        ld      a, (ut_iy + 1)
        ld      (hl), a         ; +6 iy.h
        pop     iy
        pop     ix
        ret

jphl:
        jp      (hl)

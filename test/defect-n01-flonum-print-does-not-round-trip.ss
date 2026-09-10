;; expect: #t
;; The flonum printer loses the value.  A number written and read back
;; is not the number that was written, from two significant digits
;; upward, and below about 1e-12 it is written as zero.
;;
;; This is the property everything else in this tree leans on without
;; saying so.  "Byte-for-byte identical across hosts" is checked by
;; comparing printed output, so it means "identical to twelve places
;; after the point" -- and since printing is not idempotent, it does
;; not even mean that stably.  A golden sample regenerated from a
;; previous golden sample drifts.
;;
;; The printer walks the fraction by repeated multiplication by ten,
;; stopping after twelve digits.  So:
;;   - the count is twelve places AFTER THE POINT, not twelve
;;     significant digits, and the significance available falls away
;;     as the magnitude does;
;;   - it truncates rather than rounds;
;;   - there is no exponent form, so a small number has nowhere to go
;;     but zero;
;;   - the repeated multiplication accumulates error into digits that
;;     are then printed as if they were exact.
;;
;; The integer part is a separate and correct path -- exact, through
;; bignums -- and the cells below say so, because a repair must not
;; break it and a reader should know which half is at issue.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; Printing and reading back, as one operation.
(define (round-trip v)
  (string->number (with-output-to-string (lambda () (write v)))))

;; EVERY ROW ANSWERS A BOOLEAN, and that is not a style choice.  The
;; thing under test is the printer, and a row that reported the two
;; values would report them THROUGH it: the first draft of this cell
;; printed `got 0.000000000009 want 0.000000000009' for a pair that
;; differs, because twelve places is not enough to show the
;; difference.  A judge that shares its printer with the accused
;; cannot describe the crime.  So the comparison is made in the
;; program, where the values are still whole, and only its answer is
;; printed.
(define (survives? v) (= (round-trip v) v))

;; CONTROL: the integer path is exact and must stay so.  A repair that
;; fixed the fraction by rewriting both would show up here.
(want 'n01-CONTROL-a-large-integral-flonum-survives (survives? 1e23) #t)
(want 'n01-CONTROL-and-a-small-one (survives? 536870913.0) #t)
;; CONTROL: one decimal place is fine, so the defect is not "printing
;; is broken" -- it is where the digits run out.
(want 'n01-CONTROL-one-decimal-place-survives (survives? 0.5) #t)
(want 'n01-CONTROL-and-a-tenth (survives? 0.1) #t)

;; THE DEFECT.  Two significant digits is enough.
(want 'n01-two-significant-digits-survive (survives? 0.12) #t)

;; A value below the twelfth place is printed as zero, so a non-zero
;; number reads back as nothing at all.  This is the worst of the
;; three, because a zero is a plausible value.
(want 'n01-a-small-value-does-not-become-zero (survives? 1e-12) #t)
(want 'n01-and-it-does-not-become-zero-in-particular
      (= 0.0 (round-trip 1e-12)) #f)
(want 'n01-nor-a-smaller-one (survives? 1e-20) #t)

;; And the digits are not merely short, they are wrong: the error the
;; repeated multiplication accumulates reaches past the last place.
(want 'n01-the-digits-printed-are-the-digits-of-the-value (survives? 1e-11) #t)

;; PRINTING IS NOT IDEMPOTENT.  Printing what was printed gives
;; something else again, so any chain that regenerates a recorded value
;; from a previous recording walks away from the number.
(want 'n01-printing-twice-is-printing-once
      (let ((once (round-trip 3.141592653589793)))
        (equal? (round-trip once) once))
      #t)

;; THIS CELL CAN GO GREEN, and that was checked rather than assumed.
;; A red cell's expectation is verified by nothing -- red is what a
;; defect cell is supposed to look like -- so one whose wanted answer
;; is unreachable stays red forever and goes on reading as evidence.
;; This file was run under the host Scheme, with nothing changed but
;; the import that supplies with-output-to-string:
;;
;;     chez --script <this file>   ->   #t
;;
;; So the four controls and the six defect rows are all satisfiable by
;; a correct printer, and a repair here has a colour to aim at.

(display (if (null? fails) #t (reverse fails)))

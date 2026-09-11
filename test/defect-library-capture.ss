;; expect: ((gem . 3))
;; A top-level definition reaches inside a library the program only
;; imported.
;;
;; REGRESSION GUARD (written as a red witness at e7fae5a; green since),
;; and this is the third spelling of one defect. The prelude, every
;; imported library, and the compiler's own synthesised operations are
;; all spliced into one flat top level and all call primitives by the
;; same bare symbols the user can define. namespace-library renames a
;; library's PRIVATE definitions; its references to imported primitives
;; are shared with everyone else.
;;
;; So a program that defines `car` changes what (gam inventory) does
;; six lines inside a procedure the program never reads.  Today:
;;
;;     unhandled exception: inventory-add!: not an inventory 99
;;
;; The library's own contract catches it, which is the only reason
;; there is a message at all -- the 99 walked in far enough to fail a
;; check the library wrote for a different purpose.  Without that check
;; it would have been a wrong answer.  Every library under lib/ has
;; the same shape in the same place, and most of them have no such
;; contract on the path.
;;
;; This is the case that says how big the defect is.  A user may
;; reasonably believe their own top level is theirs; that it reaches
;; into a library they merely imported is not a shadowing rule anyone
;; would expect to be told about.
;;
;; The other two spellings are test/defect-prelude-capture-car.ss and
;; test/defect-prelude-capture-null.ss.  The pair that a fix must NOT
;; break is test/prelude-capture-value-form.ss.
(import (except (rnrs) car) (gam inventory))
(define (car x) 99)
(define bag (make-inventory))
(inventory-add! bag 'gem 3)
(display (inventory-items bag))

;; WHERE THIS EXPECTATION COMES FROM.  A cell that is red today is a
;; cell whose expectation no run has ever produced, so nothing checks
;; that the expectation is reachable at all.  Tonight one of these
;; files could not have gone green even after its defect was fixed --
;; the wanted transcript was hand-written and was missing a trailing
;; space that the program always prints -- and its redness would have
;; gone on reading as "the defect is still there".
;;
;; So each of these carries a witness: the same program with the one
;; line that triggers the defect removed.  It is not a control in the
;; usual sense; it is the source of the number on the expect line.
;;
;; Measured, with that line removed:
;;
;;     (import (rnrs) (gam inventory))
;;     (define bag (make-inventory))
;;     (inventory-add! bag 'gem 3)
;;     (display (inventory-items bag))
;;
;;   ->  ((gem . 3))

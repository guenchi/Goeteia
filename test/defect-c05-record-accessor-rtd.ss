;; expect: refused
;; C05 (2026-09-06 review; written as a red witness at a52af3b, green
;; since): a record accessor checks the field layout and not the record
;; type.
;;
;; REGRESSION GUARD.  Today every target answers 7: `a-x` applied to a `b`
;; reads field 0 of a one-field record and hands it back, because the
;; generated accessor carries a field count and an index but not the
;; rtd it belongs to.  The predicate does check identity; the accessor
;; does not, so the two disagree about what a record of type `a` is.
;;
;; Two records with the same shape are exactly the case where a
;; caller most needs the check -- a position and a velocity, a health
;; and a mana -- and it is also the case where the wrong answer is a
;; plausible number rather than a crash.
;;
;; Reported location: src/compiler.ss:439-445,2879, src/js-backend.ss:947.
(import (rnrs))
(define-record-type a (fields x))
(define-record-type b (fields x))
(display (guard (e (#t 'refused)) (a-x (make-b 7))))

;; expect: #t
;; EXPECTED FAIL against lib/web/sexpr.ss at e8b0ae0.  A bare token with
;; a leading "+" is read as a SYMBOL where R6RS reads a NUMBER, and the
;; three that matter are the standard spellings of NaN and the
;; infinities -- exactly what a conforming writer emits for them.
;;
;;   Chez:  (write (list (/ 0. 0.) (/ 1. 0.) (- (/ 1. 0.))))
;;          => (+nan.0 +inf.0 -inf.0)
;;   here:  all three come back as SYMBOLS named "+nan.0" etc.
;;
;; THIS IS A WRONG VALUE, NOT A REFUSAL, which is what makes it worse
;; than the escape defect fixed in the same area.  A peer sends a NaN,
;; the reader answers a symbol, and nothing anywhere says a word.
;;
;; THE VALUE IS CARRYABLE, so this is the escape argument again rather
;; than a request to widen the format.  Measured: the writer emits a NaN
;; as #f8"AAAAAAAA+H8=" and reads it straight back.  So read-then-write
;; closes for these values -- the reader simply does not recognise the
;; OTHER spelling a conforming writer uses.
;;
;; Found by following a question from the peer implementation of this
;; format, which has the same hole: numeric-shape? catches a leading
;; digit or "-" followed by a digit, and nothing catches a leading "+".
;; Both trees inherited it.
;;
;; THE THREE SPECIALS AND THE INTEGER ARE DIFFERENT QUESTIONS and this
;; cell keeps them apart, because the first version of it did not and
;; over-asserted in exactly the way this tree spent the day catching.
;;
;; +15 IS NOT SETTLED EITHER, and I asserted the value 15 for it before
;; noticing that.  This reader does read integers and rationals, so
;; reading +15 as 15 is consistent -- but the WRITER never emits a
;; leading "+", so refusing it is equally consistent, narrow rather than
;; wide.  Two defensible answers again, and the row now asserts only
;; that it is not a SYMBOL.
;;
;; Recording how the row got there, because it happened twice in this
;; one cell: on finding a defect I wrote the repair I would have chosen
;; into the expectation.  That is the same failure as deriving an
;; expectation from an implementation, with my own preference standing
;; in for the implementation, and it is harder to see because the
;; expectation looks like a requirement rather than a guess.
;;
;; +nan.0 is NOT settled, and asserting a flonum for it would repeat
;; today's mistake of appealing to a standard the surrounding grammar
;; does not implement.  Measured: this reader refuses 1.5, 1e3 and #xFF.
;; It has NO flonum literal syntax at all, so reading +nan.0 as a flonum
;; while 1.5 stays refused would be incoherent -- the coherent readings
;; are either both or neither.  So those rows assert only what IS
;; settled: they must not come back as SYMBOLS.  A refusal, like the one
;; 1.5 already gets, satisfies them; a silent wrong value does not.
;;
;; The peer implementation of this format has TWO profiles and the same
;; hole in both, and its strict profile cannot carry a flonum at all, so
;; refusal is the only coherent answer there.  Ours carries flonums --
;; the writer emits #f8"..." and reads it back -- so both answers remain
;; open here.  What is NOT open is answering with a symbol.
(import (rnrs) (web sexpr))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (nth s i) (list-ref (string->sexpr s) i))
(define (nan? x) (and (flonum? x) (not (= x x))))
(define (posinf? x) (and (flonum? x) (fl<? 1e308 x)))
(define (neginf? x) (and (flonum? x) (fl<? x -1e308)))

;; EITHER answer is acceptable and only one is not.  A refusal, like the
;; one 1.5 already gets, is fine; reading the value is fine; coming back
;; as a SYMBOL is the defect.  Written this way on purpose -- demanding
;; a refusal specifically would go red on a repair that reads them,
;; which is the other legitimate end state.
(define (symbol-or-not src)
  (guard (e (#t 'not-a-symbol))
    (let ((v (nth src 1))) (if (symbol? v) (list 'SYMBOL v) 'not-a-symbol))))
;; the standard spellings a conforming writer emits
(want 'nan-must-not-be-a-symbol (symbol-or-not "(ok +nan.0)") 'not-a-symbol)
(want 'positive-infinity-must-not-be-a-symbol (symbol-or-not "(ok +inf.0)") 'not-a-symbol)
(want 'negative-infinity-must-not-be-a-symbol (symbol-or-not "(ok -inf.0)") 'not-a-symbol)
;; a leading + on an ordinary number is R6RS too
(want 'plus-prefixed-integer-must-not-be-a-symbol
      (symbol-or-not "(ok +15)") 'not-a-symbol)

;; THE CONTROL, and it must stay green: the readings that are already
;; right must not move.  A repair that widened the number parser too far
;; would take "+" or "+a" away from the symbols, and those ARE symbols
;; -- the writer writes both of them bare.
(want 'CONTROL-plain-integer (nth "(ok 15)" 1) 15)
(want 'CONTROL-negative-integer (nth "(ok -15)" 1) -15)
(want 'CONTROL-plus-is-a-symbol (symbol->string (nth "(ok +)" 1)) "+")
(want 'CONTROL-plus-a-is-a-symbol (symbol->string (nth "(ok +a)" 1)) "+a")
(want 'CONTROL-the-wire-flonum-form-still-reads
      (nan? (nth "(ok #f8\"AAAAAAAA+H8=\")" 1)) #t)

;; OBSERVED, not required: this reader has no flonum literal syntax, and
;; that is why the three rows above stop at "not a symbol".  Recorded as
;; a reading so the larger decision -- read these spellings as values,
;; and then 1.5 too, or refuse them as 1.5 already is -- is visible
;; rather than rediscovered.
(want 'OBSERVED-no-flonum-literal-syntax
      (list (symbol-or-not "(ok 1.5)") (symbol-or-not "(ok 1e3)"))
      (list 'not-a-symbol 'not-a-symbol))

(display (if (null? fails) #t fails))

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
;; THE ASSERTIONS ARE ON THE VALUE, not on "is not a symbol": a repair
;; that merely REFUSED these would stop the silent wrong answer and
;; still not read what the peer sent.
(import (rnrs) (web sexpr))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (nth s i) (list-ref (string->sexpr s) i))
(define (nan? x) (and (flonum? x) (not (= x x))))
(define (posinf? x) (and (flonum? x) (fl<? 1e308 x)))
(define (neginf? x) (and (flonum? x) (fl<? x -1e308)))

;; the standard spellings a conforming writer emits
(want 'nan-must-be-a-flonum (nan? (nth "(ok +nan.0)" 1)) #t)
(want 'positive-infinity (posinf? (nth "(ok +inf.0)" 1)) #t)
(want 'negative-infinity (neginf? (nth "(ok -inf.0)" 1)) #t)
;; a leading + on an ordinary number is R6RS too
(want 'plus-prefixed-integer (nth "(ok +15)" 1) 15)

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

(display (if (null? fails) #t fails))

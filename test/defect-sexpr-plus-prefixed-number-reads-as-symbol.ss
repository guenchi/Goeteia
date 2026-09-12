;; expect: #t
;; REGRESSION GUARD.  Written as a red witness against lib/web/sexpr.ss
;; at fdbd7c9, where there were two holes on the
;; bare-token path, ruled together with the peer implementation of this
;; wire format because a number parser widened on one side alone would
;; read a peer's token as a different TYPE than the peer meant.
;;
;; ONE: the standard spellings of NaN and the infinities read as
;; SYMBOLS.  A conforming writer emits exactly these for those values --
;; Chez's (write (list (/ 0. 0.) (/ 1. 0.) (- (/ 1. 0.)))) is
;; (+nan.0 +inf.0 -inf.0) -- so a peer sends a NaN and this reader
;; answers a symbol.  A WRONG VALUE, not a refusal, with nothing said.
;;
;; TWO: a leading "+" on any other token also makes a symbol, and the
;; writer refuses every one of those names, so the reader mints values
;; this implementation can hold and cannot serialise.  Cause: the
;; numeric test catches a leading digit, or "-" followed by a DIGIT, so
;; "+" slips and so does "-" before a non-digit.
;;
;; THE RULE, and it is narrower than "read R6RS numbers":
;;   - the bare token goes to the WRITER'S predicate, as the escaped
;;     path already does since e8b0ae0, so a name the writer cannot
;;     produce is not read.  That also ends a disagreement this tree
;;     introduced: bare +15 was a symbol while \x2B;15 was refused --
;;     same name, two spellings, two answers.
;;   - EXACTLY three spellings become flonums: +nan.0, +inf.0, -inf.0.
;;     Not -nan.0, which no conforming writer emits.  Not 1.5 or 1e3 or
;;     #xFF: this format's flonum spelling is the bit-exact #f8 form,
;;     and a decimal literal parser would bring back the class of
;;     hazard that external numeric text carries.
;;   - the number path is tried before the symbol path.
;;   - the writer does not change.
;;
;; So the widening is only ever "spellings of values this format already
;; carries", which is the same shape as the escape work: measured, the
;; writer emits a NaN as #f8"AAAAAAAA+H8=" and reads it straight back.
;;
;; FIXED, and the invariant is what made it right rather than merely
;; green.  The peer implementation wrote the same ruling as a LIST and a
;; third of the list was wrong; asking the writer at run time also
;; settled tokens nobody enumerated -- .5, -.5, +1/2 -- and it gets the
;; near-miss spellings right for free: +nan.00, +inf and inf.0 are NOT
;; numbers to a conforming reader, so the writer takes them, so the
;; reader must keep them as symbols.  Measured: all four agree.
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

;; THE SYMBOL HALF IS AN INVARIANT, NOT A LIST.  For any token: this
;; reader reads it as a SYMBOL if and only if the writer can write a
;; symbol of that name.  The writer is asked at RUN TIME rather than
;; copied into a table here, so the two cannot disagree and the rule
;; cannot contradict itself.
;;
;; Written this way because the peer implementation wrote the same
;; ruling as a list of spellings and a third of the list was wrong --
;; one token appeared in both the "must refuse" and the "stays a symbol"
;; table, two rows asserting opposite things about one input, red under
;; every possible implementation.  A list can contradict itself; an
;; invariant cannot.
;;
;; The marker for a refusal is deliberately NOT of a type the subject
;; can return: 'refused is compared with equal?, never with symbol?, so
;; a refusal is never mistaken for "it read a symbol".  Same peer lost
;; twelve rows to exactly that -- their refusal marker was a symbol and
;; their acceptance test was symbol?.
(define (reads-as-symbol? src)
  (guard (e (#t 'refused))
    (let ((v (nth src 1))) (if (symbol? v) 'symbol 'some-other-value))))
(define (writer-takes-name? name)
  (guard (e (#t #f)) (sexpr->string (list (string->symbol name))) #t))
(for-each
 (lambda (tok)
   (let ((read-sym? (eq? (reads-as-symbol? (string-append "(ok " tok ")")) 'symbol))
         (writable? (writer-takes-name? tok)))
     (unless (eq? read-sym? writable?)
       (want (string->symbol (string-append "invariant/" tok))
             (list 'reads-as-symbol read-sym? 'writer-takes-it writable?)
             'the-two-must-agree))))
 ;; +x is the DISCRIMINATING token and it is here because a consumer
 ;; needed it: it separates "a leading + is refused" -- which is how the
 ;; changelog first described this release, wrongly -- from "ask the
 ;; writer", which is what the code does.  The writer writes +x, so the
 ;; reader reads it; a rule stated as a token shape would refuse it.
 '("+15" "+i" "-nan.0" ".5" "-.5" "+1/2" "+" "+a" "+x" "..." "abc" "a-b" "--store"))

;; THE FLONUM HALF IS EXACTLY THREE SPELLINGS, and three is the ruling
;; rather than a sample: the spellings a conforming writer emits for
;; these values.  -nan.0 is not among them because no conforming writer
;; emits it, which is why it sits in the invariant list above instead.
(want 'nan-reads-as-a-flonum (nan? (nth "(ok +nan.0)" 1)) #t)
(want 'positive-infinity-reads-as-a-flonum (posinf? (nth "(ok +inf.0)" 1)) #t)
(want 'negative-infinity-reads-as-a-flonum (neginf? (nth "(ok -inf.0)" 1)) #t)

;; CONTROLS.  The readings that are already right must not move, and the
;; decimal spellings must stay REFUSED -- that is the boundary of the
;; widening, so a repair that reached them goes red here.
(want 'CONTROL-plain-integer (nth "(ok 15)" 1) 15)
(want 'CONTROL-negative-integer (nth "(ok -15)" 1) -15)
(want 'CONTROL-the-wire-flonum-form-still-reads
      (nan? (nth "(ok #f8\"AAAAAAAA+H8=\")" 1)) #t)
(want 'CONTROL-decimal-still-refused
      (list (reads-as-symbol? "(ok 1.5)") (reads-as-symbol? "(ok 1e3)")
            (reads-as-symbol? "(ok #xFF)"))
      (list 'refused 'refused 'refused))

(display (if (null? fails) #t fails))

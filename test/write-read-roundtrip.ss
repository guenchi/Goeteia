;; expect: every writable shape reads back, or is exempt by name
;; ONE question, asked once per shape the writer can emit: does
;; (read (write x)) give back x?
;;
;; The denominator is not a list of Scheme types remembered from the
;; report.  It was COUNTED off the artifact: $write in src/prelude.ss
;; dispatches on string, char, pair and vector and hands everything
;; else to $display, whose cond has branches for number, char, string,
;; symbol, null, #t, #f, pair, vector, bytevector, record, procedure,
;; and a fallback.  Every one of those branches appears below with
;; either a cell or an exemption that says why, because a shape with
;; neither is the one nobody notices is missing.
;;
;; This is the cell that would have caught the bytevector case: the
;; writer emitted "#vu8(...)" and the reader had no branch for it, so
;; the library could not read its own output -- and answered an
;; end-of-input object rather than failing.
;;
;; It also caught a defect in its own judge, which is worth recording
;; because the next one will not be this obliging.  The first run of
;; this comparison reported the bytevector row as DIFFERENT while
;; PRINTING THE TWO VALUES IDENTICALLY.  That contradiction is the only
;; reason anyone looked at equal? -- which had no bytevector branch and
;; answered #f for every pair of them.  A judge blind in the same place
;; as its subject reports success; this one happened to be blind in a
;; way that showed.  Do not count on the difference being visible.
(import (rnrs) (notrun))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1)) (display "  FAIL: ")
                     (display what) (newline))
(define (rd s) (with-input-from-string s read))
(define (wr x) (with-output-to-string (lambda () (write x))))

(define (trips? tag x)
  (guard (e (#t (fail! (string-append tag ": writing or reading it raised"))
                #f))
    (let* ((text (wr x)) (back (rd text)))
      (or (equal? back x)
          (begin (fail! (string-append tag ": wrote " text
                                       " and did not read back equal"))
                 #f)))))

;; ---- number ---------------------------------------------------------
(trips? "exact integer" 42)
(trips? "negative integer" -7)
(trips? "zero" 0)
(trips? "bignum" 123456789012345678901234567890)
(trips? "negative bignum" -123456789012345678901234567890)
(trips? "ratio" 7/3)
(trips? "negative ratio" -7/3)
;; Flonums: only those whose printed form reads back exactly.  The
;; printer stops at twelve fractional digits and truncates, so a
;; general flonum is NOT round-trippable through text and this file
;; does not pretend otherwise -- see docs/determinism.md, which says
;; to use bit patterns when a golden is about numbers.
(trips? "flonum, integral" 1000.0)
(trips? "flonum, short fraction" 1.5)
(trips? "flonum, negative zero" (fl* (fl- 0.0 1.0) 0.0))
(not-exercised! "the printer truncates at twelve fractional digits, by a
recorded decision -- docs/determinism.md says to use bit patterns for
numeric goldens" "flonums needing more than twelve fractional digits")
;; Infinities print as a token with no decimal expansion, on purpose.
;; This one is not blocked on anything: it is a decision, and the token
;; is deliberately not readable as a number.
(not-exercised! "infinities print as <big-flonum>, a token rather than a
numeral, by a recorded decision -- there is no decimal expansion to
read back" "+inf.0 and -inf.0")
;; NaN is different: it prints as "+nan.0", which IS its numeral, and
;; the reader does not accept that spelling yet.  Blocked, not decided.
(not-exercised! "external blocker: the reader does not yet accept the
+nan.0 spelling; this lands with the change that makes it a number
rather than a symbol" "+nan.0")

;; ---- string ---------------------------------------------------------
(trips? "string" "abc")
(trips? "string, empty" "")
(trips? "string with the two escaped characters" "a\"b\\c")
(trips? "string with a newline" (string #\a (integer->char 10) #\b))

;; ---- char -----------------------------------------------------------
(trips? "char" #\a)
(trips? "char, named" #\space)
(trips? "char, named newline" #\newline)

;; ---- symbol ---------------------------------------------------------
(trips? "symbol" 'abc)
(trips? "symbol with punctuation" (string->symbol "a-b?!"))
;; A symbol whose name needs quoting is written bare, so it reads back
;; as a DIFFERENT symbol (or as several data): (write (string->symbol
;; "a b")) emits `a b`, which reads as `a`.  Fixing it needs |...| on
;; both sides, writer and reader, which is its own change; the failure
;; is recorded here rather than left for the round trip to discover.
(not-exercised! "known defect, own change: the writer has no |...| form,
so a symbol whose name contains a delimiter is written bare and reads
back as a different symbol -- (string->symbol \"a b\") writes as `a b`
and reads as `a`; the empty symbol writes as nothing and reads as an
end-of-input object" "symbols whose names need quoting")

;; ---- the small aggregates ------------------------------------------
(trips? "null" '())
(trips? "boolean true" #t)
(trips? "boolean false" #f)
(trips? "proper list" (list 1 2 3))
(trips? "improper pair" (cons 1 2))
(trips? "vector" (vector 1 2 3))
(trips? "vector, empty" (vector))
(trips? "bytevector" (bytevector 1 2 255))
(trips? "bytevector, empty" (bytevector))
(trips? "nested" (list 1 (vector 2 (list 3) (bytevector 4)) "s" #\c 'sym))

;; ---- the branches that are not data ---------------------------------
;; These three print as #<...> and are meant to be unreadable: the
;; text is for a person looking at output, not for a reader.  They are
;; listed so that the count above is the writer's whole dispatch and
;; not the part that happened to be convenient.
(not-exercised! "by design: #<...> is a description for a human, not a
datum, and no reader syntax is intended" "records, procedures, and the
unknown-object fallback")

(display (if (= failures 0)
             "every writable shape reads back, or is exempt by name"
             "SEE FAILURES ABOVE"))

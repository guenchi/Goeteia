;; expect: every decimal spelling reads as the number Chez reads
;; The decimal face of the reader, asked through `read` at runtime so
;; the probe passes through the reader and nothing else.  (Measured by
;; compiling instead, every row here looked like a loud refusal; it was
;; name resolution downstream complaining about a symbol the reader had
;; quietly produced.)
;;
;; The oracle is Chez, and no expectation below was typed by hand.
;; Each pattern was produced by reading the same text in Chez and
;; printing the double's bytes:
;;
;;   scheme --quiet <<'EOF'
;;   (define (bits x)
;;     (let ((bv (make-bytevector 8)))
;;       (bytevector-ieee-double-set! bv 0 x (endianness big))
;;       ...))
;;   (bits (read (open-input-string "1e-3")))
;;   EOF
;;
;; Bit patterns rather than printed text: this printer stops at twelve
;; fractional digits, so two different doubles can print alike, and
;; Chez's own printed form ("2.5e-4") is not even a spelling this
;; printer emits.  Comparing text would be comparing two printers.
(import (rnrs) (gfx fx) (notrun))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1)) (display "  FAIL: ")
                     (display what) (newline))
(define (rd s) (with-input-from-string s read))

(define $hex "0123456789abcdef")
(define $bb (fx-alloc! 16))
(define (bits x)
  (%mem-f64-set! $bb x)
  (let loop ((i 7) (acc ""))
    (if (< i 0) acc
        (loop (- i 1)
              (let ((b (%mem-u8-ref (+ $bb i))))
                (string-append acc (string (string-ref $hex (quotient b 16))
                                           (string-ref $hex (remainder b 16)))))))))

(define (flonum-is? src pattern)
  (guard (e (#t (fail! (string-append src " raised")) #f))
    (let ((v (rd src)))
      (cond ((not (flonum? v)) (fail! (string-append src " did not read as a flonum")) #f)
            ((string=? (bits v) pattern) #t)
            (else (fail! (string-append src ": want " pattern " got " (bits v))) #f)))))

(define (reads-as? src ok?)
  (guard (e (#t (fail! (string-append src " raised")) #f))
    (or (ok? (rd src))
        (begin (fail! (string-append src " read as the wrong value")) #f))))

(define (refuses? src)
  (guard (e (#t #t))
    (let ((v (rd src))) (fail! (string-append src " was accepted")) #f)))

;; ---- exponent notation ---------------------------------------------
(flonum-is? "1e3"    "408f400000000000")
(flonum-is? "1E3"    "408f400000000000")     ; the marker is either case
(flonum-is? "1e+3"   "408f400000000000")
(flonum-is? "1e-3"   "3f50624dd2f1a9fc")
(flonum-is? "1.5e3"  "4097700000000000")
(flonum-is? "2.5e-4" "3f30624dd2f1a9fc")
;; the same values written without an exponent must land on the same
;; doubles -- two spellings, one number, and if they part the assembly
;; is rounding somewhere it should not
(flonum-is? "0.001"   "3f50624dd2f1a9fc")
(flonum-is? "1000.0"  "408f400000000000")
(flonum-is? "0.00025" "3f30624dd2f1a9fc")

;; ---- a decimal point with nothing on one side ----------------------
(flonum-is? ".5"  "3fe0000000000000")
(flonum-is? "-.5" "bfe0000000000000")
(flonum-is? "+.5" "3fe0000000000000")
(flonum-is? "5."  "4014000000000000")
(flonum-is? "-5." "c014000000000000")

;; ---- a leading plus, on every numeric shape ------------------------
;; The sign has two spellings and only one of them was accepted; a
;; number face that takes `-` and not `+` is the shape of a half-fix.
(flonum-is? "+1.5" "3ff8000000000000")
(reads-as? "+42"  (lambda (v) (eqv? v 42)))
(reads-as? "+1/2" (lambda (v) (eqv? v 1/2)))
(reads-as? "-42"  (lambda (v) (eqv? v -42)))   ; the half that already worked

;; ---- the non-finite spellings --------------------------------------
;; Asked by property, not by pattern: a NaN's payload is this runtime's
;; business (the encoder states its own policy separately), and what
;; matters here is that the reader produces a number at all rather than
;; a symbol, which is what it used to do.
(reads-as? "+inf.0" (lambda (v) (and (flonum? v) (fl<? 0.0 v) (fl=? v (fl* v 2.0)))))
(reads-as? "-inf.0" (lambda (v) (and (flonum? v) (fl<? v 0.0) (fl=? v (fl* v 2.0)))))
(reads-as? "+nan.0" (lambda (v) (and (flonum? v) (not (fl=? v v)))))
(reads-as? "-nan.0" (lambda (v) (and (flonum? v) (not (fl=? v v)))))

;; ---- what must STAY a symbol ---------------------------------------
;; Chez reads these as symbols, not as numbers and not as errors, and
;; so must this reader.  They are the should-GREEN half: a recogniser
;; that got greedy about `e` would swallow them.
(reads-as? "1e"   (lambda (v) (and (symbol? v) (string=? "1e" (symbol->string v)))))
(reads-as? "1e+"  (lambda (v) (and (symbol? v) (string=? "1e+" (symbol->string v)))))
(reads-as? "+"    (lambda (v) (and (symbol? v) (string=? "+" (symbol->string v)))))
(reads-as? "-"    (lambda (v) (and (symbol? v) (string=? "-" (symbol->string v)))))
(reads-as? "..."  (lambda (v) (symbol? v)))
;; and the one spelling Chez really does refuse
(refuses? ".")

;; ---- every spelling that produces a zero ---------------------------
;; The sign of a zero cannot be carried through the exact layer: the
;; exact integer 0 has no sign, so applying the sign BEFORE the
;; conversion loses it.  That is not hypothetical -- rewriting this
;; parser to assemble an exact rational reintroduced exactly that,
;; and lib/web/json.ss had already written the mechanism down for its
;; own reader before this file existed.  So every route to a zero is
;; asked here, including the ones that arrive by underflow rather than
;; by being written as zero.
(flonum-is? "0.0"     "0000000000000000")
(flonum-is? "-0.0"    "8000000000000000")
(flonum-is? "-.0"     "8000000000000000")
(flonum-is? "-0e0"    "8000000000000000")
(flonum-is? "-0.0e5"  "8000000000000000")
(flonum-is? "1e-400"  "0000000000000000")   ; underflows to zero
(flonum-is? "-1e-400" "8000000000000000")   ; and keeps its sign doing it

;; ---- long decimals, where the assembly has to stay exact -----------
;; Forty digits: the value cannot be accumulated in floating point on
;; the way in without landing on a different double, so this is the
;; cell that says the digits are assembled as an exact rational and
;; rounded once.
(flonum-is? "0.1234567890123456789012345678901234567890"
            "3fbf9add3746f65f")

;; Those forty digits do NOT actually pin the assembly method, and
;; that was measured rather than assumed: replacing the exact
;; assembly with (fl/ (exact->inexact num) (exact->inexact den))
;; leaves that cell's bits unchanged, so it would have gone on passing
;; over a parser that rounded three times.  A mutation that changes no
;; behaviour for the inputs on hand proves nothing about the cells --
;; it has to be told apart from a mutation the cells failed to catch.
;;
;; These are inputs where the two methods DO land on different
;; doubles, found by sweeping for a disagreement rather than by
;; picking a long-looking number.  They are what makes "assembled
;; exactly, rounded once" a checked claim instead of a described one.
(flonum-is? "55.59060605468946965888662"         "404bcb98faacdafd")
(flonum-is? "5.003154544922052269299795"         "4014033af1ed188e")
(flonum-is? "0.1350851727128954112710944624"     "3fc14a788f7cfa97")
(flonum-is? "0.0000450283909042984704236981542"  "3f079b9bbb08d887")
(flonum-is? "2.9543127272310226444988358905020e-5" "3efefa6c3f4eef7b")

;; The seam with the radix and exactness prefixes, now that they are
;; here: `#e1e3` must read as the EXACT integer 1000.  An assembly that
;; converted to a flonum too early would answer 1000.0, and the two are
;; indistinguishable through `=`, which is why the cell asks for
;; exactness rather than for the value.
(reads-as? "#e1e3" (lambda (v) (and (exact? v) (eqv? v 1000))))
(reads-as? "#i1e3" (lambda (v) (and (inexact? v) (fl=? v 1000.0))))
(reads-as? "#e1.5" (lambda (v) (and (exact? v) (eqv? v 3/2))))
;; the same digits at another radix, where the exponent scales by that
;; radix: #o1e3 is 8^3, not 10^3
(reads-as? "#o#e1e3" (lambda (v) (and (exact? v) (eqv? v 512))))

;; A long decimal in the SUBNORMAL range is deliberately not here: the
;; converter rounds at 53 bits and then scales down, rounding a second
;; time, so such a cell would be red for the converter's reason rather
;; than the reader's.  It belongs to that fix.
(not-exercised! "external blocker: the exact-to-double conversion
rounds twice at the subnormal floor, so a subnormal-range decimal is
judged by that defect and not by this reader" "long decimals below 2^-1022")

(display (if (= failures 0)
             "every decimal spelling reads as the number Chez reads"
             "SEE FAILURES ABOVE"))

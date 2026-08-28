;; Generate the number-syntax corpus as a CROSS PRODUCT, not a list.
;;
;; This is a Chez script, not a goeteia test: run-tests.sh takes
;; test/*.ss as its suites, so a generator with that extension is
;; compiled as a test and fails.  Generators end in .sc here
;; (test/gen-sexpr-vectors.sc is the other one) -- the extension is
;; part of the runner's contract, not a preference.
;; Writes the whole fixture, header included, so that regenerating is
;; one command and nothing about the file is maintained by hand.
;; A hand-written list is a snapshot of what the author thought of;
;; this one is prefixes x signs x bodies, so the shapes nobody
;; remembers (a hex float whose exponent marker is a digit, a prefix
;; with no number after it) are present because the product contains
;; them, not because someone recalled them.
(define radix-prefixes '("" "#b" "#B" "#o" "#O" "#d" "#D" "#x" "#X"))
(define exact-prefixes '("" "#e" "#E" "#i" "#I"))
(define bodies
  ;; ⚠ THIS LIST HAS ALREADY BEEN INCOMPLETE ONCE, IN EXACTLY THIS WAY.
;; docs/sexpr.md records a different corpus whose matrix missed five
;; dimensions -- among them the s/f/d/l exponent markers, the same four
;; this list was missing on its first day -- and closes with "assume it
;; is still incomplete".  Assume that here too: if you are reading this
;; because you are adding a row, the question is which DIMENSION is
;; absent, not which example.
;;
;; The exponent markers are ALL FIVE that R6RS defines, not just `e`.
  ;; The first version of this list had only `e`, and docs/sexpr.md had
  ;; already recorded s/f/d/l as one of the dimensions a hand-written
  ;; list missed -- in a different corpus, for the same reason, with
  ;; the warning "assume it is still incomplete" attached.  Marker case
  ;; is a dimension too, and so is the exponent's own digit range: in
  ;; base eight `1e8` has no valid exponent while `1e7` does.
  '("1" "0" "007" "10" "101" "17" "1f" "a.b" "ad" "2" "8" "zz"
    "1/2" "1/11" "7/10" "1/0" "0/0" "4/2" "0/5" "2/4"
    ".8" ".1" ".4" "1." "1.5" "0.10"
    "1e3" "1E3" "1e+3" "1e-3" "1.5e2" "1.8e2" "1e" "1e+"
    "1s3" "1f3" "1d3" "1l3" "1S3" "1F3" "1D3" "1L3" "1.5d2"
    "1e10" "1e8" "1e7" "1e1" ""))
(define signs '("" "+" "-"))

(define (bits x)
  (let ((bv (make-bytevector 8)))
    (bytevector-ieee-double-set! bv 0 x (endianness big))
    (let loop ((i 0) (acc ""))
      (if (= i 8) acc
          (loop (+ i 1)
                (string-append acc
                  ;; lower case, always: Chez renders hex digits upper
                  ;; case and this runtime lower, and a fixture that
                  ;; recorded the difference would fail every flonum
                  ;; row for a reason that is not about numbers
                  (let ((h (string-downcase
                            (number->string (bytevector-u8-ref bv i) 16))))
                    (if (= 1 (string-length h)) (string-append "0" h) h))))))))

;; Printer-independent classification: a flonum is its bytes, an exact
;; number is its exact numeral, a symbol is named.  Comparing printed
;; text would compare two printers -- and did, once, reporting +inf.0
;; as a disagreement when only the spelling differed.
(define (classify v)
  (cond
   ((eof-object? v) "EOF")
   ((symbol? v) (string-append "sym:" (symbol->string v)))
   ((and (number? v) (inexact? v) (real? v)) (string-append "f64:" (bits v)))
   ((number? v) (string-append "exact:" (number->string v)))
   (else (string-append "other:" (with-output-to-string (lambda () (write v)))))))

;; ---- deliberate divergences from the oracle -----------------------
;; Rows where OUR expectation is not Chez's, by ruling.  The list lives
;; here, in the generator, because the generator is what would
;; otherwise overwrite it: a divergence recorded only in the fixture is
;; erased by the next regeneration, silently and by someone acting in
;; good faith.  The thing that can falsify a record has to carry it.
;;
;;   zero denominator: Chez answers +inf.0 for "#i1/0" -- the inexact
;;   form of a ratio whose denominator is zero.  Supporting it means
;;   deferring the division past the exactness prefix and adding a
;;   separate 0/0-is-NaN case: a second shape in the parser for a
;;   spelling nobody writes.  Refused here, with a message naming
;;   +inf.0 / -inf.0 / +nan.0 as the spellings that work.
(define (ends-in-zero-denominator? s)
  (let ((n (string-length s)))
    (and (< 1 n)
         (char=? #\0 (string-ref s (- n 1)))
         (let scan ((i (- n 2)))
           (and (<= 0 i)
                (cond ((char=? #\/ (string-ref s i)) #t)
                      ((char=? #\0 (string-ref s i)) (scan (- i 1)))
                      (else #f)))))))

(define divergences 0)
(define (expectation-for s chez)
  ;; Count a divergence only when the answer actually differs.  The
  ;; rule below also covers rows Chez already refuses ("1/0" with no
  ;; #i), and counting those would announce a number larger than the
  ;; set it describes -- an over-count in the sentence whose whole job
  ;; is to say how much of this file is not the oracle's.
  (if (ends-in-zero-denominator? s)
      (begin
        (unless (string=? chez "REFUSED")
          (set! divergences (+ divergences 1)))
        "REFUSED")
      chez))

(define (emit s)
  (let ((chez (call/cc (lambda (k)
                (with-exception-handler (lambda (e) (k "REFUSED"))
                  (lambda () (classify (read (open-input-string s)))))))))
    (display s) (display "\t") (display (expectation-for s chez)) (newline)))

(define (header)
  (for-each (lambda (l) (display l) (newline))
   (list
    ";; Number-syntax reference face, generated from Chez Scheme 10.1.0."
    ";;"
    ";; Regenerate with:"
    ";;     scheme --quiet --script test/gen-number-face.sc > test/number-face.tsv"
    ";;"
    ";; Columns: the source text, a tab, and the expected classification."
    ";; A flonum is recorded as its eight bytes (lower case), an exact"
    ";; number as its exact numeral, a symbol by name, and REFUSED when"
    ";; the reader raises.  Bytes rather than printed text, because"
    ";; comparing printed forms compares two printers: this"
    ";; implementation spells an infinity \"<big-flonum>\" by a recorded"
    ";; decision, and a text comparison once called that a reader"
    ";; disagreement when only the spelling differed."
    ";;"
    ";; The rows are a CROSS PRODUCT of radix prefixes, exactness"
    ";; prefixes, signs and bodies -- not a hand-written list.  The"
    ";; hand-written version this replaced was missing hex fractions"
    ";; whose exponent marker is a digit, exactness over an exponent,"
    ";; ratios with a zero denominator, four of the five exponent"
    ";; markers, and every sign pile-up."
    ";;"
    ";; MOST ROWS ARE CHEZ'S ANSWER.  A few are deliberately NOT --"
    ";; see the divergence list in the generator, which is where it has"
    ";; to live: a divergence recorded only here would be erased by the"
    ";; next regeneration, silently.  The count is at the end of this"
    ";; file and is printed when the generator runs.")))

(define seen '())
(header)
(for-each
 (lambda (rp)
   (for-each
    (lambda (ep)
      (for-each
       (lambda (sg)
         (for-each
          (lambda (b)
            (let ((s (string-append rp ep sg b)))
              (unless (or (string=? s "") (member s seen))
                (set! seen (cons s seen))
                (emit s))))
          bodies))
       signs))
    exact-prefixes))
 radix-prefixes)
;; and the orderings the product above does not reach: exactness first
(for-each (lambda (s) (unless (member s seen) (set! seen (cons s seen)) (emit s)))
          '("#e#x1f" "#E#X1F" "#i#x1f" "#i#b101" "#e#d1/2" "#e#x#b1"
            "#x#x1f" "#e#e1.5" "#e#i1.5" "#i#e1.5" "#x#e" "#e#x"
            "++1" "--1" "+-1" "1+" "1-" "." ".." "..." "+inf.0" "-inf.0"
            "+nan.0" "-nan.0" "#xabc" "#xdef" "#bad" "#x1e3" "#b1e3"))

;; The count travels with the file and with the run.  A divergence
;; nobody is told about is indistinguishable from a mistake.
(display ";; rows: ") (display (length seen)) (newline)
(display ";; That count is here so the suite can check it against what it
;; actually parsed.  A fixture truncated to three rows would otherwise
;; let \"agrees on every row\" mean three rows while reading like six
;; thousand.  The number is generated with the rows, so it is not a
;; cardinality cached away from the set it describes.")
(newline)
(display ";; ") (display divergences)
(display " rows deliberately diverge from Chez: the inexact form of a")
(newline)
(display ";; zero-denominator ratio (#i1/0 and friends), which Chez reads as")
(newline)
(display ";; an infinity and this reader refuses by name.")
(newline)
(let ((p (current-error-port)))
  (display divergences p)
  (display " rows deliberately diverge from Chez (zero-denominator ratios)" p)
  (newline p))

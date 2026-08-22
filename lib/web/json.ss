;; Safe JSON parser and writer, ported from Igropyr's (igropyr json).
;;
;; A recursive-descent parser over the input string: no reader tricks,
;; safe for untrusted input. Full string escape handling including
;; \uXXXX and surrogate pairs -- decoded code points are written as
;; UTF-8 bytes (Goeteia strings are UTF-8 byte strings).
;;
;; Data model (identical to the server side):
;;   object -> alist with string keys      {"a":1}   -> (("a" . 1))
;;   array  -> vector                      [1,2]     -> #(1 2)
;;   string -> string, number -> number
;;   true/false -> #t/#f, null -> 'null
;;
;; (string->json s)   parse; raises #(json-error msg pos) on bad input
;; (json->string x)   serialize (alists -> objects, vectors -> arrays;
;;                    a NON-EMPTY plain list also serializes as an
;;                    array.  '() is the empty OBJECT "{}", not "[]" --
;;                    an empty list cannot say which it meant, and the
;;                    alist branch is the one that owns it.  Build the
;;                    empty array as #().)
;; (json-ref x k ...) path access: string/symbol key for objects,
;;                    integer index for arrays; #f when absent
;; (json-array? x)    is this datum a JSON array?  A NAME for vector?,
;;                    because the answer is the thing people get wrong
;; (json-array->list x) an array's elements as a list, one level deep
;;
;; ONE SHAPE TRIPS EVERYONE: a JSON array is a VECTOR here, not a list.
;; `(list? (json-ref doc "items"))` is #f for every array that ever
;; existed, and it is #f in the quiet way -- no error, no warning, just
;; a branch that never runs.  An object is an alist, so `list?` IS true
;; of objects, which is exactly backwards from the guess.  Ask
;; json-array? instead; it exists to be the name that says so.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web json)
  (export string->json json->string json-ref
          json-array? json-array->list)
  (import (rnrs) (web utf8))

  (define (jfail msg pos)
    (raise (vector 'json-error msg pos)))

  (define (pow10 k)
    (let loop ((k k) (acc 1))
      (if (<= k 0) acc (loop (- k 1) (* acc 10)))))

  ;; Parsing eventually rounds non-integral JSON numbers to a flonum, so
  ;; larger exponents cannot add useful precision.  More importantly, a
  ;; file-controlled exponent must never drive an unbounded bignum pow10.
  (define $max-number-digits 4096)
  (define $max-exponent 400)

  ;; ---- parser -----------------------------------------------------------

  ;; One definition each, above both users: the reader refuses a
  ;; literal that reads as an infinity and the writer refuses to spell
  ;; one, and those two answers have to come from the same predicate or
  ;; they can drift into disagreeing about the same value.
  (define (fl-nan? v) (not (fl=? v v)))
  (define (fl-inf? v) (and (fl=? v (fl* v 2.0)) (not (fl=? v 0.0))))

  (define (string->json s)
    (let ((n (string-length s)))
      (define (skip-ws i)
        (if (and (< i n) (memv (string-ref s i)
                               '(#\space #\tab #\newline #\return)))
            (skip-ws (+ i 1))
            i))
      (define (expect ch i)
        (if (and (< i n) (char=? (string-ref s i) ch))
            (+ i 1)
            (jfail (string-append "expected " (string ch)) i)))
      (define (parse-value i)
        (let ((i (skip-ws i)))
          (when (>= i n) (jfail "unexpected end of input" i))
          (let ((ch (string-ref s i)))
            (cond
             ((char=? ch #\{) (parse-object (+ i 1)))
             ((char=? ch #\[) (parse-array (+ i 1)))
             ((char=? ch #\") (parse-string (+ i 1)))
             ((char=? ch #\t) (parse-literal i "true" #t))
             ((char=? ch #\f) (parse-literal i "false" #f))
             ((char=? ch #\n) (parse-literal i "null" 'null))
             ((or (char=? ch #\-) (char-numeric? ch)) (parse-number i))
             (else (jfail "unexpected character" i))))))
      (define (parse-literal i word value)
        (let ((end (+ i (string-length word))))
          (if (and (<= end n) (string=? (substring s i end) word))
              (values value end)
              (jfail "bad literal" i))))
      (define (parse-object i)
        (let ((i (skip-ws i)))
          (if (and (< i n) (char=? (string-ref s i) #\}))
              (values '() (+ i 1))
              (let loop ((i i) (acc '()))
                (let ((i (skip-ws i)))
                  (unless (and (< i n) (char=? (string-ref s i) #\"))
                    (jfail "expected object key" i))
                  (let-values (((key i) (parse-string (+ i 1))))
                    (let ((i (expect #\: (skip-ws i))))
                      (let-values (((val i) (parse-value i)))
                        (let ((i (skip-ws i)))
                          (cond
                           ((and (< i n) (char=? (string-ref s i) #\,))
                            (loop (+ i 1) (cons (cons key val) acc)))
                           ((and (< i n) (char=? (string-ref s i) #\}))
                            (values (reverse (cons (cons key val) acc))
                                    (+ i 1)))
                           (else (jfail "expected , or } in object" i))))))))))))
      (define (parse-array i)
        (let ((i (skip-ws i)))
          (if (and (< i n) (char=? (string-ref s i) #\]))
              (values (vector) (+ i 1))
              (let loop ((i i) (acc '()))
                (let-values (((val i) (parse-value i)))
                  (let ((i (skip-ws i)))
                    (cond
                     ((and (< i n) (char=? (string-ref s i) #\,))
                      (loop (+ i 1) (cons val acc)))
                     ((and (< i n) (char=? (string-ref s i) #\]))
                      (values (list->vector (reverse (cons val acc)))
                              (+ i 1)))
                     (else (jfail "expected , or ] in array" i)))))))))
      (define (hex-digit c)
        (let ((v (char->integer c)))
          (cond
           ((and (<= 48 v) (<= v 57)) (- v 48))          ; 0-9
           ((and (<= 97 v) (<= v 102)) (- v 87))         ; a-f
           ((and (<= 65 v) (<= v 70)) (- v 55))          ; A-F
           (else #f))))
      (define (hex4 i)
        (unless (<= (+ i 4) n) (jfail "bad \\u escape" i))
        (let loop ((j i) (acc 0))
          (if (= j (+ i 4))
              acc
              (let ((d (hex-digit (string-ref s j))))
                (unless d (jfail "bad \\u escape" i))
                (loop (+ j 1) (+ (* acc 16) d))))))
      ;; Goeteia strings are UTF-8 byte strings: a decoded code point
      ;; is written as its UTF-8 bytes
      (define (utf8-write! p cp)
        (define (b! v) (write-char (integer->char v) p))
        (cond
         ((< cp #x80) (b! cp))
         ((< cp #x800)
          (b! (bitwise-ior #xC0 (bitwise-arithmetic-shift-right cp 6)))
          (b! (bitwise-ior #x80 (bitwise-and cp #x3F))))
         ((< cp #x10000)
          (b! (bitwise-ior #xE0 (bitwise-arithmetic-shift-right cp 12)))
          (b! (bitwise-ior #x80 (bitwise-and (bitwise-arithmetic-shift-right cp 6) #x3F)))
          (b! (bitwise-ior #x80 (bitwise-and cp #x3F))))
         (else
          (b! (bitwise-ior #xF0 (bitwise-arithmetic-shift-right cp 18)))
          (b! (bitwise-ior #x80 (bitwise-and (bitwise-arithmetic-shift-right cp 12) #x3F)))
          (b! (bitwise-ior #x80 (bitwise-and (bitwise-arithmetic-shift-right cp 6) #x3F)))
          (b! (bitwise-ior #x80 (bitwise-and cp #x3F))))))
      ;; ---- known deviations from RFC 8259 ----------------------------
      ;; This reader has deviations from RFC 8259's read grammar, some
      ;; of them accepting what the RFC forbids and some refusing what
      ;; it requires.  WHICH ONES THEY ARE IS NOT WRITTEN HERE.  The
      ;; list, the classification and the clause each one answers to
      ;; live in test/json-rfc-surface.ss, row by row, and that table
      ;; owns them.
      ;;
      ;; NEVER RESTATE A COUNT OR A LIST OF THE DEVIATIONS HERE.  An
      ;; earlier version of this note did -- it said the set was closed
      ;; at two -- and a third was found later.  The rule is not that
      ;; the number was wrong; it is that the number was written in the
      ;; wrong file.  Whoever discovers the next one will be editing the
      ;; parser and the table, and has no reason to open this comment,
      ;; so a total stated here goes false with NOBODY PRESENT to notice.
      ;; A fact whose falsifier is standing somewhere else cannot be
      ;; kept true by care, only by not being written down twice.  (Note
      ;; that a self-destruct clause does not save it either: such a
      ;; clause protects a claim that might be WRONG, not a claim that
      ;; is not this file's to make.)
      ;;
      ;; Single-line notes at the sites below are a different thing and
      ;; are fine: the person who makes "this branch accepts X" false is
      ;; editing that branch, so the falsifier is present.
      ;;
      ;; LOCKSTEP.  The deviations are shared with (igropyr json), the
      ;; reader this one was ported from; each side parses what the
      ;; other's writer produced.  Tightening one HERE alone would fix
      ;; this reader's conformance and at the same moment split the
      ;; pair: input one side takes and the other refuses, which is the
      ;; failure the pairing exists to prevent and the worse of the two.
      ;; The choice is not "defect or no defect" but which defect, and
      ;; the answer is that both move together or neither does.  The
      ;; surface table is the place that records what "together" means;
      ;; the counterpart holds the same table under the same row names.
      ;;
      ;; What is NOT shared, and so must not be assumed: the two readers
      ;; bound a number token differently, and this one accumulates
      ;; digits itself instead of delegating to string->number.  The
      ;; counterpart therefore had a deviation this side never had, and
      ;; that is why agreement is MEASURED row by row rather than
      ;; inferred from the shared ancestry.
      (define (parse-string i)          ; i points after the opening quote
        (let ((p (open-output-string)))
          (let loop ((i i))
            (when (>= i n) (jfail "unterminated string" i))
            (let ((ch (string-ref s i)))
              (cond
               ((char=? ch #\") (values (get-output-string p) (+ i 1)))
               ((char=? ch #\\)
                (when (>= (+ i 1) n) (jfail "bad escape" i))
                (let ((e (string-ref s (+ i 1))))
                  (case e
                    ((#\") (write-char #\" p) (loop (+ i 2)))
                    ((#\\) (write-char #\\ p) (loop (+ i 2)))
                    ((#\/) (write-char #\/ p) (loop (+ i 2)))
                    ((#\b) (write-char (integer->char 8) p) (loop (+ i 2)))
                    ((#\f) (write-char (integer->char 12) p) (loop (+ i 2)))
                    ((#\n) (write-char #\newline p) (loop (+ i 2)))
                    ((#\r) (write-char #\return p) (loop (+ i 2)))
                    ((#\t) (write-char #\tab p) (loop (+ i 2)))
                    ((#\u)
                     (let ((v (hex4 (+ i 2))))
                       (if (and (>= v #xD800) (<= v #xDBFF))
                           ;; high surrogate: expect \uDC00-\uDFFF
                           (begin
                             (unless (and (<= (+ i 12) n)
                                          (char=? (string-ref s (+ i 6)) #\\)
                                          (char=? (string-ref s (+ i 7)) #\u))
                               ;; Refused although RFC 8259 allows it
                               ;; (section 7 spells the escape as %x75
                               ;; 4HEXDIG with no pairing rule, and
                               ;; section 9 says a parser MUST accept
                               ;; what the grammar allows).  Goeteia
                               ;; strings are UTF-8 byte strings and a
                               ;; lone surrogate has no UTF-8 encoding,
                               ;; so conforming means emitting WTF-8 and
                               ;; calling it a string.  Deliberate, and
                               ;; shared with (igropyr json); if these
                               ;; two branches ever start accepting,
                               ;; that is a lockstep change and this
                               ;; note goes with them.
                               (jfail "lone high surrogate" i))
                             (let ((lo (hex4 (+ i 8))))
                               (unless (and (>= lo #xDC00) (<= lo #xDFFF))
                                 (jfail "bad low surrogate" i))
                               (utf8-write! p (+ #x10000
                                                 (* (- v #xD800) #x400)
                                                 (- lo #xDC00)))
                               (loop (+ i 12))))
                           (begin
                             (when (and (>= v #xDC00) (<= v #xDFFF))
                               (jfail "lone low surrogate" i))
                             (utf8-write! p v)
                             (loop (+ i 6))))))
                    (else (jfail "bad escape" i)))))
               ;; Any other character, INCLUDING the control characters
               ;; RFC 8259 section 7 requires to be escaped (unescaped
               ;; starts at %x20).  Known deviation, shared with
               ;; (igropyr json), pinned in test/json-rfc-surface.ss;
               ;; tightening it here alone splits the pair.
               (else (write-char ch p) (loop (+ i 1))))))))
      ;; JSON numbers by hand: string->number has no exponents, so the
      ;; value is assembled exactly -- digits / 10^frac * 10^exp as an
      ;; exact ratio -- and `exact->inexact` is called on it ONCE, when
      ;; the number is fractional.
      ;;
      ;; That is what this code does.  It is NOT a promise that the
      ;; result is the correctly rounded double for the real number the
      ;; text denotes: that depends on `exact->inexact`, and today the
      ;; runtime's gets it wrong in the subnormal range.  Measured, on
      ;; the exact ratio itself rather than through this parser:
      ;;
      ;;   24703282292062328/10^340  ->  0.0
      ;;   correct (round to nearest) ->  2^-1074, the least subnormal
      ;;
      ;; The same ratio converts the same wrong way on the wasm and the
      ;; js target, so it is not something this file can fix; the wrong
      ;; value arrives here already made.  Filed against the runtime
      ;; with the printing defects it shares a cause with -- there is no
      ;; correctly rounded conversion in either direction, decimal to
      ;; binary or binary to decimal.
      (define (digit v) (and (<= 48 v) (<= v 57) (- v 48)))
      (define (scan-digits i limit)
        (let loop ((j i) (acc 0) (k 0))
          (if (< j n)
              (let ((d (digit (char->integer (string-ref s j)))))
                (if d
                    (if (= k limit)
                        (jfail "number is too long" j)
                        (loop (+ j 1) (+ (* acc 10) d) (+ k 1)))
                    (values acc k j)))
              (values acc k j))))
      ;; This scanner does not distinguish `0` from `[1-9][0-9]*`, so
      ;; "01" is taken.  RFC 8259 section 6 forbids that; it is a known
      ;; deviation, shared with (igropyr json), pinned in
      ;; test/json-rfc-surface.ss.  Tightening it here alone splits the
      ;; pair -- see the lockstep note above parse-string.
      ;; Every inexact value this reader hands back goes through here.
      ;; A literal past the flonum range reads as an infinity, and the
      ;; writer turns infinities into `null` -- so accepting one lets a
      ;; NUMBER become NULL across a round trip, silently, and in place
      ;; inside arrays and objects ("[1e309,1]" -> "[null,1]").  RFC
      ;; 8259 section 6 lets a parser limit the range it accepts;
      ;; refusing here is that limit, and it is the answer (igropyr
      ;; json) already gives, so the two readers keep ONE acceptance
      ;; surface instead of disagreeing about this input.
      ;;
      ;; The judge is the VALUE, not a digit count.  $max-exponent
      ;; bounds the WORK before it is done (it stops pow10 from
      ;; building a thousand-digit bignum) and this bounds the RESULT;
      ;; they are not two spellings of one rule, and neither covers the
      ;; other -- "0.5e400" overflows with an exponent well inside the
      ;; work bound, and a long enough integer part overflows with no
      ;; exponent at all.  NaN is not checked because nothing here can
      ;; produce one: the mantissa is exact and pow10 is positive.
      (define (finite! v at)
        (if (fl-inf? v) (jfail "number out of range" at) v))
      (define (parse-number i)
        (let* ((neg (char=? (string-ref s i) #\-))
               (start (if neg (+ i 1) i)))
          (let-values (((ip ik j0) (scan-digits start $max-number-digits)))
            (when (= ik 0) (jfail "bad number" i))
            (let ((dot? (and (< j0 n) (char=? (string-ref s j0) #\.))))
              (let-values (((fp fk j)
                            (if dot?
                                (scan-digits (+ j0 1) $max-number-digits)
                                (values 0 0 j0))))
                (when (and dot? (= fk 0)) (jfail "bad number" i))
                (if (and (< j n) (memv (string-ref s j) '(#\e #\E)))
                    (let* ((k0 (+ j 1))
                           (esign (and (< k0 n)
                                       (memv (string-ref s k0) '(#\+ #\-))
                                       (string-ref s k0)))
                           (k (if esign (+ k0 1) k0)))
                       ;; THREE judges here, and they are independent;
                       ;; do not fold any two of them together.
                       ;;
                       ;;   how many digits  -- $max-number-digits,
                       ;;     below.  RFC 8259's `exp = e [minus/plus]
                       ;;     1*DIGIT` sets no limit, so this only
                       ;;     bounds the scan, and it used to be THREE:
                       ;;     that made "1e0001" -- value ten -- a
                       ;;     parse error, which is not a range or a
                       ;;     precision limit and so was a plain
                       ;;     deviation, and one the counterpart did
                       ;;     not share.
                       ;;   at least one    -- `(= ek 0)` just below.
                       ;;   how big         -- $max-exponent, and then
                       ;;     finite! on the value.
                       ;;
                       ;; Widening the first must not touch the third.
                       ;; "1e400" is refused for its VALUE and "1e0001"
                       ;; was refused for its LENGTH; they read alike
                       ;; from the outside, and folding the two would
                       ;; have quietly undone the range fix while every
                       ;; test for either one alone stayed green.
                       (let-values (((ep ek j2)
                                     (scan-digits k $max-number-digits)))
                         (when (= ek 0) (jfail "bad number" i))
                         ;; ⚠ WHY THIS LINE IS HERE.  When it was
                         ;; written, no test could tell: deleting it
                         ;; left every row in
                         ;; test/json-rfc-surface.ss green, because the
                         ;; finiteness check below refuses the same
                         ;; inputs one step later.  What happened
                         ;; instead was that the parser stopped
                         ;; answering -- measured, not guessed: the run
                         ;; went past a two-minute limit with no
                         ;; output, because pow10 was building a bignum
                         ;; sized by the input.
                         ;;
                         ;; test/json.ss now asks for the refusal BY
                         ;; NAME, so deleting this does fail rather than
                         ;; only hang.  The paragraph above is kept
                         ;; because it says why that assertion had to be
                         ;; written at all: a bound whose only symptom
                         ;; is "no answer" has nothing to announce it,
                         ;; and a timeout is not a red.
                         ;;
                         ;; It was not always load-bearing.  While the
                         ;; exponent scan was capped at three digits
                         ;; `ep` could not exceed 999 and this was
                         ;; decoration.  Widening that cap -- required,
                         ;; because RFC 8259's `exp` puts no limit on
                         ;; the digit count -- is what turned it into
                         ;; the only thing between untrusted input and
                         ;; unbounded work.  A change elsewhere altered
                         ;; what THIS line is for, and nothing in the
                         ;; diff said so.
                         ;;
                         ;; So: this bounds the WORK.  finite! bounds
                         ;; the VALUE.  $max-number-digits bounds the
                         ;; SCAN.  Three judges, three reasons, and
                         ;; refusals name which one fired so they stay
                         ;; distinguishable (test/json.ss asks for the
                         ;; message by name).  Do not fold them.
                         (when (> ep $max-exponent)
                           (jfail "exponent out of range" k))
                        (let* ((m0 (/ (+ (* ip (pow10 fk)) fp) (pow10 fk)))
                               (mant (if neg (- m0) m0))
                               (v (if (and esign (char=? esign #\-))
                                      (/ mant (pow10 ep))
                                      (* mant (pow10 ep)))))
                          (values (finite! (exact->inexact v) i) j2))))
                    (let ((v (if dot?
                                 (finite!
                                  (exact->inexact
                                   (let ((m (/ (+ (* ip (pow10 fk)) fp)
                                               (pow10 fk))))
                                     (if neg (- m) m)))
                                  i)
                                 (if neg (- ip) ip))))
                      (values v j))))))))
      ;; top level: one value, then only whitespace
      (let-values (((v end) (parse-value 0)))
        (unless (= (skip-ws end) n) (jfail "trailing characters" end))
        v)))

  ;; ---- writer ------------------------------------------------------------

  (define (hex-char v)
    (string-ref "0123456789abcdef" v))

  ;; WRITE side only.  RFC 8259 section 8.1: JSON text exchanged
  ;; between systems shall be encoded in UTF-8, so a byte string that
  ;; is not UTF-8 cannot go out as JSON text -- and a Goeteia string is
  ;; a byte string, so nothing upstream guarantees it is.  Refused here
  ;; rather than emitted, which is the writer's half of Postel: what
  ;; leaves is narrower than what arrives.
  ;;
  ;; The READ side keeps taking such bytes on purpose.  Section 9 lets
  ;; a parser accept non-JSON forms, and the reader this one is paired
  ;; with accepts them too; tightening one side alone would make one
  ;; side refuse a document the other takes.  That asymmetry is the
  ;; failure the pairing exists to prevent, and it is why this check is
  ;; here and not in parse-string.  Same predicate as (web sexpr)'s
  ;; writer, from (web utf8), because it is the same rule.
  (define (json-escape s)
    (unless (utf8-well-formed? s)
      (error 'json->string "string is not well-formed UTF-8" s))
    (let ((p (open-output-string)))
      (string-for-each
       (lambda (ch)
         (let ((code (char->integer ch)))
           (cond
            ((char=? ch #\") (display "\\\"" p))
            ((char=? ch #\\) (display "\\\\" p))
            ((char=? ch #\newline) (display "\\n" p))
            ((char=? ch #\return) (display "\\r" p))
            ((char=? ch #\tab) (display "\\t" p))
            ((< code 32)
             (display "\\u00" p)
             (write-char (hex-char (quotient code 16)) p)
             (write-char (hex-char (remainder code 16)) p))
            (else (write-char ch p)))))
       s)
      (get-output-string p)))


  (define (number->json v)
    (cond
     ((and (integer? v) (exact? v)) (number->string v))
     ;; A ratio becomes a flonum and then takes the SAME branch as one
     ;; that arrived as a flonum.  It used to call number->string on the
     ;; conversion directly, skipping the non-finite test just below --
     ;; so a ratio too large for a double came out as whatever the host
     ;; prints for an infinity, which is not JSON on any host.  One
     ;; policy ("non-finite is written null"), one place that applies
     ;; it: a second conversion site is a second place for the policy to
     ;; be missing from, and this is what that looked like.
     ((or (flonum? v) (exact? v))
      (let ((f (if (flonum? v) v (exact->inexact v))))
        (if (or (fl-nan? f) (fl-inf? f)) "null" (number->string f))))
     (else (error 'json->string "JSON numbers must be real" v))))

  ;; Is this list an OBJECT rather than an array of things?
  ;;
  ;; The test used to be "a list whose car is a pair", which reads the
  ;; whole shape off ONE element -- and a list of objects has a pair
  ;; for its car too, since an object is itself a list of pairs.  So
  ;; `(json-array->list (string->json "[{\"a\":1}]"))` came back a list
  ;; whose first element is an alist, was taken for an object whose
  ;; first KEY is the pair ("a" . 1), and json-escape got a pair where
  ;; a string belongs: an illegal cast, which is a TRAP -- the caller
  ;; cannot guard it, the program stops.  The vector spelling of the
  ;; same data was always fine, so the route was chosen by whichever
  ;; shape the caller happened to hold.
  ;;
  ;; Every element now has to look like a member: a pair whose car is a
  ;; string or a symbol.  That is what tells `(("a" . 1))` -- an object
  ;; -- from `((("a" . 1)))` -- an array holding one object -- and it
  ;; reads the whole list rather than guessing from its head.
  (define (json-object-shape? x)
    (and (pair? x)
         (let loop ((l x))
           (or (null? l)
               (and (pair? l)
                    (pair? (car l))
                    (let ((k (caar l))) (or (string? k) (symbol? k)))
                    (loop (cdr l)))))))

  (define (json->string x)
    (cond
     ((eq? x #t) "true")
     ((eq? x #f) "false")
     ((eq? x 'null) "null")
     ((number? x) (number->json x))
     ((string? x) (string-append "\"" (json-escape x) "\""))
     ((symbol? x) (string-append "\"" (json-escape (symbol->string x)) "\""))
     ((vector? x)
      (string-append
       "["
       (let loop ((i 0) (acc ""))
         (if (= i (vector-length x))
             acc
             (loop (+ i 1)
                   (if (string=? acc "")
                       (json->string (vector-ref x i))
                       (string-append acc "," (json->string (vector-ref x i)))))))
       "]"))
     ((null? x) "{}")
     ((json-object-shape? x)                       ; alist -> object
      (string-append
       "{"
       (fold-right
        (lambda (kv acc)
          (let ((entry (string-append
                        "\"" (json-escape
                              (if (symbol? (car kv))
                                  (symbol->string (car kv))
                                  (car kv)))
                        "\":" (json->string (cdr kv)))))
            (if (string=? acc "") entry (string-append entry "," acc))))
        "" x)
       "}"))
     ((list? x)                                    ; plain list -> array
      (string-append
       "["
       (fold-right
        (lambda (v acc)
          (if (string=? acc "")
              (json->string v)
              (string-append (json->string v) "," acc)))
        "" x)
       "]"))
     ;; Anything else is not a JSON value, and saying so beats
     ;; answering `null`.  It used to answer null -- for a char, a
     ;; procedure, a bytevector, an improper pair, the unspecified
     ;; value -- which is the same shape as the infinity that used to
     ;; be spelled null: a legal value of the WRONG TYPE, indis-
     ;; tinguishable downstream from a null the caller meant.
     ;;
     ;; The symbol `null` is the spelling that means null and has its
     ;; own clause above; this one is only reached by things that have
     ;; no JSON reading at all.
     (else (error 'json->string "not a JSON value" x))))

  ;; ---- path access -------------------------------------------------------

  ;; arrays are VECTORS, objects alists -- see the header note.  The
  ;; single step json-ref folds, and where anyone tracing a path access
  ;; lands first.
  (define (ref1 x k)
    (cond
     ((and (vector? x) (integer? k))
      (and (>= k 0) (< k (vector-length x)) (vector-ref x k)))
     ((and (list? x) (or (string? k) (symbol? k)))
      (let ((key (if (symbol? k) (symbol->string k) k)))
        (let loop ((l x))
          (cond
           ((null? l) #f)
           ((and (pair? (car l)) (equal? (caar l) key)) (cdar l))
           (else (loop (cdr l)))))))
     (else #f)))

  ;; A JSON array is a vector; an object is an alist.  So `list?` says
  ;; #f for every array and #t for every object -- backwards from what a
  ;; caller reaching for it expects, and silent either way, since a
  ;; wrong branch here just does not run.  This is the same predicate
  ;; `vector?` under a name that answers the question actually being
  ;; asked, which is the only thing that makes it worth exporting: a
  ;; name is where this knowledge can live.
  (define (json-array? x) (vector? x))

  ;; The elements of an array, as a list.  SHALLOW: an element that is
  ;; itself an array comes back as a vector, because converting the
  ;; whole tree would silently change what every nested `json-array?`
  ;; answers -- a conversion that reaches further than the caller
  ;; expects is worse than one that stops where it says.
  ;;
  ;; A non-array argument RAISES rather than answering something. The
  ;; alternative -- '() for a non-vector -- would turn the mistake this
  ;; whole note is about into an empty loop body, which is the same
  ;; silence one level over.
  (define (json-array->list x)
    (unless (vector? x)
      (error 'json-array->list
             "not a JSON array (arrays are vectors here; objects are alists)"
             x))
    (let loop ((i (- (vector-length x) 1)) (acc '()))
      (if (< i 0) acc (loop (- i 1) (cons (vector-ref x i) acc)))))

  ;; arrays are VECTORS -- see the header note before writing (list? ...)
  (define (json-ref x . keys)
    (fold-left (lambda (acc k) (and acc (ref1 acc k))) x keys)))

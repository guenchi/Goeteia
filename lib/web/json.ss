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
;; ONE SPELLING PER VALUE, and the type comes from the OUTERMOST
;; CONSTRUCTOR -- you never look inside to find out what something is.
;; `(` opens an object, `#(` opens an array:
;;
;;     (("a" . #("b")))   -> {"a":["b"]}   a one-element array inside
;;     #((("a" . "b")))   -> [{"a":"b"}]   a one-key object inside
;;
;; A SYMBOL IS NOT A JSON VALUE HERE, in either position -- `null` is
;; the one exception, because it is the spelling that means null.  The
;; writer used to take `'foo` for a key or a value and spell it
;; `"foo"`, which made `'foo` and `"foo"` the same document.
;;
;; The reason for removing it is worth stating exactly, because the
;; short version is false and someone will measure it: symbols do NOT
;; leak here.  What leaks is `string->symbol` applied to text that came
;; from outside -- it interns an unbounded set from untrusted input --
;; and that call is in nobody's codec, it is in the program between
;; them.  A writer that accepts symbols is what makes
;;
;;     read -> intern the keys as symbols -> write back
;;
;; the obvious shape to write, and the middle step is the leak.  So
;; this narrowing removes an invitation, not a hole.  The reader is
;; untouched and has always produced string keys only.
;;
;; An array is a vector -- `#(1 2)` -- and nothing else; a pair is an
;; object.  The writer used to take a plain
;; list for an array too, and that is the question the next reader
;; will ask: why not accept both, it is more convenient.
;;
;; Because the two representations OVERLAP.  Once a list can be an
;; array and an alist is also a list, a pair-shaped value has two
;; readings and its type has to be decided by looking at its CONTENTS.
;; The first rule for doing that read only the head element, which put
;; a list of objects -- exactly what json-array->list hands back -- on
;; the object route, where json-escape got a pair and the runtime
;; stopped.  Reading the whole list fixed that instance and left the
;; overlap: `(("a" "b"))` was a legal one-entry alist AND a legal
;; one-element array, and no amount of looking decides between them.
;;
;; This is not Postel's law, and calling it that was the mistake.
;; Being liberal in what you accept means a WIDER DOMAIN -- more
;; values you handle correctly.  It does not mean a second spelling
;; for a value you already accept.  A second spelling buys nothing and
;; costs the ability to read a type off the representation, which is
;; the one thing that is constant-time and has no edge cases.
;;
;; (string->json s)   parse; raises #(json-error msg pos) on bad input
;; (json->string x)   serialize.  An array is a VECTOR; a pair is an
;;                    OBJECT.  The type is read off the shape, and
;;                    nothing about the contents changes it:
;;
;;                      (("a" . 1))       -> {"a":1}
;;                      #(("a" . 1))      -> [{"a":1}]
;;                      #(1 2 3)          -> [1,2,3]
;;                      (1 2 3)           -> refused, with the spelling
;;
;;                    '() is the empty OBJECT "{}"; the empty array is
;;                    #().  An empty list cannot say which it meant,
;;                    and the object side owns it.
;;
;;                    A plain list used to be an array as well.  Two
;;                    defects came out of that overlap and only the
;;                    first was an accident: `[{"a":1},{"b":2}]` taken
;;                    apart with json-array->list and handed back was
;;                    read as an object, and the runtime stopped; and
;;                    `(("a" "b"))` was a legal one-entry alist AND a
;;                    legal one-element array at the same time, which
;;                    no rule reading the contents could have decided.
;;                    Written here because the repair erases its own
;;                    evidence: with arrays spelled #(...) there is one
;;                    reading left and nothing shows there were two.
;;
;;                    RAISES `error` on a value with no JSON reading:
;;                    a char, a procedure, a bytevector, an improper
;;                    pair, the unspecified value, and A SYMBOL in
;;                    either position -- key or value -- except `null`.
;;                    ⚠ CHANGED, twice: those first five used to
;;                    serialize as `null`, silently, which is a legal
;;                    value of the wrong type and one the caller may
;;                    have meant; and a symbol used to serialize as the
;;                    string of its name, so `'foo` and `"foo"` were one
;;                    document.  If you were relying on either, the fix
;;                    is to convert before calling: `'null` for a JSON
;;                    null, a string for anything textual, and
;;                    `(symbol->string k)` for a key.
;; (json-ref x k ...) path access: string/symbol key for objects --
;;                    a symbol is a QUERY here, not a document, so it
;;                    stays accepted where the writer no longer takes
;;                    one; the asymmetry is the point, not an oversight,
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
;; That paragraph was true of the READER and false of the WRITER,
;; which quietly accepted a list for an array -- so the sentence
;; warning everyone about the rule was itself only half in force.  It
;; is in force now, both directions.
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
  ;; The same 64 (igropyr json) uses, and the same refusal, because a
  ;; text one of the two readers accepts and the other refuses is the
  ;; thing this port exists not to produce.  RFC 8259 section 9 grants
  ;; the limit explicitly.  Without it a nested text does not fail --
  ;; it exhausts the stack, which is not a JSON error and not
  ;; something the caller can guard, on input that came from outside.
  (define $max-depth 64)

  ;; A LOCAL RESOURCE GUARD, and deliberately not $max-depth.  The two
  ;; numbers answer different questions and must not be aligned:
  ;;
  ;;   $max-depth (64) is a WIRE CONTRACT.  It is the same 64 that
  ;;   (igropyr json) refuses at, word for word, and changing it means
  ;;   changing both libraries in one batch.
  ;;
  ;;   this one only keeps a recursion off the end of the stack.  It
  ;;   is not a contract with anybody, and the number that belongs
  ;;   here is a property of the RUNTIME, so it need not match
  ;;   igropyr's guard either -- Chez has a deep native stack, we run
  ;;   on whatever the host gives us.
  ;;
  ;; Reusing 64 here was a defect, not a tidiness: the pipeline is
  ;; read -> wrap -> write, so what the writer sees is always the
  ;; reader's ceiling PLUS however many levels the application added.
  ;; Parse a legal 64-deep document, put it under {"result": ...},
  ;; send it back, and the writer refused at 65 -- on input nothing
  ;; was wrong with, giving anyone outside a reliable way to make us
  ;; raise.
  ;;
  ;; 1024, measured rather than chosen: with this guard disabled, the
  ;; writer completed at 3072 and exhausted the stack at 3584 (node,
  ;; this host, all three container shapes agreeing within a factor).
  ;; That leaves 16x over the reader's ceiling -- room for any amount
  ;; of wrapping -- and about 3x under the point where it actually
  ;; breaks.  The 3x is the part that matters, and it is not slack: a
  ;; BROWSER stack is typically smaller than node's, so the measured
  ;; figure is an upper bound on other hosts, not a guarantee.
  (define $write-guard-depth 1024)

  ;; ---- parser -----------------------------------------------------------

  ;; One definition each, above both users: the reader refuses a
  ;; literal that reads as an infinity and the writer refuses to spell
  ;; one, and those two answers have to come from the same predicate or
  ;; they can drift into disagreeing about the same value.
  ;; The sign of a zero cannot survive the exact stage: (- 0) is 0,
  ;; and exact->inexact then has nothing left to carry.  So it is
  ;; reapplied here, once, for every path that produces a flonum.
  ;;
  ;; It matters because "-0.0" is in JSON's grammar and (igropyr json)
  ;; reads it as a negative zero and writes it back as one -- measured
  ;; against Chez, not assumed.  A reader that answers +0.0 makes the
  ;; two libraries give one text two values, with nothing downstream
  ;; able to see the difference except by dividing.
  ;;
  ;; Built, not written.  That was once forced -- the reader collapsed
  ;; a -0.0 literal into +0.0 -- and now it is a choice: the literal
  ;; works, but building the value keeps this code independent of the
  ;; reader it is not testing (test/trig.ss builds its own for the
  ;; same reason).  And a MULTIPLICATION -- (fl+ x 0.0) collapses the
  ;; sign, which is correct IEEE behaviour and exactly why it cannot
  ;; be used here.
  ;;
  ;; "-0" is not this function's business: with no fraction and no
  ;; exponent it stays an exact zero, which is what the counterpart
  ;; answers too, and an exact zero has no sign to carry.
  (define (signed-float v neg)
    (let ((f (exact->inexact v)))
      (if (and neg (fl=? f 0.0)) (fl* -1.0 0.0) f)))

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
      (define (parse-value i depth)
        (when (> depth $max-depth) (jfail "nesting too deep" i))
        (let ((i (skip-ws i)))
          (when (>= i n) (jfail "unexpected end of input" i))
          (let ((ch (string-ref s i)))
            (cond
             ((char=? ch #\{) (parse-object (+ i 1) (+ depth 1)))
             ((char=? ch #\[) (parse-array (+ i 1) (+ depth 1)))
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
      (define (parse-object i depth)
        (let ((i (skip-ws i)))
          (if (and (< i n) (char=? (string-ref s i) #\}))
              (values '() (+ i 1))
              (let loop ((i i) (acc '()))
                (let ((i (skip-ws i)))
                  (unless (and (< i n) (char=? (string-ref s i) #\"))
                    (jfail "expected object key" i))
                  (let-values (((key i) (parse-string (+ i 1))))
                    (let ((i (expect #\: (skip-ws i))))
                      (let-values (((val i) (parse-value i depth)))
                        (let ((i (skip-ws i)))
                          (cond
                           ((and (< i n) (char=? (string-ref s i) #\,))
                            (loop (+ i 1) (cons (cons key val) acc)))
                           ((and (< i n) (char=? (string-ref s i) #\}))
                            (values (reverse (cons (cons key val) acc))
                                    (+ i 1)))
                           (else (jfail "expected , or } in object" i))))))))))))
      (define (parse-array i depth)
        (let ((i (skip-ws i)))
          (if (and (< i n) (char=? (string-ref s i) #\]))
              (values (vector) (+ i 1))
              (let loop ((i i) (acc '()))
                (let-values (((val i) (parse-value i depth)))
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
                          (values (finite! (signed-float v neg) i) j2))))
                    (let ((v (if dot?
                                 (finite!
                                  (signed-float
                                   (let ((m (/ (+ (* ip (pow10 fk)) fp)
                                               (pow10 fk))))
                                     (if neg (- m) m))
                                   neg)
                                  i)
                                 (if neg (- ip) ip))))
                      (values v j))))))))
      ;; top level: one value, then only whitespace
      (let-values (((v end) (parse-value 0 0)))
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
     ;; REAL, not "exact".  A JSON number is a real number, and that is
     ;; the question this clause has to ask: an exact COMPLEX satisfies
     ;; `exact?`, went through exact->inexact, and stopped the runtime
     ;; on an illegal cast -- a trap, not the "JSON numbers must be
     ;; real" error waiting two lines below.  Its inexact spelling
     ;; reached that error and raised properly, so the two spellings of
     ;; one wrong value behaved differently, and the worse one was the
     ;; one a caller is more likely to write.
     ((real? v)
      (let ((f (if (flonum? v) v (exact->inexact v))))
        (if (or (fl-nan? f) (fl-inf? f)) "null" (number->string f))))
     (else (error 'json->string "JSON numbers must be real" v))))

  ;; The predicate that used to stand here decided OBJECT from ARRAY
  ;; by reading the list's contents, and the history is worth one
  ;; paragraph because it is the argument for not having it:
  ;;
  ;;   version one read the head element only.  A list of objects has
  ;;   a pair for its head too, so the output of json-array->list came
  ;;   back and was taken for an object whose first KEY was the pair
  ;;   ("a" . 1); json-escape got a pair where a string belongs and
  ;;   the runtime stopped -- a trap, unguardable.
  ;;   version two read every element.  That fixed the instance and
  ;;   not the cause: `(("a" "b"))` is a legal one-entry alist and a
  ;;   legal one-element array at once, and reading further cannot
  ;;   decide between two legal answers.
  ;;
  ;; So the decision was removed instead of improved.  An array is a
  ;; vector; a pair is an object; the type comes from the outermost
  ;; constructor and nothing inside changes it.
  ;;
  ;; A member of an object, checked while it is written rather than
  ;; by a vote taken beforehand.  There is nothing left to decide:
  ;; a pair IS an object, because an array is a vector and only a
  ;; vector.  What remains is whether each member is well formed, and
  ;; a member that is not gets the sentence that says how to fix it.
  (define (member-key kv)
    (unless (pair? kv)
      (error 'json->string "a JSON array is a vector, not a list: #(a b) for [a,b], and ((\"k\" . #(v))) for {\"k\":[v]}; list->vector converts one" kv))
    (let ((k (car kv)))
      (cond ((string? k) k)
            (else
             ;; BOTH signposts, because a non-string key arrives two
             ;; ways and they need different repairs: `(k . 1)` is a
             ;; symbol key and wants quoting, while `((("a" . 1)))` is
             ;; a list that meant to be an array and wants
             ;; list->vector.  The message cannot tell which, so it
             ;; carries both -- and dropping either half breaks the
             ;; assertions that name it.
             (error 'json->string
                    (string-append
                     "an object key is a string: write (\"k\" . v), not (k . v)"
                     " -- and a JSON array is a vector, not a list:"
                     " #(a b) for [a,b]; list->vector converts one")
                    k)))))

  (define (json->string x) (json->string* x 0))

  (define (json->string* x depth)
    (when (> depth $write-guard-depth)
      (error 'json->string "nesting too deep" $write-guard-depth))
    (cond
     ((eq? x #t) "true")
     ((eq? x #f) "false")
     ((eq? x 'null) "null")
     ((number? x) (number->json x))
     ((string? x) (string-append "\"" (json-escape x) "\""))
     ;; `null` is answered above; every other symbol is refused here.
     ((symbol? x)
      (error 'json->string
             "a JSON string is a string: write \"foo\", not 'foo" x))
     ((vector? x)
      (string-append
       "["
       (let loop ((i 0) (acc ""))
         (if (= i (vector-length x))
             acc
             (loop (+ i 1)
                   (if (string=? acc "")
                       (json->string* (vector-ref x i) (+ depth 1))
                       (string-append
                        acc "," (json->string* (vector-ref x i) (+ depth 1)))))))
       "]"))
     ((null? x) "{}")                              ; the empty OBJECT
     ((pair? x)                                    ; alist -> object
      ;; No test of the contents decides this any more.  A pair is an
      ;; object; a list that meant to be an array is a mistake with a
      ;; one-call fix, and it is told so below rather than silently
      ;; taken for one thing or the other.
      (string-append
       "{"
       ;; The finiteness check is INSIDE this walk, and it has to be:
       ;; it used to live in the shape predicate that decided object
       ;; from array, and that predicate is gone because the decision
       ;; is gone.  Deleting it took the cycle guard with it -- the
       ;; guard was load-bearing for a reason unrelated to why the
       ;; predicate existed, and nothing said so.  A circular alist
       ;; walked here without end again, which is the defect that was
       ;; just repaired one module over.
       ;;
       ;; Two cursors in the same single pass, not a second traversal:
       ;; `slow` advances on every other step and meets `l` exactly
       ;; when the spine cycles.
       (let loop ((l x) (slow x) (step #f) (acc ""))
         (cond
          ((null? l) acc)
          ((not (pair? l))
           (error 'json->string
                  (string-append "an object is a proper list of pairs -- "
                                 "a JSON array is a vector, not a list: #(a b) for [a,b], and ((\"k\" . #(v))) for {\"k\":[v]}; list->vector converts one")
                  x))
          (else
           (let* ((entry (string-append
                          "\"" (json-escape (member-key (car l)))
                          "\":" (json->string* (cdr (car l)) (+ depth 1))))
                  (l* (cdr l))
                  (slow* (if step (cdr slow) slow)))
             (when (and step (pair? l*) (eq? l* slow*))
               (error 'json->string "an object's members cycle" x))
             (loop l* slow* (not step)
                   (if (string=? acc "") entry
                       (string-append acc "," entry)))))))
       "}"))
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

;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; goeteia prelude: the runtime library, written in goeteia's own
;; Scheme and compiled into every module.

(define (newline . p)
  (if (null? p) ($wb 10) ($write-byte-port (car p) 10)))

(define (display x . p)
  (if (null? p) ($display x) ($with-out (car p) (lambda () ($display x)))))
(define ($display x)
  (cond
   ((number? x) (%display-number x))
   ((char? x) ($wb (char->integer x)))
   ((string? x) (%display-string x 0))
   ((symbol? x) (%display-string (symbol->string x) 0))
   ((null? x) ($wb 40) ($wb 41))
   ((eq? x #t) ($wb 35) ($wb 116))
   ((eq? x #f) ($wb 35) ($wb 102))
   ((pair? x)
    ($wb 40)
    (display (car x))
    (%display-tail (cdr x)))
   ((vector? x)
    ($wb 35) ($wb 40)                    ; #(
    (let loop ((i 0))
      (when (< i (vector-length x))
        (unless (zero? i) ($wb 32))
        ($display (vector-ref x i))
        (loop (+ i 1))))
    ($wb 41))
   ((bytevector? x)
    (%display-string "#vu8(" 0)
    (let loop ((i 0))
      (when (< i (bytevector-length x))
        (unless (zero? i) ($wb 32))
        ($display (bytevector-u8-ref x i))
        (loop (+ i 1))))
    ($wb 41))
   ((%recbase? x)
    (%display-string "#<" 0)
    ($display (car (%record-rtd x)))
    ($wb 62))
   ((procedure? x) (%display-string "#<procedure>" 0))
   (else (%display-string "#<unknown>" 0))))

(define (%display-tail x)
  (cond
   ((null? x) ($wb 41))
   ((pair? x)
    ($wb 32)
    (display (car x))
    (%display-tail (cdr x)))
   (else
    ($wb 32) ($wb 46) ($wb 32)
    (display x)
    ($wb 41))))

(define (%display-string s i)
  (when (< i (string-length s))
    ($wb (char->integer (string-ref s i)))
    (%display-string s (+ i 1))))

(define (%display-number n)
  (cond
   ((flonum? n) ($display-flonum n))
   ((%bignum? n) ($display-bignum n))
   ((%ratio? n)
    (%display-number (%ratio-num n))
    ($wb 47)
    (%display-number (%ratio-den n)))
   ((%complex? n)
    (%display-number (%cx-re n))
    (let ((im (%cx-im n)))
      (unless (or (< im 0) (and (flonum? im) (fl<? im (fixnum->flonum 0))))
        ($wb 43))
      (%display-number im))
    ($wb 105))
   ((< n 0) ($wb 45) (%display-digits (- 0 n)))
   (else (%display-digits n))))
(%target-case
 (js
  ;; the host prints an arbitrary-precision integer directly
  (define ($display-bignum b) (%display-string (%big->str b) 0)))
 (wasm
  (define ($display-bignum b)
    (when ($bn-neg? b) ($wb 45))
    ($display-mag (%bignum-limbs b)))
  (define ($display-mag m)
    (if (and (= ($mag-len m) 1) (< (vector-ref m 0) 10))
        ($wb (+ 48 (vector-ref m 0)))
        (let ((qr ($mag-divmod-small m 10)))
          ($display-mag (car qr))
          ($wb (+ 48 (cdr qr))))))))
(define ($display-flonum x)
  (if (not (fl=? x x))
      (%display-string "+nan.0" 0)
      ($display-flonum* x)))
(define ($display-flonum* x)
  ;; Negative zero has to be asked for separately: (fl<? -0.0 0.0) is
  ;; false, so a plain sign test prints it as "0.0" and the text loses
  ;; a distinction the bits keep -- (fl/ 1.0 -0.0) is -inf.  Division
  ;; tells the two zeros apart, but ONLY zeros may be asked that way:
  ;; 1/-inf is -0.0, which is not less than zero, so negative infinity
  ;; would come back positive.  Hence the ordinary test first and the
  ;; division only for values that compare equal to zero.
  (let* ((zero (fixnum->flonum 0))
         (neg (or (fl<? x zero)
                  (and (fl=? x zero)
                       (fl<? (fl/ (fixnum->flonum 1) x) zero))))
         (mag (if neg (fl- zero x) x)))
    (when neg ($wb 45))
    (cond
     ;; Infinity has no digits, so it is spelled rather than computed.
     ;; It is recognised by being its own double: nothing finite and
     ;; non-zero satisfies that.
     ;;
     ;; +inf.0 and -inf.0 are the external representations, and they are
     ;; what string->number reads back -- so an infinity now survives the
     ;; round trip that every other flonum here already survived.  It
     ;; used to print "<big-flonum>", which is not a number, not a
     ;; symbol, and not readable as anything: the clause below recounts
     ;; what that cost when a millisecond timestamp carried it out of
     ;; (web json) with nothing raised anywhere.  That clause was
     ;; repaired and this one was not, six lines apart, and the comment
     ;; here called the placeholder continuity rather than the same
     ;; defect.
     ;;
     ;; The sign is already out for a negative -- $wb 45 above -- so only
     ;; the positive spelling carries its own +.
     ((and (not (fl=? mag zero)) (fl=? mag (fl* mag (fixnum->flonum 2))))
      (%display-string (if neg "inf.0" "+inf.0") 0))
     ;; Zero has no significant digits to find, and the search below
     ;; would not terminate looking for them: $dec-exponent walks
     ;; powers of ten toward a value it can never reach.  The sign was
     ;; written above, so both zeros come out spelled apart.
     ((fl=? mag zero) (%display-string "0.0" 0))
     ;; Past the FIXNUM cap, not past what a double can say.  %fl->fx
     ;; below is an i31 and stops at 2^29-1, so everything above that
     ;; used to print "<big-flonum>" -- and print it SUCCESSFULLY, which
     ;; is how {"t":<big-flonum>} left (web json) for a millisecond
     ;; timestamp with nothing raised anywhere.
     ;;
     ;; The integer part goes through the exact path instead: flfloor
     ;; is exact, `exact` on an integral flonum is exact, and
     ;; %display-digits reaches the bignum operations through the same
     ;; generic quotient/remainder it already used.  No rounding is
     ;; invented here and none should be: what comes out is the double's
     ;; own value.  1.7e12 IS an exact integer as a double, so it prints
     ;; as 1700000000000.0 and reads back as itself.
     ;;
     ;; What the fraction printer below actually does: twelve places
     ;; after the point, truncated rather than rounded, with no
     ;; exponent form, and a lookahead that stops as soon as the rest
     ;; is zero.  The lookahead is why 0.1 prints as "0.1" -- an
     ;; earlier note here said it printed its true expansion, which it
     ;; does not, and that sentence was the reason to believe the
     ;; printer was at least faithful.
     ;;
     ;; It is not faithful, and not only imprecise.  Measured: 0.12
     ;; prints 0.119999999999 and does not read back; 450 of the 999
     ;; values n/100 do not read back; and printing is not idempotent --
     ;; pi loses a place on each print-and-read and keeps losing.
     ;;
     ;; Near the twelfth place there is no clean threshold, which is
     ;; worth writing out because a reader will otherwise assume one:
     ;;
     ;;     1e-11  ->  0.000000000009   wrong digit, not a short one
     ;;     1e-12  ->  0.000000000000   a non-zero value reads as zero
     ;;     2e-12  ->  0.000000000001   wrong digit again
     ;;     9e-12  ->  0.000000000009   happens to read back
     ;;     1e-13  ->  0.000000000000   zero
     ;;
     ;; The wrong digits are the repeated multiply accumulating error
     ;; past the last place printed; the zeros are truncation with no
     ;; exponent form to fall back on.  They are two symptoms of the
     ;; same walk, and neither is a bound the other respects.
     ;;
     ;; The integer part is exact and none of this touches it.
     (else (%display-string ($shortest-decimal mag) 0)))))
;; ---- the shortest decimal that reads back as this double ----------
;;
;; A double is a rational with a power-of-two denominator, so its exact
;; decimal digits are computable with the integer arithmetic already
;; here.  The rounding happens ONCE, on an exact remainder, instead of
;; accumulating across repeated multiplications -- which is what the
;; old fraction walk did and why it emitted wrong digits rather than
;; merely short ones.
;;
;; Shortest is found by generate-and-test rather than by comparing
;; against the neighbouring doubles: emit d significant digits for
;; d = 1, 2, 3, ..., read each candidate back with this tree's own
;; reader, and stop at the first that is the original value.  At most
;; seventeen attempts, and no ulp machinery.  This rests on the reader
;; being exact, which was measured differentially against two other
;; implementations over 3020 doubles before this was written.

;; floor(log10 v) for an exact positive rational
(define ($dec-exponent v)
  (if (< v 1)
      (let down ((k -1) (p 1/10))
        (if (<= p v) k (down (- k 1) (/ p 10))))
      (let up ((k 0) (p 1))
        (if (< v (* p 10)) k (up (+ k 1) (* p 10))))))

;; round an exact rational to the nearest integer, halves away from zero
(define ($exact-round r)
  (let* ((n (numerator r)) (d (denominator r))
         (q (quotient n d))
         (rem (- n (* q d))))
    (if (>= (* 2 rem) d) (+ q 1) q)))

;; the decimal digits of a positive exact integer, as a list of chars
(define ($int-chars n)
  (let loop ((n n) (acc '()))
    (if (< n 10)
        (cons (integer->char (+ 48 n)) acc)
        (loop (quotient n 10)
              (cons (integer->char (+ 48 (remainder n 10))) acc)))))

(define ($zeros k) (let loop ((i k) (acc '())) (if (= i 0) acc (loop (- i 1) (cons #\0 acc)))))

;; digits + the position of the point -> the text, without an exponent
(define ($place-point ds k)
  (let ((n (length ds)))
    (cond
     ((< k 0) (list->string (append (list #\0 #\.) ($zeros (- (- k) 1)) ds)))
     ((>= k n) (list->string (append ds ($zeros (- (+ k 1) n)) (list #\. #\0))))
     (else
      (let split ((i 0) (l ds) (head '()))
        (if (= i (+ k 1))
            ;; a decimal point with nothing after it is not a number
            ;; this reader will take back, so the zero is written
            (list->string (append (reverse head) (list #\.)
                                  (if (null? l) (list #\0) l)))
            (split (+ i 1) (cdr l) (cons (car l) head))))))))

;; Rounding up can carry into an extra digit -- 9.99 becomes 10.0 -- and
;; the value is then a power of ten, so the digit the carry added is a
;; trailing zero that says nothing.  Dropping it and moving the point
;; one place keeps the count at d digits, which is what "shortest" is
;; counting.
(define ($drop-carry ds)
  (let loop ((l ds) (acc '()))
    (if (null? (cdr l)) (reverse acc) (loop (cdr l) (cons (car l) acc)))))

;; How many decimal digits identify a binary64.  The search below stops
;; here, and the spelling choice measures against it, so the two cannot
;; drift apart into two unrelated numbers.
(define $fl-max-digits 17)

;; The longest plain decimal whose characters are all informative: a
;; leading digit, a point, and every digit a double can distinguish.
(define $fl-max-decimal (+ $fl-max-digits 2))

;; The same digits spelled with an exponent: one digit, the rest after a
;; point, then e and the power.  No plus sign on a positive exponent --
;; the choice below is made on character count, so a sign that carries
;; no information would tip it.
(define ($exponent-form ds k)
  (list->string
   (append (list (car ds))
           (if (null? (cdr ds)) '() (cons #\. (cdr ds)))
           (list #\e)
           (if (< k 0) (list #\-) '())
           ($int-chars (if (< k 0) (- 0 k) k)))))

;; Both spellings name the same double.  The exponent is used only when
;; the plain decimal has grown longer than any double can justify.
;;
;; $fl-max-digits is how many decimal digits a binary64 needs to be
;; identified -- the same bound the search above stops at -- so a
;; decimal spelling of a leading digit, a point and that many digits is
;; the longest one whose every character is still telling the reader
;; something.  Past it the extra characters are positional padding:
;; zeros standing in for an exponent.  That is the condition here, and
;; it is a property of the FORMAT rather than a preference about how
;; numbers should look.  (The sign is not counted because the caller
;; has already written it.)
;;
;; Two rules were tried before this one and both were constant-free,
;; derivable, and wrong.  "Use the exponent where a plain decimal
;; cannot round-trip" never fires at all -- a decimal always
;; round-trips given enough zeros, so 1e-320 came out as three hundred
;; and twenty-two characters.  "Use whichever spelling is shorter"
;; fires far too often: 1e2 beats 100.0 by two characters and is not
;; what anyone wants to read.  Both are recorded here because a rule
;; that was tried and replaced is worth more to the next reader than
;; one that looks obvious, and without the note they will re-derive
;; them.  What decides a rule is its output, not its shape.
(define ($shorter-spelling dec ds k mag)
  (let ((exp-form ($exponent-form ds k)))
    (if (and (> (string-length dec) $fl-max-decimal)
             (fl=? (string->number exp-form) mag))
        exp-form
        dec)))

;; the shortest text that reads back as mag, mag positive and finite
;; How long the plain decimal would be, without building it.  The
;; extreme values are exactly the ones whose decimal is enormous, so
;; measuring it by construction would spend the time this is trying to
;; avoid.
(define ($decimal-length ds k)
  (let ((n (length ds)))
    (cond ((< k 0) (+ 2 (- (- k) 1) n))
          ((>= k n) (+ (+ k 1) 2))
          (else (+ n 1)))))

;; nearest integer to a/b, halves away from zero; a and b non-negative,
;; b positive.  Integer arithmetic only: see the note in
;; $shortest-decimal about why no rational appears here.
(define ($round-quotient a b)
  (quotient (+ (* 2 a) b) (* 2 b)))

(define ($shortest-decimal mag)
  ;; The scaling is done, and this is the point of the whole routine,
  ;; on the numerator and denominator as
  ;; INTEGERS and never as a rational.  A double's exact value has a
  ;; denominator around 2^1050, so every rational multiply reduces by a
  ;; gcd of two thousand-bit numbers: measured, that one operation cost
  ;; 73ms for a value near 1e-300, and the same arithmetic done on
  ;; integers costs 0.55ms.  A printer that takes a second reads as a
  ;; hang, and a suite reports a hang as a timeout, which is a category
  ;; that hides its own cause.
  (let* ((ex (inexact->exact mag))
         (n0 (numerator ex))
         (d0 (denominator ex))
         (k ($dec-exponent ex)))
    ;; scale by a power of ten in whichever direction it goes.
    ;; %expt-int counts DOWN to zero, so a negative exponent never
    ;; reaches its base case -- it does not return.  Every use here
    ;; therefore asks for a non-negative power and divides instead of
    ;; multiplying when the scale is the other way.
    ;; The candidates all share a prefix: the d-digit rounding is the
    ;; full-precision one shortened.  So the expensive division -- the
    ;; one whose operands are as wide as the double's exact value --
    ;; happens ONCE, and each candidate is derived from it by dividing
    ;; a $fl-max-digits-wide integer by a small power of ten.  Doing it
    ;; per candidate cost seventeen wide divisions, measured at 6.7ms
    ;; for a value near 1e-300 against 0.4ms for one.
    ;;
    ;; Shortening a rounded number rounds twice, which can differ by
    ;; one in the last place from rounding the original directly.  That
    ;; costs nothing here: every candidate is checked by reading it
    ;; back, so a candidate that differs simply fails and the next
    ;; length is tried.  The full-precision case is exact.
    (let* ((up (+ (- 0 k) (- $fl-max-digits 1)))
           (numF (if (>= up 0) (* n0 (%expt-int 10 up)) n0))
           (denF (if (>= up 0) d0 (* d0 (%expt-int 10 (- up)))))
           (nF ($round-quotient numF denF)))
      (let try ((d 1))
        (if (> d $fl-max-digits)
            ;; $fl-max-digits always identify a double, so this is
            ;; unreachable; it is written safely rather than left as
            ;; the one branch that could hang.
            ($place-point ($int-chars nF) k)
            (let* ((n (if (= d $fl-max-digits)
                          nF
                          ($round-quotient nF (%expt-int 10 (- $fl-max-digits d)))))
                   ;; rounding up can carry into an extra digit
                   ;; (9.99 -> 10.0), which moves the point one place
                   (ds0 ($int-chars n))
                   (carry? (> (length ds0) d))
                   (ds (if carry? ($drop-carry ds0) ds0))
                   (kk (if carry? (+ k 1) k))
                   ;; the spelling is chosen from the LENGTH the decimal
                   ;; would have, so an enormous decimal is never built
                   ;; only to be measured and discarded
                   (text (if (> ($decimal-length ds kk) $fl-max-decimal)
                             ($exponent-form ds kk)
                             ($place-point ds kk))))
              (if (fl=? (string->number text) mag)
                  text
                  (try (+ d 1)))))))))

(define ($display-frac f i)
  ;; up to 12 digits, trimmed via lookahead: stop when the rest is 0
  (if (or (= i 12) (fl=? f (fixnum->flonum 0)))
      (when (zero? i) ($wb 48))
      (let* ((scaled (fl* f (fixnum->flonum 10)))
             (d (%fl->fx scaled)))
        ($wb (+ 48 d))
        ($display-frac (fl- scaled (fixnum->flonum d)) (+ i 1)))))

(define (%display-digits n)
  (if (< n 10)
      ($wb (+ 48 n))
      (begin
        (%display-digits (quotient n 10))
        ($wb (+ 48 (remainder n 10))))))

(define (string=? a b)
  (and (= (string-length a) (string-length b))
       (%string-eq-from a b 0)))

(define (%string-eq-from a b i)
  (or (= i (string-length a))
      (and (eq? (string-ref a i) (string-ref b i))
           (%string-eq-from a b (+ i 1)))))

(define (list . args) args)

(define (length ls)
  (%length ls 0))
(define (%length ls n)
  (if (null? ls) n (%length (cdr ls) (+ n 1))))

(define (append . ls)
  (cond
   ((null? ls) '())
   ((null? (cdr ls)) (car ls))
   (else ($append2 (car ls) (apply append (cdr ls))))))
(define ($append2 a b)
  ($rev-onto (reverse a) b))
(define ($rev-onto rev tail)
  (if (null? rev)
      tail
      ($rev-onto (cdr rev) (cons (car rev) tail))))

(define (filter pred ls) ($filter-acc pred ls '()))
(define ($filter-acc pred ls acc)
  (cond
   ((null? ls) (reverse acc))
   ((pred (car ls)) ($filter-acc pred (cdr ls) (cons (car ls) acc)))
   (else ($filter-acc pred (cdr ls) acc))))

(define (reverse ls)
  (%reverse ls '()))
(define (%reverse ls acc)
  (if (null? ls) acc (%reverse (cdr ls) (cons (car ls) acc))))

(define (memq x ls)
  (cond
   ((null? ls) #f)
   ((eq? (car ls) x) ls)
   (else (memq x (cdr ls)))))

(define (assq x ls)
  (cond
   ((null? ls) #f)
   ((eq? (caar ls) x) (car ls))
   (else (assq x (cdr ls)))))

(define (remq x ls)
  (cond
   ((null? ls) '())
   ((eq? (car ls) x) (remq x (cdr ls)))
   (else (cons (car ls) (remq x (cdr ls))))))

(define (caar p) (car (car p)))
(define (cadr p) (car (cdr p)))
(define (cdar p) (cdr (car p)))
(define (cddr p) (cdr (cdr p)))

(define (equal? a b)
  (cond
   ((pair? a) (and (pair? b)
                   (equal? (car a) (car b))
                   (equal? (cdr a) (cdr b))))
   ((string? a) (and (string? b) (string=? a b)))
   ((vector? a)
    (and (vector? b)
         (= (vector-length a) (vector-length b))
         (let loop ((i 0))
           (or (= i (vector-length a))
               (and (equal? (vector-ref a i) (vector-ref b i))
                    (loop (+ i 1)))))))
   ;; Bytevectors compare by content, like the other aggregates.  They
   ;; used to fall through to eqv?, so two bytevectors with identical
   ;; bytes were not equal? -- and the failure direction is the quiet
   ;; one: an assertion that two differ was satisfied for free, by
   ;; every pair of bytevectors in existence.
   ((bytevector? a)
    (and (bytevector? b) (bytevector=? a b)))
   (else (eqv? a b))))

;; Multiple values: a list tagged with a unique pair, collapsing to
;; the value itself in the single-value case.
(define $values-tag (cons 0 0))

(define (values . args)
  (if (and (pair? args) (null? (cdr args)))
      (car args)
      (cons $values-tag args)))

(define (call-with-values producer consumer)
  (let ((v (producer)))
    (if (and (pair? v) (eq? (car v) $values-tag))
        (apply consumer (cdr v))
        (consumer v))))

;; ---- strings <-> lists ----

(define (list->string ls)
  (let ((s (%make-string (length ls))))
    (%fill-string s ls 0)
    s))
(define (%fill-string s ls i)
  (unless (null? ls)
    (string-set! s i (car ls))
    (%fill-string s (cdr ls) (+ i 1))))

(define (string->list s)
  (%string->list s (- (string-length s) 1) '()))
(define (%string->list s i acc)
  (if (< i 0)
      acc
      (%string->list s (- i 1) (cons (string-ref s i) acc))))

;; ---- runtime symbol interning ----
;;
;; The table starts as the compile-time interned symbols (pulled
;; lazily from the module), so read and string->symbol agree with
;; symbol literals under eq?.

(define $symtab #f)

(define (string->symbol s)
  (when (eq? $symtab #f)
    (set! $symtab (%interned-symbols)))
  (%intern s $symtab))
(define (%intern s tab)
  (cond
   ((null? tab)
    (let ((sym (%make-symbol s)))
      (set! $symtab (cons sym $symtab))
      sym))
   ((string=? (symbol->string (car tab)) s) (car tab))
   (else (%intern s (cdr tab)))))

;; ---- ports ----
;;
;; Console I/O rides the two host imports; string ports are plain
;; records.  The reader and the printers dispatch through the current
;; ports, so with-output-to-string and friends need no host support.

(define-record-type ($port $make-port port?)
  (fields (immutable kind $port-kind)
          (mutable a $port-a $port-a!)
          (mutable b $port-b $port-b!)
          ;; where the reader stands in this port: line (from 1) and
          ;; bytes consumed on that line.  Live counting happens in
          ;; globals (see %next-byte); these fields are the parking
          ;; place $with-in uses, so a port that is read from twice
          ;; keeps counting where it left off.
          (mutable line $port-line $port-line!)
          (mutable col $port-col $port-col!)))
;; kinds: console-in (a = one-byte pushback), console-out,
;;        string-in (a = string, b = position),
;;        string-out (a = reversed char list)

(define $console-in ($make-port 'console-in -2 0 1 0))
(define $console-out ($make-port 'console-out 0 0 1 0))
(define $cip $console-in)
(define $cop $console-out)
(define (current-input-port) $cip)
(define (current-output-port) $cop)
(define (input-port? p)
  (and (port? p) (memq ($port-kind p) '(console-in string-in file-in))))
(define (output-port? p)
  (and (port? p) (memq ($port-kind p) '(console-out string-out file-out))))

(define (open-input-string s) ($make-port 'string-in s 0 1 0))
(define (open-output-string) ($make-port 'string-out '() 0 1 0))
(define (get-output-string p) (list->string (reverse ($port-a p))))

(define ($peek-byte-port p)
  (let ((k ($port-kind p)))
    (cond
     ((eq? k 'console-in)
      (when (= ($port-a p) -2) ($port-a! p (%read-byte)))
      ($port-a p))
     ((eq? k 'string-in)
      (let ((s ($port-a p)) (i ($port-b p)))
        (if (< i (string-length s))
            (char->integer (string-ref s i))
            -1)))
     ((eq? k 'file-in)
      (when (= ($port-b p) -2) ($port-b! p (%fread ($port-a p))))
      ($port-b p))
     (else (errorf 'read "not an input port")))))
;; Where the reader stands in the current input port.  The compiler
;; reads its source through this counter and error context wants
;; file:line; the reader's own diagnostics want a column too.
;;
;; Lines count from 1.  $reader-column counts BYTES consumed on the
;; current line, so after consuming a byte it is that byte's 1-based
;; column -- and a multi-byte UTF-8 character spans as many columns as
;; it has bytes, matching the latin-1 view the reader takes of source.
(define $reader-line 1)
(define $reader-column 0)
(define $reader-datum-line 1)

;; A driver that splices many files into one stream can say which
;; file the stream is currently in, and where its line 1 fell: set
;; $reader-file to the name and $reader-line-origin so that
;; (stream line - origin) is the line in that file.  The reader's
;; diagnostics then name the file the author wrote rather than the
;; stream nobody sees.  Left alone -- which is the case for every
;; program that merely calls read -- positions are the stream's own.
(define $reader-file "")
(define $reader-line-origin 0)

(define ($next-byte-port p)
  (let ((b ($peek-byte-port p)))
    (let ((k ($port-kind p)))
      (cond
       ((eq? k 'console-in) ($port-a! p -2))
       ((eq? k 'file-in) ($port-b! p -2))
       ((eq? k 'string-in)
        (when (< -1 b) ($port-b! p (+ ($port-b p) 1))))))
    b))
(define ($write-byte-port p byte)
  (let ((k ($port-kind p)))
    (cond
     ((eq? k 'console-out) (%write-byte byte))
     ((eq? k 'string-out)
      ($port-a! p (cons (integer->char byte) ($port-a p))))
     ((eq? k 'file-out) (%fwrite ($port-a p) byte))
     (else (errorf 'write "not an output port")))))

;; One byte of pushback.  The line-ending forms are multi-byte -- NEL is
;; C2 85 and LS is E2 80 A8 -- so recognising one means looking past a
;; byte that may turn out to be data.  Without somewhere to put it back
;; every caller had to be told what was speculatively eaten, and the
;; three callers handled it three ways; with it the recogniser is one
;; procedure that consumes exactly what it matched.
(define $pushed -1)
(define (%push-back b)
  (set! $pushed b)
  (when (< 0 $reader-column) (set! $reader-column (- $reader-column 1))))
(define (%peek-byte) (if (< -1 $pushed) $pushed ($peek-byte-port $cip)))
;; the reader's byte source, and the one place the position advances:
;; two integer updates, no allocation, on the hottest path there is
(define (%next-byte)
  (let ((b (if (< -1 $pushed)
               (let ((p $pushed)) (set! $pushed -1) p)
               ($next-byte-port $cip))))
    (cond
     ((= b 10) (set! $reader-line (+ $reader-line 1))
               (set! $reader-column 0))
     ((< -1 b) (set! $reader-column (+ $reader-column 1))))
    b))
(define ($wb byte) ($write-byte-port $cop byte))

(define ($with-out p thunk)
  (let ((old $cop))
    (dynamic-wind
      (lambda () (set! $cop p))
      thunk
      (lambda () (set! $cop old)))))
(define ($with-in p thunk)
  ;; park the live position in the port being left and pick up the
  ;; one belonging to the port being entered, so every port keeps its
  ;; own place across separate reads (and a nested read cannot move
  ;; the outer stream's line number)
  (let ((old $cip))
    (dynamic-wind
      (lambda () ($set-in! old p))
      thunk
      (lambda () ($set-in! p old)))))
(define ($set-in! from to)
  ($port-line! from $reader-line)
  ($port-col! from $reader-column)
  (set! $cip to)
  (set! $reader-line ($port-line to))
  (set! $reader-column ($port-col to)))
(define (with-output-to-string thunk)
  (let ((p (open-output-string)))
    ($with-out p thunk)
    (get-output-string p)))
(define (with-input-from-string s thunk)
  ($with-in (open-input-string s) thunk))

;; Bytes taken from the CURRENT input port move the reader position;
;; a read-char naming some other port does not (that port's parked
;; position, and any later read from it, is off by what was taken).
(define (read-char . p)
  (let ((b (if (or (null? p) (eq? (car p) $cip))
               (%next-byte)
               ($next-byte-port (car p)))))
    (if (< b 0) (eof-object) (integer->char b))))
(define (peek-char . p)
  (let ((b ($peek-byte-port (if (null? p) $cip (car p)))))
    (if (< b 0) (eof-object) (integer->char b))))
(define (write-char c . p)
  ($write-byte-port (if (null? p) $cop (car p)) (char->integer c)))

;; ---- the reader ----

;; "line L column C", the one place a reader diagnostic spells a
;; position.  Callers pass the position they captured, not the live
;; counter: the mistake a reader reports is nearly always where a
;; construct was OPENED, and by the time it is detected the counter
;; has run on to the end of the input.
;;
;; The line is mapped back through $reader-line-origin, so a driver
;; that concatenates files reports the author's line, and the file
;; name leads when one is known.
(define (%at-line line col)
  (string-append $reader-file
                 (if (string=? $reader-file "") "" " ")
                 "line " (number->string (- line $reader-line-origin))
                 " column " (number->string col)))

(define (read . p)
  (if (null? p)
      ;; console = the compile stream: remember where this datum
      ;; starts, for error context.
      ;;
      ;; Comments come first, and a comment can span lines: `#;`
      ;; discards a datum that may be several lines long, `#| |#` the
      ;; same.  The line to remember is where the SURVIVING datum
      ;; starts, not where the comment before it did -- a form
      ;; attributed to the comment above it reads as a right line,
      ;; which is worse than no line at all.
      (let skip ()
        (%skip-blanks)
        (if (= (%peek-byte) 35)                    ; #
            (begin
              (%next-byte)
              (if (%skip-hash-comment)
                  (skip)
                  ;; not a comment: the `#` opens the datum itself,
                  ;; and this is its line
                  (begin (set! $reader-datum-line $reader-line)
                         (%read-hash))))
            (begin (set! $reader-datum-line $reader-line)
                   ($read))))
      ($with-in (car p) (lambda () ($read)))))
(define ($read)
  (%skip-blanks)
  (let ((b (%peek-byte)))
    (cond
     ((< b 0) (eof-object))
     ((= b 40) (%next-byte) (%read-list))          ; (
     ((= b 41)                                     ; ) with nothing open
      (%next-byte)
      (errorf 'read (string-append "unexpected ) at "
                                   (%at-line $reader-line $reader-column))))
     ((= b 39) (%next-byte) (list 'quote ($read)))  ; '
     ((= b 96) (%next-byte) (list 'quasiquote ($read))) ; `
     ((= b 44)                                     ; , or ,@
      (%next-byte)
      (if (= (%peek-byte) 64)
          (begin (%next-byte) (list 'unquote-splicing ($read)))
          (list 'unquote ($read))))
     ((= b 34)                                     ; "
      (%next-byte)
      (%read-string $reader-line $reader-column '()))
     ((= b 35)                                     ; #
      (%next-byte)
      ;; Neither comment form is a datum, so neither can be the value of
      ;; a read: both consume text and then ask for the next datum.
      ;; That is why they are handled here and not in %read-hash, which
      ;; has to answer with something.
      (if (%skip-hash-comment) ($read) (%read-hash)))
     (else (let ((r (%read-atom '() #f)))
             (%finish-atom (cdr r) (car r)))))))

;; An atom's bytes, with the two escape forms understood.
;;
;; This could not live in %read-token: that stops at the first
;; delimiter, and `;` IS one, so `a\x20;b` tokenised as `a\x20`
;; followed by a comment -- the escape's own terminator ended the
;; token.  Every name the writer escapes would have come back wrong,
;; and quietly, because the truncated name is still a symbol.
;;
;; Answers (escaped? . bytes).  The flag matters: `\x31;` denotes the
;; SYMBOL 1, and without it %finish-atom would classify the decoded
;; bytes as the number.  An escape is how a name says it is a name.
(define (%read-atom acc esc)
  (let ((b (%peek-byte)))
    (cond
     ((%delimiter? b) (cons esc (reverse acc)))
     ;; a bare `#` ends a name.  Both spellings that PUT one in a name
     ;; are unaffected: |a#b| is consumed by the bar loop below, and
     ;; a\x23;b arrives through the escape branch, so neither reaches
     ;; this test.
     ((= b 35) (cons esc (reverse acc)))
     ((= b 124)                                    ; | ... |
      (%next-byte)
      (let bar ((acc acc))
        (let ((c (%next-byte)))
          (cond
           ((< c 0)
            (errorf 'read
                    (string-append "a |...| symbol reaches end of input at "
                                   (%at-line $reader-line $reader-column))))
           ((= c 124) (%read-atom acc #t))
           (else (bar (cons c acc)))))))
     ((= b 92)                                     ; backslash
      (%next-byte)
      (let ((c (%next-byte)))
        (if (= c 120)                              ; x
            (%read-atom (%push-utf8
                         (%read-hex-escape $reader-line $reader-column) acc)
                        #t)
            (errorf 'read
                    (string-append "a backslash in a symbol must begin \\x, not \\"
                                   (if (< c 0) "<end of input>"
                                       (string (integer->char c)))
                                   " at "
                                   (%at-line $reader-line $reader-column))))))
     (else (%next-byte) (%read-atom (cons b acc) esc)))))

(define (%delimiter? b)
  (or (< b 0) (= b 32) (= b 10) (= b 9) (= b 13)
      (= b 40) (= b 41) (= b 59) (= b 34)))

(define (%skip-blanks)
  (let ((b (%peek-byte)))
    (cond
     ((or (= b 32) (= b 10) (= b 9) (= b 13))
      (%next-byte)
      (%skip-blanks))
     ((= b 59)                                     ; ;
      (%skip-line)
      (%skip-blanks))
     (else #f))))
(define (%skip-line)
  ;; ends on ANY line ending, which is one of the three callers of
  ;; %line-ending? -- it used to end only on LF, so a comment closed by
  ;; a CR ran on and swallowed the next form on this host while the
  ;; reference read it
  (let ((b (%next-byte)))
    (unless (or (< b 0) (%line-ending? b))
      (%skip-line))))

(define (%read-token acc)
  (if (%delimiter? (%peek-byte))
      (reverse acc)
      (%read-token (cons (%next-byte) acc))))

;; The same scan, for a NAME rather than a number token: `#` ends it
;; too.  R6RS does not let a bare `#` sit inside an identifier, and the
;; writer already agrees -- test/symbol-quoting.ss pins that the name
;; "a#b" is emitted as a\x23;b -- so only the reader disagreed, and
;; `abc#|c|#` came back as the symbol abc#c# with the comment eaten.
;;
;; This is a SIBLING rather than a flag on %read-token, and %read-token
;; keeps its behaviour exactly.  Its one remaining caller reads a
;; NUMBER token, where `#` must NOT end the scan: %read-prefixed gathers
;; the whole token and peels the prefixes off afterwards, so the `#` of
;; `#x` in `#e#x10` is INSIDE the token it is reading.  Widening the
;; shared scanner would break every stacked prefix, and it would break
;; them far from the edit; a caller that wants the other shape asks for
;; it by name.
;;
;; Nothing ENFORCES that choice: both scanners take the same argument,
;; so a future name scan that reached for %read-token would compile and
;; be wrong.  What carries the weight is that %read-token has exactly
;; ONE caller, the number path, and this comment names it.
(define (%read-name-token acc)
  (let ((b (%peek-byte)))
    (if (or (%delimiter? b) (= b 35))
        (reverse acc)
        (%read-name-token (cons (%next-byte) acc)))))

(define (%finish-atom bs escaped?)
  (cond
   ;; An escaped name is a NAME.  `\x31;` is the symbol 1, not the
   ;; number; `||` is the empty symbol, not an empty token.  Deciding
   ;; that from the decoded bytes alone is impossible -- they are the
   ;; same bytes either way -- so the tokenizer carries the flag.
   (escaped? (string->symbol (%bytes->string bs)))
   ;; A lone dot is not a symbol.  Inside a list it is the dotted-tail
   ;; marker and never reaches here; standing alone it is the one
   ;; spelling in this whole face that Chez refuses outright, and
   ;; letting it become a symbol would make `(read ".")` answer a datum
   ;; where the reference answers an error.
   ((and (pair? bs) (null? (cdr bs)) (= (car bs) 46))
    (errorf 'read (string-append "a lone . is not a datum at "
                                 (%at-line $reader-line $reader-column))))
   ((%bytes->number bs) => (lambda (v) v))
   ;; Number-shaped and denoting no number.  Refused by name rather than
   ;; allowed to become a symbol: the reader answered an error here
   ;; before this file grew a second caller, and a token silently
   ;; turning into the symbol 1/0 would be a change nobody asked for.
   ((%denominator-zero-token? bs) (%denominator-zero-error))
   (else (string->symbol (%bytes->string bs)))))

;; WHAT IS A NUMBER, once.  %finish-atom had these five clauses and
;; string->number had two of them, so the public procedure was a proper
;; subset of the reader: ratios, complexes and the non-finite spellings
;; read from source and answered #f from text.  The face is stated here
;; and both callers reach it -- the discipline %body->number already
;; keeps for the four radices, which is why writing a second recogniser
;; inside string->number would have been the wrong repair for a defect
;; that IS a second recogniser.
;;
;; -> a number, or #f.  What #f MEANS is the caller's to say: the reader
;; asks %denominator-zero-token? and refuses, string->number stops here.
(define (%bytes->number bs)
  (cond
   ((%special-number bs) => (lambda (v) v))
   ((%number-token? bs) (%parse-int bs))
   ((%decimal-token? bs) (%parse-decimal bs))
   ((%ratio-token? bs) (%parse-ratio bs))
   ((%complex-token? bs) (%parse-complex bs))
   (else #f)))
(define (%split-at bs byte)
  ;; -> (before . after) at the first occurrence, or #f
  (let loop ((pre '()) (bs bs))
    (cond
     ((null? bs) #f)
     ((= (car bs) byte) (cons (reverse pre) (cdr bs)))
     (else (loop (cons (car bs) pre) (cdr bs))))))
;; A zero denominator is NOT a ratio token.  It has the shape and
;; denotes nothing, so the recognisers answer no and each caller says
;; what that means: string->number answers #f, and %finish-atom refuses
;; it by name rather than letting it become a symbol.
(define (%ratio-token? bs)
  (let ((halves (%split-at bs 47)))                ; /
    (and halves
         (%number-token? (car halves))
         (pair? (cdr halves))
         (%all-digits? (cdr halves))
         (not (%all-zero-digits? (cdr halves))))))

;; Ratio-shaped with a zero denominator: what %ratio-token? just
;; refused, told apart from text that is not a numeral at all.
;;
;; A zero denominator has THREE positions, not one: the token itself,
;; and either half of a complex numeral.  (read "1/0+2i") refused this
;; before and must go on refusing it -- Chez does too -- so the test
;; follows %complex-token? into the halves rather than stopping at the
;; whole token.  It reuses %split-imag rather than restating how a
;; complex numeral comes apart; that splitter already has two callers
;; and this is the third.
(define (%denominator-zero-token? bs)
  (or (%zero-denominator-ratio? bs)
      (let ((rev (reverse bs)))
        (and (pair? rev)
             (= (car rev) 105)                     ; trailing i
             (let ((split (%split-imag (reverse (cdr rev)))))
               (and split
                    (or (%zero-denominator-ratio? (car split))
                        (%zero-denominator-ratio? (cdr split)))))))))

(define (%zero-denominator-ratio? bs)
  (let ((halves (%split-at bs 47)))
    (and halves
         (%number-token? (car halves))
         (pair? (cdr halves))
         (%all-digits? (cdr halves))
         (%all-zero-digits? (cdr halves)))))
(define (%parse-ratio bs)
  (let ((halves (%split-at bs 47)))
    ($make-rat (%parse-int (car halves))
               (%digits->int (cdr halves) 0))))
(define (%real-token? bs)
  (or (%number-token? bs) (%decimal-token? bs) (%ratio-token? bs)))
(define (%parse-real bs)
  (cond
   ((%number-token? bs) (%parse-int bs))
   ((%decimal-token? bs) (%parse-decimal bs))
   (else (%parse-ratio bs))))
(define (%complex-token? bs)
  ;; [real](+|-)[real]i  or  (+|-)[real]i  or  [real]i
  (and (pair? bs)
       (let ((rev (reverse bs)))
         (and (= (car rev) 105)                    ; trailing i
              (let ((body (reverse (cdr rev))))
                (let ((split (%split-imag body)))
                  (and split
                       (or (null? (car split)) (%real-token? (car split)))
                       (let ((im (cdr split)))
                         (or (equal? im '(43)) (equal? im '(45))
                             (%real-token?
                              (if (= (car im) 43) (cdr im) im)))))))))))
(define (%split-imag body)
  ;; split at the last +/- that isn't the leading sign; the imaginary
  ;; part must carry a sign (R6RS: +2i, -i, 3+4i -- never bare 2i)
  (let loop ((i (- (length body) 1)))
    (cond
     ((< i 1)
      (if (and (pair? body) (memv (car body) '(43 45)))
          (cons '() body)
          #f))
     ((memv (list-ref body i) '(43 45))
      (cons ($take-n body i) (list-tail body i)))
     (else (loop (- i 1))))))
(define ($take-n ls n)
  (if (zero? n) '() (cons (car ls) ($take-n (cdr ls) (- n 1)))))
(define (%parse-complex bs)
  (let* ((body (reverse (cdr (reverse bs))))       ; strip the i
         (split (%split-imag body))
         (re (if (null? (car split)) 0 (%parse-real (car split))))
         (imbs (cdr split))
         (im (cond
              ((null? imbs) 1)
              ((equal? imbs '(43)) 1)              ; +
              ((equal? imbs '(45)) -1)             ; -
              (else (%parse-real
                     (if (= (car imbs) 43) (cdr imbs) imbs))))))
    ($cx re im)))
(define (%parse-decimal bs) (%decimal->flonum bs))

(define (%sign-byte? b) (or (= b 45) (= b 43)))   ; - +

(define (%number-token? bs)
  ;; Both signs.  This took only `-` for its whole life, so `+42` was a
  ;; symbol and `-42` a number -- a sign has two spellings and a face
  ;; that accepts one of them is a half-fix that reads as a whole one.
  (if (and (pair? bs) (%sign-byte? (car bs)))
      (and (pair? (cdr bs)) (%all-digits? (cdr bs)))
      (and (pair? bs) (%all-digits? bs))))

;; The decimal face is ONE procedure that both recognises and builds,
;; and the predicate below is defined in terms of it.  It used to be a
;; scanner and a parser walking the same bytes by separate rules, which
;; is two statements of one grammar: whichever one is edited alone
;; becomes a token the other side answers differently.
;;
;; The digits are assembled as an EXACT RATIONAL and converted once.
;; Accumulating in floating point on the way in, or dividing by a power
;; of ten afterwards, rounds more than once and lands on a different
;; double -- and lands there differently on the two targets, which is
;; what the exact integer layer exists to prevent.
(define (%decimal->flonum bs)                     ; -> flonum, or #f
  ;; The base-ten face, which is the one an unprefixed token reaches.
  ;; It is the general body parser at radix 10 with the answer forced
  ;; inexact, so the two cannot describe different grammars: a number
  ;; face stated twice is a number face that will be edited once.
  (let ((r (%body->number bs 10)))
    (and (%number-body? r) (cadr r) (%apply-exactness r 'inexact))))

;; ---- the number body, in any radix -------------------------------
;; A body is  sign? ( digits / digits | digits? . digits? exp? ) and
;; the SAME procedure reads it in base 2, 8, 10 and 16.  Writing a
;; separate digit loop per radix is how `#x` came to have no sign, no
;; length check and no digit validation while base ten had all three:
;; four copies of one grammar, and only the copy anyone used got
;; fixed.
;;
;; Answers (magnitude inexact? negative?) with the magnitude an EXACT
;; rational, or #f.  The sign travels separately all the way to the
;; conversion, because the exact number 0 has no sign and applying it
;; early is exactly how a negative zero is lost.
;;
;; An exponent exists only at radix ten.  Anywhere else `e` is a digit
;; or it is nothing: `#x1e3` is 483, and `#x1.8e2` is a hex fraction
;; whose last three digits are `8`, `e` and `2`.
(define (%digit-val b radix)
  (let ((v (cond
            ((and (< 47 b) (< b 58)) (- b 48))      ; 0-9
            ((and (< 96 b) (< b 123)) (+ 10 (- b 97)))  ; a-z
            ((and (< 64 b) (< b 91)) (+ 10 (- b 65)))   ; A-Z
            (else 99))))
    (and (< v radix) v)))

(define (%digits-of bs radix)           ; -> (value count rest)
  (let loop ((bs bs) (v 0) (n 0))
    (if (and (pair? bs) (%digit-val (car bs) radix))
        (loop (cdr bs) (+ (* v radix) (%digit-val (car bs) radix)) (+ n 1))
        (list v n bs))))

;; %body->number answers one of THREE things, and this is the third.
;; A ratio whose denominator is zero has the shape of a number and
;; denotes none, and the two callers disagree about what to do with it:
;; the reader refuses it, string->number answers #f.  So the parser
;; reports WHAT IT FOUND and each caller states its own policy -- a
;; policy argument here would be the parser asking who called it.
;;
;; A fresh pair rather than a symbol: a symbol can be written down, and
;; a magnitude that happened to be one would collide with it.  This
;; value never leaves the file.
(define %denominator-zero (list 'denominator-zero))

;; The only way to ask whether an answer carries fields.  Every reader
;; of car/cadr/caddr below goes through this first, so "indexed into
;; the marker" is not a mistake that can be written here.
(define (%number-body? r)
  (and (pair? r) (not (eq? r %denominator-zero))))

;; All digits and all of them zero -- a byte scan, NOT a parse.  A token
;; predicate that answers by running the parser is how an error inside
;; the parser escapes through a question that was only yes or no.
(define (%all-zero-digits? bs)
  (and (pair? bs)
       (let loop ((bs bs))
         (or (null? bs)
             (and (= (car bs) 48) (loop (cdr bs)))))))

(define (%body->number bs radix)  ; -> (magnitude inexact? neg) | #f | %denominator-zero
  (and
   (pair? bs)
   (let* ((neg (= (car bs) 45))
          (bs (if (%sign-byte? (car bs)) (cdr bs) bs)))
     (let* ((ip (%digits-of bs radix))
            (int-v (car ip)) (int-n (cadr ip)) (rest (caddr ip)))
       (cond
        ;; ratio: no decimal point, no exponent, both halves required
        ((and (pair? rest) (= (car rest) 47))       ; /
         (let* ((dp (%digits-of (cdr rest) radix))
                (den-v (car dp)) (den-n (cadr dp)) (tail (caddr dp)))
           (and (< 0 int-n) (< 0 den-n) (null? tail)
                (begin
                  ;; A zero denominator is refused, and the message
                  ;; names the spellings that work.  Chez answers
                  ;; +inf.0 for "#i1/0", which would need the division
                  ;; deferred past the exactness prefix plus a separate
                  ;; 0/0-is-NaN case: a second shape in the parser for
                  ;; a spelling nobody writes.
                  ;;
                  ;; Reported rather than raised.  It used to raise from
                  ;; here, and the raise travelled through
                  ;; %decimal-token? -- a predicate whose whole body is
                  ;; (if (%decimal->flonum bs) #t #f) -- so a caller that
                  ;; had only asked "is this a number" was handed a
                  ;; reader error, complete with a line and column it had
                  ;; never read.
                  (if (= den-v 0)
                      %denominator-zero
                      (list ($make-rat int-v den-v) #f neg))))))
        ;; a decimal point, an exponent, or neither
        (else
         (let* ((dotted (and (pair? rest) (= (car rest) 46)))
                (fp (if dotted (%digits-of (cdr rest) radix) (list 0 0 rest)))
                (frac-v (car fp)) (frac-n (cadr fp)) (tail (caddr fp))
                (e (%exponent-of tail radix)))
           (and (< 0 (+ int-n frac-n)) e
                (let* (;; Both scales follow the RADIX: the fraction
                       ;; digits are a power of it ("#x.8" is 8/16, not
                       ;; 8/10) and so is the exponent ("#o1e3" is
                       ;; 8^3).  They collapse into a single power,
                       ;; which is why this is shorter than the version
                       ;; that treated ten specially.
                       (whole (+ (* int-v (%expt-int radix frac-n)) frac-v))
                       (scale (- (if (eq? e 'none) 0 e) frac-n))
                       (%bounded (%check-scale! scale))
                       (mag (if (< scale 0)
                                ($make-rat whole (%expt-int radix (- 0 scale)))
                                (* whole (%expt-int radix scale)))))
                  ;; R6RS: a decimal point or an exponent makes it
                  ;; inexact unless a prefix says otherwise
                  (list mag (or dotted (not (eq? e 'none))) neg)))))))))) 

(define (%expt-int b n) (let loop ((i n) (a 1)) (if (= i 0) a (loop (- i 1) (* a b)))))

;; An exponent in a numeral is chosen by whoever wrote the text, and
;; this reader is the one the compiler reads its own source with, so
;; the text is not always ours.  (%expt-int radix scale) costs scale
;; bignum multiplications against a growing accumulator: the work is
;; quadratic in a number the input picks.  Measured on this runtime,
;; 10^10000 reads in 0.16s, 10^50000 in 2.9s, and 10^200000 does not
;; finish inside 40 seconds.
;;
;; So the bound is on the VALUE and is checked BEFORE the power is
;; built, which is the shape (web json)'s $max-exponent already uses
;; for the same reason.  BOTH signs need it: the negative branch
;; reaches the identical %expt-int through $make-rat's denominator,
;; and "#e1e-999999" hangs exactly as "#e1e999999" does.
;;
;; What this costs: a numeral R6RS allows is refused, and the refusal
;; is an error rather than #f -- including for the inexact spelling,
;; where Chez answers +inf.0 for "1e999999" and 0.0 for "1e-999999".
;; Answering the limit instead would mean carrying the overflow past
;; the exactness prefix, since only #e/#i decides whether the answer
;; is a flonum or a refused bignum.  Erring here is the same trade the
;; division-by-zero refusal above already makes in this parser.
(define $max-scale 10000)
(define (%check-scale! scale)
  (when (< $max-scale (if (< scale 0) (- 0 scale) scale))
    (errorf 'read
            (string-append
             "exponent out of range -- at most 10^"
             (number->string $max-scale) " at "
             (%at-line $reader-line $reader-column)))))

;; Turn (magnitude inexact? neg) into the number, under an exactness
;; that is 'exact, 'inexact, or #f for "whatever the spelling said".
(define (%apply-exactness r want)
  (unless (%number-body? r)
    (errorf '%apply-exactness "not a number body" r))
  (let* ((mag (car r)) (neg (caddr r))
         (inexact? (if want (eq? want 'inexact) (cadr r))))
    (if inexact?
        (let ((v ($exact->fl (numerator mag) (denominator mag))))
          ;; sign applied after the conversion -- see %decimal->flonum
          (if neg (fl* v (fixnum->flonum -1)) v))
        (if neg (- 0 mag) mag))))

;; ---- #b #o #d #x and #e #i ---------------------------------------
;; Entered with the byte after `#` already read.  The rest of the
;; token is gathered and the prefixes are peeled off the front, at
;; most one radix and at most one exactness, in either order --
;; `#e#x1f` and `#x#e1f` are both 31, and `#x#x1f` and `#e#i1.5` are
;; both refused.
(define (%read-prefixed first)
  (let ((token (cons 35 (cons first (%read-token '())))))
    (let peel ((bs token) (radix #f) (exactness #f))
      (if (and (pair? bs) (= (car bs) 35) (pair? (cdr bs)))
          (let* ((c (cadr bs))
                 (radix! (lambda (r)
                           (when radix (%prefix-twice "radix"))
                           (peel (cddr bs) r exactness)))
                 (exact! (lambda (x)
                           (when exactness (%prefix-twice "exactness"))
                           (peel (cddr bs) radix x))))
            (cond
             ((memv c '(98 66)) (radix! 2))
             ((memv c '(111 79)) (radix! 8))
             ((memv c '(100 68)) (radix! 10))
             ((memv c '(120 88)) (radix! 16))
             ((memv c '(101 69)) (exact! 'exact))
             ((memv c '(105 73)) (exact! 'inexact))
             ;; A `#` inside a number token that is not a prefix is an
             ;; error, not a datum.  Answering #f here would make the
             ;; reader hand back the boolean false for "#x#q1" -- a
             ;; value, from a token that has no value.
             (else
              (errorf 'read
                      (string-append "unrecognised number prefix #"
                                     (string (integer->char c)) " at "
                                     (%at-line $reader-line $reader-column))))))
          (let* ((base (or radix 10))
                 (r (%body->number bs base)))
            (cond
             ((eq? r %denominator-zero) (%denominator-zero-error))
             (r (%apply-exactness r exactness))
             (else (%bad-prefixed bs base))))))))

;; Say WHY, naming the byte and the base.  A reader that only reports
;; "that is not a number" sends the writer looking at the wrong end of
;; the token; #bad and #b101 differ by two bytes and by nothing else
;; the message would show.
(define (%prefix-twice what)
  (errorf 'read
          (string-append "a number carries at most one " what
                         " prefix at "
                         (%at-line $reader-line $reader-column))))

;; The reader's answer to a numeral that denotes no number.  Both
;; reader legs -- the unprefixed one through %finish-atom and the
;; prefixed one through %read-hash -- say it here, so the wording and
;; the position are written once.
(define (%denominator-zero-error)
  (errorf 'read
          (string-append
           "division by zero in a numeral -- write "
           "+inf.0, -inf.0 or +nan.0 at "
           (%at-line $reader-line $reader-column))))

(define (%bad-prefixed bs base)
  (let ((offender
         (let find ((bs bs))
           (cond
            ((null? bs) #f)
            ((or (%digit-val (car bs) base) (%sign-byte? (car bs))
                 (= (car bs) 46) (= (car bs) 47))
             (find (cdr bs)))
            (else (car bs))))))
    (errorf 'read
            (if offender
                (string-append (string (integer->char offender))
                               " is not a base-" (number->string base)
                               " digit at "
                               (%at-line $reader-line $reader-column))
                (string-append "a #-prefixed number needs at least one base-"
                               (number->string base) " digit at "
                               (%at-line $reader-line $reader-column))))))

(define (%pow10 k) (let loop ((i k) (a 1)) (if (= i 0) a (loop (- i 1) (* a 10)))))


;; What follows the digits: nothing, or an exponent.  Answers the
;; exponent as an integer, `none` when the token simply ended, and #f
;; when the rest is not an exponent -- which is how "1e" and "1e+"
;; stay symbols, as they are in R6RS and in Chez.
;;
;; ONE rule covers every radix: a marker is a letter of `e s f d l`
;; (either case) that is NOT a digit in the current radix, its digits
;; are read in that radix, and it scales by a power of that radix.
;; So `#x1e3` is 483 -- `e` is a hex digit there, so no exponent
;; exists -- while `#o1e3` is 8^3 and `#o1e8` is refused because `8`
;; is not an octal digit.
;;
;; The alternative was to honour markers only at radix ten.  That is
;; MORE code: it needs a guard whose only purpose is to reject input
;; this rule already handles.  The general rule is the smaller
;; program, and it agrees with Chez.  It does go beyond R6RS, which
;; defines decimals for radix ten alone, and docs/limits.md carries
;; that declaration -- an undeclared extension is an accident, a
;; declared one is a feature.
;;
;; Four of the five markers were missing when this was decimal-only.
;; docs/sexpr.md had already recorded s/f/d/l as a dimension a
;; hand-written list missed, in a different corpus, with "assume it is
;; still incomplete" attached.
(define (%exp-marker? b radix)
  (and (memv b '(101 69 115 83 102 70 100 68 108 76))   ; e E s S f F d D l L
       (not (%digit-val b radix))))

(define (%exponent-of bs radix)
  (cond
   ((null? bs) 'none)
   ((%exp-marker? (car bs) radix)
    (let* ((rest (cdr bs))
           (neg (and (pair? rest) (= (car rest) 45)))
           (rest (if (and (pair? rest) (%sign-byte? (car rest))) (cdr rest) rest))
           (d (%digits-of rest radix)))
      (and (< 0 (cadr d)) (null? (caddr d))
           (if neg (- 0 (car d)) (car d)))))
   (else #f)))

(define (%decimal-token? bs) (if (%decimal->flonum bs) #t #f))

;; +inf.0 -inf.0 +nan.0 -nan.0, built by arithmetic: this file cannot
;; write a literal for any of them, and would not want to -- a literal
;; would be read by the very reader being defined.
(define (%special-number bs)                      ; -> flonum, or #f
  ;; Every atom in every source file reaches this, so it costs a byte
  ;; comparison before it costs a string: all four spellings are six
  ;; bytes beginning with a sign.
  (if (not (and (pair? bs) (%sign-byte? (car bs)) (= 6 (length bs))))
      #f
      (%special-number* bs)))
(define (%special-number* bs)
  (let ((s (%bytes->string bs))
        (zero (fixnum->flonum 0)))
    (cond
     ((string=? s "+inf.0") (fl/ (fixnum->flonum 1) zero))
     ((string=? s "-inf.0") (fl/ (fixnum->flonum -1) zero))
     ((or (string=? s "+nan.0") (string=? s "-nan.0")) (fl/ zero zero))
     (else #f))))
(define (%all-digits? bs)
  (if (null? bs)
      #t
      (and (< 47 (car bs)) (< (car bs) 58)
           (%all-digits? (cdr bs)))))
(define (%parse-int bs)
  (cond
   ((= (car bs) 45) (- 0 (%digits->int (cdr bs) 0)))
   ((= (car bs) 43) (%digits->int (cdr bs) 0))
   (else (%digits->int bs 0))))
(define (%digits->int bs acc)
  (if (null? bs)
      acc
      (%digits->int (cdr bs) (+ (* acc 10) (- (car bs) 48)))))

(define (%bytes->string bs)
  (let ((s (%make-string (length bs))))
    (%fill-bytes s bs 0)
    s))
(define (%fill-bytes s bs i)
  (unless (null? bs)
    (string-set! s i (integer->char (car bs)))
    (%fill-bytes s (cdr bs) (+ i 1))))

;; Entered with the open paren already consumed, so the live counter
;; still names it: carry that position down the whole list, and an
;; end of input reports where the list was OPENED.  A file whose
;; parens do not balance otherwise reports at its very end, which is
;; the least useful place it could name.
(define (%read-list)
  (%read-list-from $reader-line $reader-column #f))
;; `any?` is whether an element has been read yet, which the dotted-tail
;; branch needs: a dot is a tail marker between two things, so it has to
;; have something on its left.  A comment passes the flag through
;; unchanged -- it is not an element.
(define (%read-list-from line col any?)
  ;; The elements are gathered in reverse and the list is built once
  ;; its end is known, so a list of any length is read in constant
  ;; stack.  One frame per element ran the self-hosted compiler out of
  ;; stack on a list of a couple of thousand elements.  The elements
  ;; are still read in order; only the consing waits for the end.
  (define (onto rev tail)
    (if (null? rev) tail (onto (cdr rev) (cons (car rev) tail))))
  (let next ((acc '()) (any? any?))
    (%skip-blanks)
    (let ((b (%peek-byte)))
      (cond
       ((< b 0) (%unclosed-list line col))
       ;; ) ends the list
       ((= b 41) (%next-byte) (onto acc '()))
       ;; A comment inside a list has to be skipped HERE, not by $read.
       ;; $read answers with a datum, so "#;2 . 3" made it read the dot
       ;; as the next datum -- and a lone dot is not one.  The list is
       ;; the only place that knows a dot is a tail marker.
       ((= b 35)
        (%next-byte)
        (if (%skip-hash-comment)
            (next acc any?)
            (next (cons (%read-hash) acc) #t)))
       ;; . is a dotted tail, or the start of a dot-initial atom
       ((= b 46)
        (%next-byte)
        ;; `#` ends the dot as a delimiter does.  Since %read-name-token
        ;; and %read-atom stop at `#`, a dot followed by one can no
        ;; longer be the start of a name -- `.` alone is not a datum --
        ;; so the only reading left is the tail marker.
        ;;
        ;; This ENDS the dot rather than skipping atmosphere after it,
        ;; and the difference is the whole point: what follows may be a
        ;; DATUM that merely begins with `#`.  `(1 .#(2))` has a vector
        ;; as its tail, and a repair that consumed `#` atmosphere here
        ;; would eat it.  Ending the dot hands `#` back to $read, which
        ;; already knows both readings.
        (if (let ((n (%peek-byte)))
              (or (%delimiter? n) (= n 35)))
            (begin
              ;; "(. 2)" -- the dot has nothing to be the tail of
              (unless any?
                (errorf 'read
                        (string-append "a dot needs an item before it at "
                                       (%at-line $reader-line $reader-column))))
              (let ((d ($read)))
                ;; This used to consume whatever byte was here without
                ;; looking, so "(1 . 2 3)" read as (1 . 2) and the 3 was
                ;; gone -- a shorter answer than the text, and nothing
                ;; said.  Only ")" may follow the tail datum.
                ;;
                ;; But ATMOSPHERE may, and `#|...|#`, `#;<datum>` and a
                ;; lexical directive are all atmosphere.  %skip-blanks
                ;; reaches none of them, which is why `(1 . 2 #|c|#)`
                ;; reported a second item.  So the close is a loop, and a
                ;; `#` opening NEITHER a comment NOR a directive is a
                ;; second item and refused as one -- which is what
                ;; `(1 . 2 #(3))` is, while `(1 . 2 #!r6rs)` is accepted.
                ;; Chez agrees on all three.
                (let close ()
                  (%skip-blanks)
                  (let ((n (%peek-byte)))
                    (cond
                     ((< n 0) (%unclosed-list line col))
                     ((= n 41) (%next-byte) (onto acc d))
                     ((= n 35)
                      (%next-byte)
                      (if (%skip-hash-comment)
                          (close)
                          (errorf 'read
                                  (string-append
                                   "more than one item found after dot at "
                                   (%at-line $reader-line $reader-column)))))
                     (else
                      (errorf 'read
                              (string-append
                               "more than one item found after dot at "
                               (%at-line $reader-line $reader-column)))))))))
            (next (cons (let ((r (%read-atom (list 46) #f)))
                          (%finish-atom (cdr r) (car r)))
                        acc)
                  #t)))
       (else
        (next (cons ($read) acc) #t))))))
(define (%unclosed-list line col)
  (errorf 'read (string-append "list opened at " (%at-line line col)
                               " never closed")))

(define (%read-string line col acc)
  (let ((b (%next-byte)))
    (cond
     ((= b 34) (%bytes->string (reverse acc)))
     ((< b 0)
      (errorf 'read (string-append "string opened at " (%at-line line col)
                                   " never closed")))
     ((= b 92)                                     ; backslash
      ;; A LINE CONTINUATION is not an escape: R6RS 4.2.5 says a
      ;; backslash followed by intraline whitespace, a line ending and
      ;; more intraline whitespace stands for NOTHING -- it is how a
      ;; long string literal is broken across source lines.  Without
      ;; this the pair fell through to %read-escape's `else` and became
      ;; a newline character, so the same source read as two different
      ;; strings depending on whose reader saw it: Chez elides it, this
      ;; one did not, and a file using the escape compiled to different
      ;; bytes on the two hosts.
      ;; %line-ending? consumes what it matches, so the byte has to be
      ;; taken before it is asked about, and handed on when it turns out
      ;; to be an ordinary escape.
      (let ((n (%peek-byte)))
        (if (%intraline-ws? n)
            (begin (%skip-string-continuation line col)
                   (%read-string line col acc))
            (let ((c (%next-byte)))
              (if (and (< -1 c) (%line-ending? c))
                  (begin (%skip-intraline-ws)
                         (%read-string line col acc))
                  (%escape-after-backslash c line col acc))))))
     ;; A LINE ENDING inside a literal is one newline, whatever it was
     ;; spelled as -- the third caller of the one predicate, alongside
     ;; %skip-line and the continuation test above.
     ((%line-ending? b) (%read-string line col (cons 10 acc)))
     (else (%read-string line col (cons b acc))))))

;; A string in this runtime is a sequence of UTF-8 BYTES: the reader
;; takes source bytes one at a time, so a literal lambda is the two
;; characters 206 and 187, and the compiler encodes what its host read
;; the same way.  So a hex escape has to encode too, or "\x3bb;" and
;; "lambda spelled literally" would be different strings -- and the
;; escape is the spelling a source file uses precisely when it cannot
;; carry the character itself.  That equality is the property, and the
;; cells assert it directly rather than asserting a byte count.
;;
;; `acc` is built in reverse, so the bytes are consed in order.
(define (%push-utf8 v acc)
  (cond
   ((< v 128) (cons v acc))
   ((< v 2048)
    (cons (+ 128 (bitwise-and v 63))
          (cons (+ 192 (bitwise-arithmetic-shift-right v 6)) acc)))
   ((< v 65536)
    (cons (+ 128 (bitwise-and v 63))
          (cons (+ 128 (bitwise-and (bitwise-arithmetic-shift-right v 6) 63))
                (cons (+ 224 (bitwise-arithmetic-shift-right v 12)) acc))))
   (else
    (cons (+ 128 (bitwise-and v 63))
          (cons (+ 128 (bitwise-and (bitwise-arithmetic-shift-right v 6) 63))
                (cons (+ 128 (bitwise-and (bitwise-arithmetic-shift-right v 12) 63))
                      (cons (+ 240 (bitwise-arithmetic-shift-right v 18))
                            acc)))))))

(define (%intraline-ws? b) (or (= b 32) (= b 9)))
;; THE single answer to "does a line ending start here".  Call it with
;; the byte already consumed; it answers #t having consumed the rest of
;; the ending, or #f having consumed nothing (anything it looked at and
;; did not want is pushed back).
;;
;; The reference treats LF, CR, CRLF, NEL (U+0085), CR+NEL and LS
;; (U+2028) alike and does NOT treat PS (U+2029) as one -- measured.
;; Three places need this answer: skipping a line comment, normalising
;; the body of a string literal, and deciding whether a backslash
;; begins a continuation.  They used to disagree: the body knew the
;; whole set, the continuation knew LF and CR, and the comment knew
;; only LF, so the same file read as different programs on the two
;; hosts.  One supplier, three callers -- removing NEL from here turns
;; all three suites red, which is what says they share it.
(define (%line-ending? b)
  (cond
   ((= b 10) #t)                                 ; LF
   ((= b 13)                                     ; CR, CRLF, CR+NEL
    (let ((n (%peek-byte)))
      (cond
       ((= n 10) (%next-byte) #t)
       ((= n 194)
        (%next-byte)
        (if (= (%peek-byte) 133)
            (begin (%next-byte) #t)
            (begin (%push-back 194) #t)))        ; a lone CR is still one
       (else #t))))
   ((= b 194) (if (= (%peek-byte) 133)           ; NEL
                  (begin (%next-byte) #t)
                  #f))
   ((= b 226)                                    ; LS, and only LS
    (if (= (%peek-byte) 128)
        (begin (%next-byte)
               (if (= (%peek-byte) 168)
                   (begin (%next-byte) #t)
                   (begin (%push-back 128) #f)))
        #f))
   (else #f)))

;; the backslash is already consumed; take the rest of the continuation
;; and produce nothing
(define (%skip-string-continuation line col)
  (let skip ()
    (when (%intraline-ws? (%peek-byte)) (%next-byte) (skip)))
  (let ((b (%next-byte)))
    (unless (%line-ending? b)
      (errorf 'read
              (string-append "a backslash in the string opened at "
                             (%at-line line col)
                             " is followed by whitespace and then no line "
                             "ending, which is not an escape")))
    ;; CR LF is ONE line ending
    (when (and (= b 13) (= (%peek-byte) 10)) (%next-byte)))
  (let skip ()
    (when (%intraline-ws? (%peek-byte)) (%next-byte) (skip))))
;; The byte after a backslash, once it is known not to begin a line
;; ending.  Split out so the continuation test above reads as one
;; question rather than as a cond with an unrelated tail.
(define (%escape-after-backslash c line col acc)
  (cond
   ;; End of input after the backslash: the fault is the unclosed
   ;; string, not an unknown escape.  Before the escape table refused
   ;; anything this fell through and the loop reported the missing
   ;; quote by itself; the refusal would now get there first and name a
   ;; character that does not exist.  test/read-errors.ss was already
   ;; holding this case -- "a trailing backslash cannot swallow the end
   ;; of input" -- and it is what caught that regression.
   ((< c 0)
    (errorf 'read (string-append "string opened at " (%at-line line col)
                                 " never closed")))
   ((= c 120)                                    ; x -- hex escape
    (%read-string line col (%push-utf8 (%read-hex-escape line col) acc)))
   (else (%read-string line col (cons (%read-escape c) acc)))))

(define (%skip-intraline-ws)
  (when (%intraline-ws? (%peek-byte)) (%next-byte) (%skip-intraline-ws)))

(define (%read-escape b)
  ;; The byte after a backslash.  This table had three entries and an
  ;; `else` that answered the byte itself, so "\a" was the letter a and
  ;; "\q" was the letter q: not a refusal, not a diagnostic, a
  ;; different string from the one the source says.  An unknown escape
  ;; is a typo, and a reader that invents a meaning for it can never
  ;; report one.
  (cond
   ((= b 97) 7)        ; \a -> alarm
   ((= b 98) 8)        ; \b -> backspace
   ((= b 116) 9)       ; \t -> tab
   ((= b 110) 10)      ; \n -> newline
   ((= b 118) 11)      ; \v -> vertical tab
   ((= b 102) 12)      ; \f -> form feed
   ((= b 114) 13)      ; \r -> return
   ((= b 34) 34)       ; \" -> quote
   ((= b 92) 92)       ; \\ -> backslash
   (else
    (errorf 'read
            (string-append "\\" (string (integer->char b))
                           " is not a string escape at "
                           (%at-line $reader-line $reader-column))))))

;; \xHHHH; -- the `x` is already consumed.  The semicolon is required
;; and it TERMINATES: "\x41;f" is A followed by the letter f, so a
;; reader that swallowed the terminator or stopped at the wrong byte
;; only shows itself when something follows the escape.
(define (%read-hex-escape line col)
  (let loop ((v 0))
    (let ((b (%next-byte)))
      (cond
       ((< b 0)
        (errorf 'read
                (string-append "a \\x escape in the string opened at "
                               (%at-line line col)
                               " reaches end of input with no ;")))
       ((= b 59)                                   ; ;
        ;; No digits at all is accepted, as code point zero, which is
        ;; what the reference implementation does; refusing it would
        ;; cost a check that buys nothing.  What must be refused is a
        ;; value that is not a character: past the last code point, or
        ;; inside the surrogate range, which UTF-16 reserves and which
        ;; integer->char would have to invent a meaning for.
        (when (< 1114111 v)
          (errorf 'read
                  (string-append "a \\x escape in the string opened at "
                                 (%at-line line col)
                                 " is past the last code point")))
        (when (and (<= 55296 v) (<= v 57343))
          (errorf 'read
                  (string-append "a \\x escape in the string opened at "
                                 (%at-line line col)
                                 " names a surrogate, which is not a character")))
        v)
       ((%digit-val b 16) => (lambda (d) (loop (+ (* v 16) d))))
       (else
        (errorf 'read
                (string-append (string (integer->char b))
                               " is not a hexadecimal digit in the \\x escape"
                               " in the string opened at "
                               (%at-line line col))))))))

(define (%read-hash)
  (let ((b (%next-byte)))
    (cond
     ((= b 116) #t)                                ; t
     ((= b 102) #f)                                ; f
     ((= b 39) (list 'syntax ($read)))              ; ' -- #'x
     ((= b 40) (list->vector (%read-list)))        ; ( -- #(...) vector
     ((memv b '(98 66 111 79 100 68 120 88 101 69 105 73))
      (%read-prefixed b))                          ; b B o O d D x X e E i I
     ((= b 118) (%read-bytevector))                ; v -- #vu8(...)
     ((= b 92)                                     ; \ -- character
      (let ((first (%next-byte)))
        (if (%delimiter? (%peek-byte))
            (integer->char first)
            (%named-char (%bytes->string
                          (cons first (%read-name-token '())))))))
     ;; Anything else is an error, and it has to be: this branch used
     ;; to answer (eof-object), which is not a weak error but the wrong
     ;; KIND of value.  End-of-input is a control signal, so a form the
     ;; reader did not implement did not fail -- it ended the datum,
     ;; and a consumer's correct response to that is to stop and treat
     ;; what it has as complete.  `(read "(1 #b101 3)")` answered
     ;; `(1 #<eof> 101 3)`: three elements became four, with different
     ;; contents, silently.  A failure encoded as a legal protocol
     ;; signal is worse than a crash, because the caller handles it.
     (else
      (errorf 'read
              (string-append "unrecognised # syntax: #"
                             (if (< b 0) "<end of input>"
                                 (string (integer->char b)))
                             " at " (%at-line $reader-line $reader-column)))))))

;; #| ... |# and it NESTS.  Scanning to the last |# accepts
;; "#| a |# b |#" as one comment and swallows `b`; stopping at the
;; first accepts "#| outer #| inner |# still-outer |#" too early and
;; leaves `still-outer |#` as data.  Both pass a single-level test, so
;; the depth is carried and test/reader-comments.ss reads what comes
;; AFTER the comment rather than the comment itself.
;; The `#` is consumed; if what follows begins a comment, consume the
;; whole comment and answer #t.  Otherwise consume nothing more and
;; answer #f, leaving the caller to read the hash form.
;;
;; One procedure because there are two callers -- a comment can begin a
;; datum or sit between two elements of a list -- and they had the same
;; three-way cond written out twice.  Two statements of one grammar is
;; how "#;2 . 3" came to be read as a dot: the list's copy was added
;; later, and the two were only accidentally the same.
(define (%skip-hash-comment)
  (let ((c (%peek-byte)))
    (cond
     ((= c 124) (%next-byte) (%skip-block-comment 1) #t)
     ((= c 59) (%next-byte) (%skip-datum) #t)
     ;; A lexical directive is atmosphere, like the two comment forms
     ;; above: it names the dialect and denotes no value.  It belongs
     ;; here rather than in %read-hash because all three callers of
     ;; this procedure simply carry on afterwards, which is what makes
     ;; "(1 #!r6rs)" and a directive at end of input work.  A version
     ;; that read the FOLLOWING datum instead would have to find one,
     ;; and at the end of a list or of a file there is none.
     ((= c 33) (%next-byte) (%skip-directive) #t)
     (else #f))))

;; The directives this implementation knows.  R6RS defines #!r6rs.
;; #!chezscheme is accepted because stage0 reads sources with CHEZ's
;; reader, which accepts it; a directive the two readers disagreed
;; about would compile on stage0 and fail on stage1, and that stage
;; divergence is the defect this branch exists to remove.  No source
;; in this tree carries it today.  Adding a directive is adding a name
;; to this list: what is accepted and what the diagnostic offers are
;; both read from it, so the two cannot come to disagree.
(define %lexical-directives '("r6rs" "chezscheme"))

(define (%known-directive? name ds)
  (cond ((null? ds) #f)
        ((string=? name (car ds)) #t)
        (else (%known-directive? name (cdr ds)))))

(define (%directive-names ds)
  (cond ((null? ds) "")
        ((null? (cdr ds)) (string-append "#!" (car ds)))
        (else (string-append "#!" (car ds) " " (%directive-names (cdr ds))))))

;; An unknown directive RAISES rather than being skipped.  A branch that
;; consumed whatever followed #! would take #!r6r5 for #!r6rs, and a
;; misspelling that reads as "no directive at all" is the failure this
;; branch exists to prevent -- the file would compile and the thing the
;; author asked for would simply not be in effect.  "#!" with nothing
;; after it arrives here with an empty name and is refused the same way.
(define (%skip-directive)
  (let ((name (%bytes->string (%read-name-token '()))))
    (unless (%known-directive? name %lexical-directives)
      (errorf 'read
              (string-append "unrecognised lexical directive: #!" name
                             " at " (%at-line $reader-line $reader-column)
                             " (this implementation knows "
                             (%directive-names %lexical-directives) ")")))))

(define (%skip-block-comment depth)
  (let ((b (%next-byte)))
    (cond
     ((< b 0)
      (errorf 'read
              (string-append "a #| block comment reaches end of input with "
                             "no |# at "
                             (%at-line $reader-line $reader-column))))
     ((and (= b 35) (= (%peek-byte) 124))         ; #|
      (%next-byte) (%skip-block-comment (+ depth 1)))
     ((and (= b 124) (= (%peek-byte) 35))         ; |#
      (%next-byte)
      (unless (= depth 1) (%skip-block-comment (- depth 1))))
     (else (%skip-block-comment depth)))))

;; #; comments out the next DATUM, not the next token: "#;(1 2) 3"
;; drops the whole list.  Reading it is what finds its end, so this
;; reads and discards -- and refuses when there is nothing to discard,
;; which is what "#;" alone and "(#;)" are.
(define (%skip-datum)
  (let ((d ($read)))
    (when (eof-object? d)
      (errorf 'read
              (string-append "a #; datum comment has no datum after it at "
                             (%at-line $reader-line $reader-column))))))

(define (%read-bytevector)
  ;; #vu8( ... ) -- the spelling the writer emits for a bytevector, so
  ;; the reader owes it an entry: without one this library could not
  ;; read back its own output.
  (let ((u (%next-byte)) (eight (%next-byte)) (open (%next-byte)))
    (unless (and (= u 117) (= eight 56) (= open 40))   ; u 8 (
      (errorf 'read
              (string-append "unrecognised # syntax: #v (only #vu8( is a "
                             "bytevector) at "
                             (%at-line $reader-line $reader-column))))
    (let ((elements (%read-list)))
      ;; Check every element rather than letting bytevector-u8-set!
      ;; take what it is given: an out-of-range value would be
      ;; truncated or wrapped, and a wrapped byte is a wrong value that
      ;; looks like a right one.
      (let ((bv (make-bytevector (length elements))))
        (let loop ((i 0) (es elements))
          (if (null? es)
              bv
              (let ((e (car es)))
                (unless (and (integer? e) (exact? e)
                             (<= 0 e) (<= e 255))
                  (errorf 'read
                          (string-append
                           "a bytevector element is an exact integer in "
                           "0..255 at "
                           (%at-line $reader-line $reader-column))))
                (bytevector-u8-set! bv i e)
                (loop (+ i 1) (cdr es)))))))))


;; R6RS's #\x<hex>.  This is NOT the string escape and the two are
;; deliberately not unified: a string escape is \x<hex>; WITH a
;; terminating semicolon, a character literal is #\x<hex> with none.
;;
;; A name reaches here only when a byte followed the x, so #\x alone is
;; still the character x through the single-character branch, and #\X41
;; and #\xyz still fall through to the unknown-name error -- only a
;; lowercase x opens the escape, and every later byte must be a hex
;; digit.
(define (%char-hex-name? name)
  (and (> (string-length name) 1)
       (char=? (string-ref name 0) #\x)
       (let loop ((i 1))
         (or (= i (string-length name))
             (and (%digit-val (char->integer (string-ref name i)) 16)
                  (loop (+ i 1)))))))

;; The range is THIS RUNTIME'S, not R6RS's.  A character here is a byte
;; (docs/limits.md, "Character literals stop at U+007F"), so a scalar
;; value above 127 is refused in the same words the Chez-hosted driver
;; refuses a non-ASCII character datum, rather than minting a character
;; no string in this runtime could hold.  Chez answers a character for
;; #\x1F600; copying it here would make the two hosts disagree about
;; which programs exist, which is the reason limits.md gives.
;;
;; The bound is tested as the digits are consumed rather than after: a
;; long run would otherwise build an unbounded integer before anything
;; looked at its value, and the value can only grow.
(define (%char-hex-char name)
  (let loop ((i 1) (v 0))
    (cond
     ((> v 127)
      (errorf 'read
              (string-append "a character literal above U+007F has no"
                             " self-hosted spelling: #\\" name " at "
                             (%at-line $reader-line $reader-column))))
     ;; the arm above rejected v > 127, so v is 0..127 here
     ((= i (string-length name)) (%integer->char v))
     (else (loop (+ i 1)
                 (+ (* v 16)
                    (%digit-val (char->integer (string-ref name i)) 16)))))))

(define (%named-char name)
  ;; the full R6RS set; an unknown name is an error, not a silent
  ;; first-character guess (#\return once read as #\r that way)
  (cond
   ((string=? name "space") #\space)
   ((string=? name "newline") #\newline)
   ((string=? name "tab") (%integer->char 9))
   ((string=? name "return") (%integer->char 13))
   ((string=? name "linefeed") (%integer->char 10))
   ((string=? name "nul") (%integer->char 0))
   ((string=? name "alarm") (%integer->char 7))
   ((string=? name "backspace") (%integer->char 8))
   ((string=? name "vtab") (%integer->char 11))
   ((string=? name "page") (%integer->char 12))
   ((string=? name "esc") (%integer->char 27))
   ((string=? name "delete") (%integer->char 127))
   ((%char-hex-name? name) (%char-hex-char name))
   ((= (string-length name) 1) (string-ref name 0))
   (else (error 'read (string-append "unknown character name ending at "
                                     (%at-line $reader-line $reader-column))
                name))))

;; ---- write ----

(define (write x . p)
  (if (null? p) ($write x) ($with-out (car p) (lambda () ($write x)))))
(define ($write x)
  (cond
   ((string? x)
    ($wb 34)
    (%write-escaped x 0)
    ($wb 34))
   ((char? x)
    ($wb 35) ($wb 92)
    (%write-char-name x))
   ((pair? x)
    ($wb 40)
    (write (car x))
    (%write-tail (cdr x)))
   ((vector? x)
    ($wb 35) ($wb 40)
    (let loop ((i 0))
      (when (< i (vector-length x))
        (unless (zero? i) ($wb 32))
        (write (vector-ref x i))
        (loop (+ i 1))))
    ($wb 41))
   ((symbol? x) (%write-symbol (symbol->string x)))
   (else (display x))))

;; A symbol name that cannot be spelled bare has to be escaped, or the
;; writer emits something that is not the datum it was handed: the name
;; "a b" went out as `a b` and came back as `a` with `b` left over, and
;; the empty name went out as nothing at all.
;;
;; The escape set is MEASURED, not reasoned about -- every byte from 1
;; to 126 was written as a symbol under the reference implementation
;; and the ones it escaped are the ones escaped here.  Two positions
;; differ, so there are two predicates: `+`, `-`, `.`, a digit and `@`
;; are fine inside a name and not at the front of one.
;;
;; Two different exemptions, and conflating them was a defect.
;;
;; `+`, `-` and `...` are WHOLE names that need no escaping at all.
;; `->` is not one of those: it exempts only the LEADING byte from the
;; leading rule, and every byte after it is judged normally.  Treating
;; `->` as a whole-name exemption meant "->a b" went out unescaped and
;; read back as `->a` with `b` left over -- the exact failure this
;; change exists to remove, reintroduced by the exemption meant to
;; spell `->x` correctly.  Measured against the reference:
;;   "->a b" => ->a\x20;b      "->|" => ->\x7C;      "->#" => ->\x23;
(define (%sym-whole-name-safe? s)
  (or (string=? s "+") (string=? s "-") (string=? s "...")))

(define (%sym-arrow? s)                 ; leading byte exempt, rest normal
  (and (>= (string-length s) 2)
       (char=? #\- (string-ref s 0))
       (char=? #\> (string-ref s 1))))

(define (%sym-escape-mid? b)
  (or (< b 33)                                     ; controls and space
      (memv b '(34 35 39 40 41 44 59 91 92 93 96 123 124 125))))

(define (%sym-escape-lead? b)
  (or (%sym-escape-mid? b)
      (memv b '(43 45 46 64))                      ; + - . @
      (and (>= b 48) (<= b 57))))                  ; a digit

(define $hex-upper "0123456789ABCDEF")
(define (%write-sym-escape b)                      ; \xHH; upper case, no padding
  ($wb 92) ($wb 120)
  (when (< 15 b) ($wb (char->integer (string-ref $hex-upper (quotient b 16)))))
  ($wb (char->integer (string-ref $hex-upper (remainder b 16))))
  ($wb 59))

(define (%write-symbol s)
  (let ((n (string-length s)))
    (cond
     ;; the one name with no inline spelling: there is no escape for
     ;; nothing, so the bars carry it
     ((= n 0) ($wb 124) ($wb 124))
     ((%sym-whole-name-safe? s) (%display-string s 0))
     (else
      (let ((arrow (%sym-arrow? s)))
        (let loop ((i 0))
          (when (< i n)
            (let ((b (char->integer (string-ref s i))))
              (if (if (and (= i 0) (not arrow))
                      (%sym-escape-lead? b)
                      (%sym-escape-mid? b))
                  (%write-sym-escape b)
                  ($wb b)))
            (loop (+ i 1)))))))))

(define (%write-tail x)
  (cond
   ((null? x) ($wb 41))
   ((pair? x)
    ($wb 32)
    (write (car x))
    (%write-tail (cdr x)))
   (else
    ($wb 32) ($wb 46) ($wb 32)
    (write x)
    ($wb 41))))

(define (%write-escaped s i)
  (when (< i (string-length s))
    (let ((c (char->integer (string-ref s i))))
      (when (or (= c 34) (= c 92))
        ($wb 92))
      ($wb c))
    (%write-escaped s (+ i 1))))

(define (%write-char-name c)
  (let ((n (char->integer c)))
    (cond
     ((= n 32) (%display-string "space" 0))
     ((= n 10) (%display-string "newline" 0))
     ((= n 9) (%display-string "tab" 0))
     (else ($wb n)))))

;; ---- additions for self-hosting ----

(define (void) (begin))

(define (> a b) (< b a))
;; <= and >= are built from < and =, NOT as the negation of the
;; opposite strict comparison.  (not (> a b)) equals (<= a b) for every
;; pair of real numbers and differs on exactly one input: a NaN, which
;; IEEE 754 says is unordered with respect to every value including
;; itself, so all four comparisons are false.  Written as negations,
;; (<= nan 0) and (>= nan nan) answered #t -- the second of those is
;; the claim that a NaN is ordered with respect to itself, which is
;; enough to let an ordered insert give it a position and make every
;; later comparison against it a lie, quietly and permanently.
;;
;; It also decides whether the guards spelled (and (real? x) (not (< x 0)))
;; keep NaN out: they do, and they do it through <, so they were never
;; the thing to fix.
(define (<= a b) (if (< a b) #t (= a b)))
(define (>= a b) (if (< b a) #t (= a b)))
;; R6RS max and min take one argument or more, not exactly two.  They
;; were binary, so `(max 1 5 2)' was a compile error and `(apply max
;; (list 3 9 4 100))' answered 9 -- the extra arguments went by without
;; a word.  (What they still do NOT do is R6RS's inexactness
;; contagion: `(max 1 2.0)' answers 2.0 here because that argument is
;; the larger, not because any argument was inexact, and `(max 3 2.0)'
;; answers 3 where R6RS asks for 3.0.  The binary version did not do it
;; either; making only the n-ary path do it would be a worse
;; inconsistency than leaving it, so it stays a known gap.)
(define (max a . rest)
  (let loop ((m a) (l rest))
    (if (null? l) m (loop (if (< m (car l)) (car l) m) (cdr l)))))
(define (min a . rest)
  (let loop ((m a) (l rest))
    (if (null? l) m (loop (if (< (car l) m) (car l) m) (cdr l)))))

;; A list has FINITE length by definition, so a chain that cycles is
;; not one and #f is the only answer -- but the answer has to ARRIVE.
;; The body used to be
;;     (if (null? x) #t (and (pair? x) (list? (cdr x))))
;; and `and` expands to `if`, which puts that call in tail position:
;; on a circular list it did not overflow the stack, it span forever.
;; No exception, no output, no return.  Of the ways this can go wrong
;; -- wrong answer, crash, hang -- the hang is the only one that does
;; not even say that something went wrong, and in a browser it takes
;; the tab with it.
;;
;; Two cursors, one stepping twice: they meet if and only if the chain
;; cycles, and neither outruns a proper list's end.
(define (list? x)
  (let loop ((slow x) (fast x))
    (cond ((null? fast) #t)
          ((not (pair? fast)) #f)
          ((null? (cdr fast)) #t)
          ((not (pair? (cdr fast))) #f)
          (else (let ((fast (cdr (cdr fast))) (slow (cdr slow)))
                  (and (not (eq? fast slow)) (loop slow fast)))))))

;; NOT memq/assq.  eq? on a flonum, a bignum or a ratio compares
;; identity, so (memv 2.0 '(1.0 2.0)) answered #f -- the number was in
;; the list and the search said it was not.  eqv? is the comparison
;; these two are defined by.
(define (memv x ls)
  (cond
   ((null? ls) #f)
   ((eqv? (car ls) x) ls)
   (else (memv x (cdr ls)))))

(define (assv x ls)
  (cond
   ((null? ls) #f)
   ((eqv? (caar ls) x) (car ls))
   (else (assv x (cdr ls)))))
(define (member x ls)
  (cond
   ((null? ls) #f)
   ((equal? (car ls) x) ls)
   (else (member x (cdr ls)))))
(define (assoc x ls)
  (cond
   ((null? ls) #f)
   ((equal? (caar ls) x) (car ls))
   (else (assoc x (cdr ls)))))

(define (list-tail ls n)
  (if (zero? n) ls (list-tail (cdr ls) (- n 1))))
(define (list-ref ls n)
  (car (list-tail ls n)))

(define (fold-left f init ls)
  (if (null? ls)
      init
      (fold-left f (f init (car ls)) (cdr ls))))
(define (fold-right f init ls)
  (if (null? ls)
      init
      (f (car ls) (fold-right f init (cdr ls)))))

(define (caddr p) (car (cddr p)))
(define (cdddr p) (cdr (cddr p)))
(define (cadddr p) (car (cdddr p)))
(define (cdadr p) (cdr (cadr p)))
(define (caadr p) (car (cadr p)))

(define (make-list n x)
  (if (zero? n) '() (cons x (make-list (- n 1) x))))

(define (number->string n)
  (with-output-to-string (lambda () (display n))))
;; The same face the reader reads, and #f for everything else --
;; including a numeral that denotes no number, which the reader refuses
;; and this answers #f for, as R6RS requires and as the reference does.
;;
;; NOT the reader itself: %finish-atom falls back to string->symbol, and
;; a procedure whose job is to answer #f cannot be built on one whose
;; job is to answer a symbol.
;;
;; The `#` prefixes are still absent here, and wiring did not add them:
;; they are read by %read-hash, one layer above the number body, so
;; (string->number "#x10") is still #f where Chez answers 16.
(define (string->number s)
  (%bytes->number (map (lambda (c) (char->integer c)) (string->list s))))

;; gensyms: fresh uninterned symbol structs; identity comes from the
;; struct allocation, so even same-named gensyms are distinct
(define $gensym-count 0)
(define (gensym prefix)
  (set! $gensym-count (+ $gensym-count 1))
  (%make-symbol (string-append prefix (number->string $gensym-count))))


(define (%abort) (%unreachable))

;; compatible with the host Chez errorf; format directives print as-is
(define (errorf who msg . irritants)
  (raise ($make-error who msg irritants)))

(define (eqv? a b)
  (or (eq? a b)
      (and (flonum? a) (flonum? b) ($fl-eqv? a b))
      (and (%bignum? a) (%bignum? b) ($eq2 a b))
      (and (%ratio? a) (%ratio? b) ($eq2 a b))
      (and (%complex? a) (%complex? b)
           (eqv? (%cx-re a) (%cx-re b))
           (eqv? (%cx-im a) (%cx-im b)))))
;; Two flonums are eqv? when they are the same number with the same
;; sign: 0.0 and -0.0 are fl=? and are not eqv? (R6RS 11.5), which the
;; sign of the reciprocal tells; and every NaN is eqv? to every NaN, as
;; on Chez (R6RS leaves it open).  $eqv-hash hashes every flonum to 0, so
;; it already agrees with this.
(define ($fl-eqv? a b)
  (if (fl=? a b)
      (or (not (fl=? a 0.0))
          (eq? (fl<? (fl/ 1.0 a) 0.0) (fl<? (fl/ 1.0 b) 0.0)))
      (and (not (fl=? a a)) (not (fl=? b b)))))
(define (number? x)
  (or (fixnum? x) (flonum? x) (%bignum? x) (%ratio? x) (%complex? x)))
;; x - x is 0.0 for every finite flonum, and NaN for an infinity or a
;; NaN -- so this is false exactly for the values that are not a
;; position on the number line.  (NaN was already excluded by the
;; floor test below, since NaN is not equal to itself; the infinities
;; were not, because flfloor of an infinity is that infinity.)
(define ($fl-finite? x) (fl=? (fl- x x) (fixnum->flonum 0)))

(define (integer? x)
  (or (fixnum? x) (%bignum? x)
      (and (flonum? x) ($fl-finite? x) (fl=? x (flfloor x)))))
(define (exact? x)
  (or (fixnum? x) (%bignum? x) (%ratio? x)
      (and (%complex? x) (exact? (%cx-re x)) (exact? (%cx-im x)))))
(define (inexact? x) (and (number? x) (not (exact? x))))
(define (cadar p) (car (cdar p)))

;; ---- derived binding forms (macros live in the prelude too) ----

;; both bind sequentially
(define-syntax let-values
  (syntax-rules ()
    ((_ () body1 body2 ...) (let () body1 body2 ...))
    ((_ ((formals expr) rest ...) body1 body2 ...)
     (call-with-values (lambda () expr)
       (lambda formals (let-values (rest ...) body1 body2 ...))))))
(define-syntax let*-values
  (syntax-rules ()
    ((_ bindings body1 body2 ...) (let-values bindings body1 body2 ...))))

(define-syntax assert
  (syntax-rules ()
    ((_ e) (let ((t e)) (if t t (errorf 'assert "assertion failed"))))))

(define (cons* a . rest) ($cons* a rest))
(define ($cons* a rest)
  (if (null? rest) a (cons a ($cons* (car rest) (cdr rest)))))

;; n-ary map and for-each
(define (map f ls . more)
  (if (null? more) ($map1 f ls) ($mapn f (cons ls more))))
(define ($map1 f ls) ($map1-acc f ls '()))
(define ($map1-acc f ls acc)
  (if (null? ls)
      (reverse acc)
      ($map1-acc f (cdr ls) (cons (f (car ls)) acc))))
(define ($mapn f lists)
  (if ($any-null? lists)
      '()
      (cons (apply f ($heads lists)) ($mapn f ($tails lists)))))
(define ($any-null? ls)
  (and (pair? ls) (or (null? (car ls)) ($any-null? (cdr ls)))))
(define ($heads ls) (if (null? ls) '() (cons (caar ls) ($heads (cdr ls)))))
(define ($tails ls) (if (null? ls) '() (cons (cdar ls) ($tails (cdr ls)))))
(define (for-each f ls . more)
  (if (null? more) ($for-each1 f ls) ($for-eachn f (cons ls more))))
(define ($for-each1 f ls)
  (unless (null? ls)
    (f (car ls))
    ($for-each1 f (cdr ls))))
(define ($for-eachn f lists)
  (unless ($any-null? lists)
    (apply f ($heads lists))
    ($for-eachn f ($tails lists))))

;; ---- dynamic-wind ----
;;
;; $winders holds (before . after) frames.  Escaping continuations
;; capture the winder stack; $escape runs the after thunks of every
;; frame being exited, then throws to the matching call/cc.

(define $winders '())

(define (dynamic-wind before thunk after)
  (before)
  (set! $winders (cons (cons before after) $winders))
  (let ((r (thunk)))
    (set! $winders (cdr $winders))
    (after)
    r))

(define ($escape tok saved v)
  ($unwind-to saved)
  (%throw-k tok v))
(define ($unwind-to saved)
  (unless (eq? $winders saved)
    (let ((w (car $winders)))
      (set! $winders (cdr $winders))
      ((cdr w))
      ($unwind-to saved))))

;; ---- vectors ----

(define (make-vector n . fill)
  (%make-vector n (if (null? fill) 0 (car fill))))
(define (vector . els) (list->vector els))
(define (list->vector ls)
  (let ((v (%make-vector (length ls) 0)))
    ($vfill! v ls 0)
    v))
(define ($vfill! v ls i)
  (unless (null? ls)
    (vector-set! v i (car ls))
    ($vfill! v (cdr ls) (+ i 1))))
(define (vector->list v)
  ($v->l v (- (vector-length v) 1) '()))
(define ($v->l v i acc)
  (if (< i 0) acc ($v->l v (- i 1) (cons (vector-ref v i) acc))))
(define (vector-fill! v x)
  ($vf! v x 0))
(define ($vf! v x i)
  (when (< i (vector-length v))
    (vector-set! v i x)
    ($vf! v x (+ i 1))))
(define (vector-map f v) (list->vector (map f (vector->list v))))
(define (vector-for-each f v) (for-each f (vector->list v)))

;; ---- bytevectors ----

(define (make-bytevector n . fill)
  (%make-bytevector n (if (null? fill) 0 (car fill))))
(define (bytevector . bytes)
  (let ((bv (%make-bytevector (length bytes) 0)))
    ($bvfill! bv bytes 0)
    bv))
(define ($bvfill! bv ls i)
  (unless (null? ls)
    (bytevector-u8-set! bv i (car ls))
    ($bvfill! bv (cdr ls) (+ i 1))))
(define (bytevector=? a b)
  (and (= (bytevector-length a) (bytevector-length b))
       ($bv= a b 0)))
(define ($bv= a b i)
  (or (= i (bytevector-length a))
      (and (= (bytevector-u8-ref a i) (bytevector-u8-ref b i))
           ($bv= a b (+ i 1)))))
(define (utf8->string bv)
  (let ((s (%make-string (bytevector-length bv))))
    ($bv->s bv s 0)
    s))
(define ($bv->s bv s i)
  (when (< i (bytevector-length bv))
    ;; from bytevector-u8-ref, so 0..255
    (string-set! s i (%integer->char (bytevector-u8-ref bv i)))
    ($bv->s bv s (+ i 1))))
(define (string->utf8 str)
  (let ((bv (%make-bytevector (string-length str) 0)))
    ($s->bv str bv 0)
    bv))
(define ($s->bv str bv i)
  (when (< i (string-length str))
    (bytevector-u8-set! bv i (char->integer (string-ref str i)))
    ($s->bv str bv (+ i 1))))

;; ---- hashtables (buckets of alists over vectors) ----

;; mutable? is #f only for a copy hashtable-copy made immutable; every
;; table the constructors make is mutable, so the procedures that change
;; a table refuse only a table nothing could make before that copy.
(define-record-type (hashtable $make-ht hashtable?)
  (fields (immutable hash $ht-hash)
          (immutable equiv $ht-equiv)
          (mutable size $ht-size $ht-size-set!)
          (mutable buckets $ht-buckets $ht-buckets-set!)
          (immutable mutable? $ht-mutable?)))

(define (make-eq-hashtable . _) ($new-ht $eqv-hash eq?))
(define (make-eqv-hashtable . _) ($new-ht $eqv-hash eqv?))
(define (make-hashtable hash equiv . _) ($new-ht hash equiv))
(define ($new-ht h e) ($make-ht h e 0 (make-vector 8 '()) #t))
(define ($ht-writable! who ht)
  (unless ($ht-mutable? ht)
    (error who "the hashtable is immutable" ht)))

(define (abs n) (if (< n 0) (- 0 n) n))
(define (string-hash s) ($sh s 0 7))
;; Preserve (31*h + c) modulo 2^29-1 without promoting the product
;; to a bignum. Fold 32*h at bit 29, then subtract h. Every intermediate
;; stays in the signed 30-bit fixnum range, including Unicode scalars.
;; Despite the name, this is the shared step for every (31*h + c)
;; modulo 2^29-1 site in this file, not only for the string hash.
;; It is total for h and c anywhere in 0..2^29-1.
(define ($sh-step h c)
  (let* ((folded (+ (bitwise-arithmetic-shift-left (bitwise-and h 16777215) 5)
                   (bitwise-arithmetic-shift-right h 24)))
         (difference (- folded h))
         (positive (if (< difference 0)
                       (+ difference 536870911) difference))
         (room (- 536870911 c)))
    (if (>= positive room) (- positive room) (+ positive c))))
(define ($sh s i h)
  (if (< i (string-length s))
      ($sh s (+ i 1)
           ($sh-step h (char->integer (string-ref s i))))
      h))
;; The same bound the string hash keeps, applied to the hash VALUE
;; rather than to the arithmetic that produces it.  Adding a tag to a
;; hash already near the top of the range would leave the fixnum range
;; in the addition itself, so the tag is added modulo 2^29-1 without
;; ever forming the oversized sum: subtract the room that is left
;; instead of adding into it.  Both arguments must already be within
;; the modulus.
(define ($m+ h tag)
  (let ((room (- 536870911 tag)))
    (if (>= h room) (- h room) (+ h tag))))
;; A length spreads a vector, string or bytevector by size.  The
;; multiply overflows BEFORE the addition does -- 7 * 76695845 is
;; already past the modulus -- so wrapping only the sum would not be
;; enough and the length is reduced first.
;;
;; This is deliberately NOT (7*n + tag) modulo 2^29-1, and the two part
;; company past a length of 76695840.  Below that -- which is every
;; length any of these objects can actually reach here -- it returns
;; exactly the tag + 7*n this used to return, so the change is confined
;; to the lengths that used to leave the range.
(define ($len-hash n tag)
  ($m+ (* 7 (remainder n 76695845)) tag))
;; The hash an eq/eqv table uses.  It may depend ONLY on things that
;; cannot change while the object sits in a table: a hash that moved
;; would leave the entry unreachable in a table that still holds it.
;; That rules out contents for anything mutable, which is why this is
;; not simply `equal-hash'.
;;
;; What each type can offer:
;;   - bignums, ratios, complexes are immutable, and `eqv?' compares
;;     them by value anyway, so their value is the honest hash;
;;   - a vector's or string's LENGTH is fixed for the life of the
;;     object (nothing in this runtime resizes one; vector-fill! does
;;     not), so it is eq-stable and spreads them BY SIZE -- which is
;;     sound and nearly useless, because objects of one size are the
;;     normal case: coordinates, colours, fixed-field records.  Twenty
;;     thousand one-element vectors still land in one bucket.
;;   - a record carries its rtd, which spreads records BY TYPE, with
;;     the same caveat: a table full of one record type gains nothing.
;;
;; So only the immutable numeric types are genuinely fixed here.  The
;; rest are divided into a handful of buckets instead of one, which is
;; not the same thing as being fast, and nothing in this file should be
;; read as saying eq-hashtables are now scalable.
;;
;; PAIRS AND PROCEDURES HAVE NOTHING that is both eq-stable and
;; varying: a pair's car and cdr are mutable, and a procedure offers
;; no observable at all.  They stay constant here, so a table with
;; many pair keys is still a linear scan.  Fixing that needs an
;; identity the runtime does not have -- see docs/limits.md, which
;; also records what would change it.
(define ($eqv-hash k)
  (cond
   ;; NOT (abs k): abs of the most negative fixnum is one past the
   ;; maximum, so that one key would hash to a bignum.  Folding the
   ;; negatives onto 0..maximum keeps every fixnum key inside the range
   ;; and costs the same comparison abs already made.  Every negative
   ;; fixnum hashes one lower than it did; -1 now collides with 0 where
   ;; it used to collide with 1.  Mapping 2^30 keys onto 2^29+1 values
   ;; collides either way, and only equal keys are required to agree.
   ((fixnum? k) (if (< k 0) (- -1 k) k))
   ((char? k) (char->integer k))
   ((symbol? k) (string-hash (symbol->string k)))
   ((eq? k #t) 1)
   ((eq? k #f) 2)
   ((null? k) 3)
   ;; A bignum is hashed through generic `remainder' rather than by
   ;; reading its limbs: %bignum-limbs is a wasm-backend primitive and
   ;; the JS backend does not implement it, so the limb version
   ;; compiled on one target and not the other.
   ((%bignum? k) ($m+ (abs (remainder k 536870911)) 11))
   ((%ratio? k) ($m+ ($sh-step ($eqv-hash (%ratio-num k))
                               ($eqv-hash (%ratio-den k)))
                     13))
   ((%complex? k) ($m+ ($sh-step ($eqv-hash (%cx-re k))
                                 ($eqv-hash (%cx-im k)))
                       17))
   ((number? k) 0)                      ; flonums: eqv? is by value,
                                        ; but no cheap stable spread
   ((vector? k) ($len-hash (vector-length k) 19))
   ((string? k) ($len-hash (string-length k) 23))
   ((bytevector? k) ($len-hash (bytevector-length k) 29))
   ((%recbase? k)
    ($m+ (string-hash (symbol->string (car (%record-rtd k)))) 31))
   (else 0)))                           ; pairs, procedures: see above
(define (equal-hash k)
  (cond
   ((string? k) (string-hash k))
   ((pair? k) ($sh-step (equal-hash (car k)) (equal-hash (cdr k))))
   (else ($eqv-hash k))))

(define ($ht-index ht k)
  (remainder (abs (($ht-hash ht) k))
             (vector-length ($ht-buckets ht))))
(define ($bucket-find equiv k bucket)
  (cond
   ((null? bucket) #f)
   ((equiv (caar bucket) k) (car bucket))
   (else ($bucket-find equiv k (cdr bucket)))))

(define (hashtable-ref ht k default)
  (let ((hit ($bucket-find ($ht-equiv ht) k
                           (vector-ref ($ht-buckets ht) ($ht-index ht k)))))
    (if hit (cdr hit) default)))
(define (hashtable-contains? ht k)
  (if ($bucket-find ($ht-equiv ht) k
                    (vector-ref ($ht-buckets ht) ($ht-index ht k)))
      #t
      #f))
(define (hashtable-set! ht k v)
  ($ht-writable! 'hashtable-set! ht)
  ($ht-set! ht k v))
(define ($ht-set! ht k v)
  (let* ((i ($ht-index ht k))
         (bucket (vector-ref ($ht-buckets ht) i))
         (hit ($bucket-find ($ht-equiv ht) k bucket)))
    (if hit
        (set-cdr! hit v)
        (begin
          (vector-set! ($ht-buckets ht) i (cons (cons k v) bucket))
          ($ht-size-set! ht (+ ($ht-size ht) 1))
          (when (< (* 2 (vector-length ($ht-buckets ht))) ($ht-size ht))
            ($ht-grow! ht))))))
(define (hashtable-delete! ht k)
  ($ht-writable! 'hashtable-delete! ht)
  (let* ((i ($ht-index ht k))
         (bucket (vector-ref ($ht-buckets ht) i)))
    (vector-set! ($ht-buckets ht) i
                 ($bucket-remove ($ht-equiv ht) k bucket
                                 (lambda () ($ht-size-set! ht (- ($ht-size ht) 1)))))))
(define ($bucket-remove equiv k bucket shrink!)
  (cond
   ((null? bucket) '())
   ((equiv (caar bucket) k) (shrink!) (cdr bucket))
   (else (cons (car bucket)
               ($bucket-remove equiv k (cdr bucket) shrink!)))))
(define (hashtable-size ht) ($ht-size ht))
(define (hashtable-update! ht k proc default)
  ($ht-writable! 'hashtable-update! ht)
  ($ht-set! ht k (proc (hashtable-ref ht k default))))
(define (hashtable-keys ht)
  (list->vector ($ht-fold ht (lambda (k v acc) (cons k acc)) '())))
(define ($ht-fold ht f acc)
  (let ((buckets ($ht-buckets ht)))
    (let loop ((i 0) (acc acc))
      (if (= i (vector-length buckets))
          acc
          (loop (+ i 1)
                (let scan ((b (vector-ref buckets i)) (acc acc))
                  (if (null? b)
                      acc
                      (scan (cdr b) (f (caar b) (cdar b) acc)))))))))
(define ($ht-grow! ht)
  (let ((old ($ht-buckets ht)))
    ($ht-buckets-set! ht (make-vector (* 2 (vector-length old)) '()))
    ($ht-size-set! ht 0)
    (let loop ((i 0))
      (when (< i (vector-length old))
        (let scan ((b (vector-ref old i)))
          (unless (null? b)
            ($ht-set! ht (caar b) (cdar b))
            (scan (cdr b))))
        (loop (+ i 1))))))

;; ---- the numeric tower: bignums and flonum contagion ----
;;
;; Bignums: sign flag plus a vector of 15-bit limbs, little-endian.
;; The compiler's inline fixnum paths call $add2/$sub2/$mul2/$quot2/
;; $rem2/$lt2/$eq2 on overflow or non-fixnum operands.

;; The inline arithmetic shifts call these when they cannot answer
;; exactly: a left shift whose result is not a fixnum, or a negative
;; count for either.  The bitwise operations take fixnums only, so the
;; answer is a refusal and not a bignum; it is a condition naming the
;; procedure, so a guard can catch it.
(define ($shl-refused n k)
  (if (< k 0)
      (error 'bitwise-arithmetic-shift-left "negative shift count" n k)
      (error 'bitwise-arithmetic-shift-left
             "the shifted value is not a fixnum" n k)))
(define ($shr-refused n k)
  (error 'bitwise-arithmetic-shift-right "negative shift count" n k))

(define ($bn-limbs-of n)                ; fixnum magnitude -> limb vector
  (let count ((m n) (k 0))
    (if (zero? m)
        (let ((v (make-vector (if (< 0 k) k 1) 0)))
          (let fill ((m n) (i 0))
            (if (zero? m)
                v
                (begin (vector-set! v i (remainder m 16384))
                       (fill (quotient m 16384) (+ i 1))))))
        (count (quotient m 16384) (+ k 1)))))
(define ($fx->bn n)
  (cond
   ((< n 0)
    ;; negating -2^29 overflows back into the slow path; its limbs
    ;; are known
    (if (= n (* -2 268435456))
        (%make-bignum 1 (vector 0 0 2))
        (%make-bignum 1 ($bn-limbs-of (- 0 n)))))
   (else (%make-bignum 0 ($bn-limbs-of n)))))
(%target-case
 (js
  ;; the integer layer rides the host's arbitrary-precision integers;
  ;; the limb machinery above is never referenced on this target and
  ;; DCE removes it
  (define ($->bn x) (if (fixnum? x) (%fx->big x) x))
  (define ($bn-add a b) (%big-norm (%big-add a b)))
  (define ($bn-negate b) (%big-neg b))
  (define ($bn-mul2 a b) (%big-norm (%big-mul ($->bn a) ($->bn b))))
  (define ($bn-quot2 a b) (%big-norm (%big-quot ($->bn a) ($->bn b))))
  (define ($bn-rem2 a b) (%big-norm (%big-rem ($->bn a) ($->bn b))))
  (define ($bn-lt2 a b) (%big-lt ($->bn a) ($->bn b)))
  (define ($bn-eq2 a b) (%big-eq ($->bn a) ($->bn b)))
  (define ($bn->fl x) (%big->fl x)))
 (wasm
  (define ($->bn x) (if (fixnum? x) ($fx->bn x) x))))
(define ($bn-neg? b) (= (%bignum-sign b) 1))

(define ($bn-norm sign limbs)
  ;; strip leading zeroes; collapse to a fixnum when the value fits
  ;; (three limbs still fit when the top one is 0 or 1)
  (let strip ((n (vector-length limbs)))
    (cond
     ((and (< 1 n) (zero? (vector-ref limbs (- n 1)))) (strip (- n 1)))
     ;; the asymmetric fixnum boundary: -2^29 fits, +2^29 does not
     ;; (the product below stays on the inline fast path)
     ((and (= n 3) (= sign 1)
           (= (vector-ref limbs 2) 2)
           (zero? (vector-ref limbs 1))
           (zero? (vector-ref limbs 0)))
      (* -2 268435456))
     ((or (< n 3) (and (= n 3) (< (vector-ref limbs 2) 2)))
      (let ((v (+ (vector-ref limbs 0)
                  (if (< 1 n) (* (vector-ref limbs 1) 16384) 0)
                  (if (< 2 n) (* (vector-ref limbs 2) 268435456) 0))))
        (if (= sign 1) (- 0 v) v)))
     (else
      (%make-bignum sign
                    (if (= n (vector-length limbs))
                        limbs
                        (let ((w (make-vector n 0)))
                          (let copy ((i 0))
                            (if (= i n)
                                w
                                (begin (vector-set! w i (vector-ref limbs i))
                                       (copy (+ i 1))))))))))))

(define ($mag-cmp a b)                  ; limb vectors -> -1 0 1
  (let ((la ($mag-len a)) (lb ($mag-len b)))
    (cond
     ((< la lb) -1)
     ((< lb la) 1)
     (else
      (let loop ((i (- la 1)))
        (cond
         ((< i 0) 0)
         ((< (vector-ref a i) (vector-ref b i)) -1)
         ((< (vector-ref b i) (vector-ref a i)) 1)
         (else (loop (- i 1)))))))))
(define ($mag-len v)                    ; length ignoring leading zeroes
  (let loop ((n (vector-length v)))
    (if (and (< 1 n) (zero? (vector-ref v (- n 1))))
        (loop (- n 1))
        n)))

(define ($mag-add a b)
  (let* ((la ($mag-len a)) (lb ($mag-len b))
         (n (+ (if (< la lb) lb la) 1))
         (r (make-vector n 0)))
    (let loop ((i 0) (carry 0))
      (if (= i n)
          r
          (let ((s (+ carry
                      (+ (if (< i la) (vector-ref a i) 0)
                         (if (< i lb) (vector-ref b i) 0)))))
            (vector-set! r i (remainder s 16384))
            (loop (+ i 1) (quotient s 16384)))))))
(define ($mag-sub a b)                  ; assumes a >= b
  (let* ((la ($mag-len a))
         (r (make-vector la 0)))
    (let loop ((i 0) (borrow 0))
      (if (= i la)
          r
          (let ((d (- (- (vector-ref a i) borrow)
                      (if (< i ($mag-len b)) (vector-ref b i) 0))))
            (if (< d 0)
                (begin (vector-set! r i (+ d 16384)) (loop (+ i 1) 1))
                (begin (vector-set! r i d) (loop (+ i 1) 0))))))))
(define ($mag-mul a b)
  (let* ((la ($mag-len a)) (lb ($mag-len b))
         (r (make-vector (+ la lb) 0)))
    (let outer ((i 0))
      (if (= i la)
          r
          (begin
            (let inner ((j 0) (carry 0))
              (if (= j lb)
                  (vector-set! r (+ i j)
                               (+ (vector-ref r (+ i j)) carry))
                  (let ((t (+ (+ (vector-ref r (+ i j)) carry)
                              (* (vector-ref a i) (vector-ref b j)))))
                    (vector-set! r (+ i j) (remainder t 16384))
                    (inner (+ j 1) (quotient t 16384)))))
            (outer (+ i 1)))))))
(define ($mag-divmod-small v d)         ; -> (quotient-vec . rem-fixnum)
  (let* ((n ($mag-len v))
         (q (make-vector n 0)))
    (let loop ((i (- n 1)) (rem 0))
      (if (< i 0)
          (cons q rem)
          (let ((cur (+ (* rem 16384) (vector-ref v i))))
            (vector-set! q i (quotient cur d))
            (loop (- i 1) (remainder cur d)))))))

(%target-case
 (js)
 (wasm
  (define ($bn-add a b)                 ; bignum x bignum
    (let ((sa (%bignum-sign a)) (sb (%bignum-sign b))
          (ma (%bignum-limbs a)) (mb (%bignum-limbs b)))
      (cond
       ((= sa sb) ($bn-norm sa ($mag-add ma mb)))
       ((< ($mag-cmp ma mb) 0) ($bn-norm sb ($mag-sub mb ma)))
       (else ($bn-norm sa ($mag-sub ma mb))))))
  (define ($bn-negate b)
    (%make-bignum (- 1 (%bignum-sign b)) (%bignum-limbs b)))))

;; ---- exact -> inexact, in ONE rounding ----
;; An exact value wider than 53 bits has to be rounded, and rounding
;; more than once is not the same as rounding once: two conversions
;; and a division land up to two ulp from the nearest double, and land
;; there differently on the two targets.  So the scaling and the
;; rounding decision are made in the EXACT integer layer -- where both
;; targets are forced to agree, every operation in it being exact --
;; and only a 53-bit significand and a power of two ever cross into
;; f64, both of which f64 represents exactly.
;;
;; $exact->fl is the single entry point: bignum -> flonum, ratio ->
;; flonum and the reader's decimal literals all round here, once.
(define ($int-bitlen n)                 ; n >= 0, exact
  (let coarse ((m n) (b 0))
    (if (< m 16777216)                  ; 2^24, a fixnum-safe stride
        (let fine ((m m) (b b))
          (if (= m 0) b (fine (quotient m 2) (+ b 1))))
        (coarse (quotient m 16777216) (+ b 24)))))

(define ($pow2 k)                       ; 2^k, exact, by squaring
  (if (= k 0)
      1
      (let* ((h ($pow2 (quotient k 2)))
             (hh (* h h)))
        (if (= 0 (- k (* 2 (quotient k 2)))) hh (* hh 2)))))

(define ($small->fl m)                  ; exact 0 <= m < 2^53, exactly
  (let* ((hi (quotient m 67108864))     ; 2^26: both halves are fixnums
         (lo (- m (* hi 67108864))))
    (fl+ (fl* (fixnum->flonum hi) 67108864.0) (fixnum->flonum lo))))

(define ($fl-scale2 v k)                ; v * 2^k, exact until it can
  (cond                                 ; no longer be (overflow, or
   ((= k 0) v)                          ; the subnormal floor)
   ((< k 0) ($fl-scale2 (fl* v 0.5) (+ k 1)))
   (else ($fl-scale2 (fl* v 2.0) (- k 1)))))

(define ($nonneg->fl num den)           ; num >= 0, den > 0
  (if (= num 0)
      0.0
      ;; scale num/den into [2^53, 2^54) so the quotient carries the
      ;; 53 bits that survive plus one guard bit, and the division
      ;; remainder is the sticky bit
      (let* ((k (- 54 (- ($int-bitlen num) ($int-bitlen den))))
             (n (if (< 0 k) (* num ($pow2 k)) num))
             (d (if (< k 0) (* den ($pow2 (- 0 k))) den)))
        (let norm ((n n) (d d) (e (- 0 k)))
          (let ((q (quotient n d)))     ; value = (n/d) * 2^e
            (cond
             ((< q 9007199254740992) (norm (* n 2) d (- e 1)))     ; 2^53
             ((< 18014398509481983 q) (norm n (* d 2) (+ e 1)))    ; 2^54
             (else
              ;; q holds 53 significant bits and one guard bit, and the
              ;; division remainder is the sticky bit.  Rounding here
              ;; is right only when the RESULT has 53 bits to keep.
              ;;
              ;; Below the normal floor it does not.  The value is
              ;; about half * 2^(e+1), so its binade exponent is
              ;; e + 53, and a result under 2^-1022 has
              ;;     deficit = -1075 - e
              ;; bits fewer than 53 to store.  Rounding at 53 and then
              ;; letting $fl-scale2 halve into place rounds a SECOND
              ;; time, and the first rounding has already absorbed the
              ;; evidence the second one needs: "strictly above the
              ;; halfway point" becomes "exactly at it", and ties-to-
              ;; even sends it the other way.  That is one ulp, on the
              ;; values that sit just above a halfway point -- which is
              ;; why most subnormals were right and a few were not.
              ;;
              ;; So drop the bits in ONE step, at the width the result
              ;; actually has.  `drop` is 1 in the normal case, which
              ;; is the old behaviour: one formula, not a special case
              ;; bolted beside it.
              ;;
              ;; The unit works out to exactly 2^-1074 whenever the
              ;; result is subnormal (2^(e+drop) with drop = 1+deficit),
              ;; so `keep` counts smallest-subnormals and the scaling
              ;; afterwards is exact by construction rather than by
              ;; hope.  A carry out of the top -- keep reaching 2^52 --
              ;; needs no special handling: that value times 2^-1074 IS
              ;; the smallest normal, which is the correct answer, and
              ;; the transition cells in test/exact-to-flonum.ss are
              ;; the ones that would notice if it were dropped.
              (let* ((deficit (- (- 0 1075) e))
                     ;; Past 55 the answer is zero and the width stops
                     ;; mattering: q is under 2^54, so it cannot reach
                     ;; half of the unit, and building a power of two
                     ;; with thousands of bits to divide by would only
                     ;; slow down the way there.  1e-4000 takes this
                     ;; path.
                     (drop (cond ((< deficit 1) 1)
                                 ((< 54 deficit) 55)
                                 (else (+ 1 deficit))))
                     (unit ($pow2 drop))
                     (keep (quotient q unit))
                     (rest (- q (* keep unit)))
                     (halfway (quotient unit 2))
                     ;; sticky = some bit BELOW the guard is set.  The
                     ;; guard is the top bit of `rest`, so that is
                     ;; exactly rest > halfway -- and the division
                     ;; remainder carries the bits that never reached
                     ;; the quotient at all.
                     (sticky (or (not (= (- n (* q d)) 0))
                                 (< halfway rest)))
                     (guard (if (< rest halfway) 0 1))
                     (odd (- keep (* (quotient keep 2) 2)))
                     (rounded                     ; nearest, ties to even
                      (if (and (= guard 1) (or sticky (= odd 1)))
                          (+ keep 1)
                          keep)))
                ($fl-scale2 ($small->fl rounded) (+ e drop))))))))))

(define ($exact->fl num den)            ; den > 0
  (if (< num 0)
      ;; multiply, don't subtract: an exact negative small enough to
      ;; round to zero must come out as -0.0, and 0.0 - 0.0 is +0.0
      (fl* (fixnum->flonum -1) ($nonneg->fl (- 0 num) den))
      ($nonneg->fl num den)))

(define ($->fl x)
  (cond
   ((flonum? x) x)
   ((fixnum? x) (fixnum->flonum x))
   ((%ratio? x) ($exact->fl (%ratio-num x) (%ratio-den x)))
   (else ($bn->fl x))))
(%target-case
 (js)
 (wasm
  ;; The limb layer's one rounding operation, and so the one place it
  ;; could disagree with the JS target's exact BigInt layer: a Horner
  ;; accumulation over base-16384 limbs rounds ONCE PER LIMB.  Round
  ;; once instead, in the exact layer both targets share.  (The JS
  ;; branch stays on the host's Number(bigint), already one correctly
  ;; rounded step -- two mechanisms, one answer, pinned against each
  ;; other by test/determinism-battery.ss.)
  (define ($bn->fl x)
    (if ($bn-neg? x)
        (fl- 0.0 ($nonneg->fl ($bn-negate x) 1))
        ($nonneg->fl x 1)))))

(define ($add2 a b)
  (cond
   ((or (%complex? a) (%complex? b))
    ($cx ($add2 (real-part a) (real-part b))
         ($add2 (imag-part a) (imag-part b))))
   ((or (flonum? a) (flonum? b))
    (fl+ ($->fl a) ($->fl b)))
   ((or (%ratio? a) (%ratio? b))
    ($make-rat ($add2 ($mul2 (numerator a) (denominator b))
                      ($mul2 (numerator b) (denominator a)))
               ($mul2 (denominator a) (denominator b))))
   (else ($bn-add ($->bn a) ($->bn b)))))
(define ($sub2 a b)
  (cond
   ((or (%complex? a) (%complex? b))
    ($cx ($sub2 (real-part a) (real-part b))
         ($sub2 (imag-part a) (imag-part b))))
   ((or (flonum? a) (flonum? b))
    (fl- ($->fl a) ($->fl b)))
   ((or (%ratio? a) (%ratio? b))
    ($make-rat ($sub2 ($mul2 (numerator a) (denominator b))
                      ($mul2 (numerator b) (denominator a)))
               ($mul2 (denominator a) (denominator b))))
   (else ($bn-add ($->bn a) ($bn-negate ($->bn b))))))
(define ($mul2 a b)
  (cond
   ((or (%complex? a) (%complex? b))
    (let ((ar (real-part a)) (ai (imag-part a))
          (br (real-part b)) (bi (imag-part b)))
      ($cx ($sub2 ($mul2 ar br) ($mul2 ai bi))
           ($add2 ($mul2 ar bi) ($mul2 ai br)))))
   ((or (flonum? a) (flonum? b))
    (fl* ($->fl a) ($->fl b)))
   ((or (%ratio? a) (%ratio? b))
    ($make-rat ($mul2 (numerator a) (numerator b))
               ($mul2 (denominator a) (denominator b))))
   (else ($bn-mul2 a b))))
(%target-case
 (js)
 (wasm
  (define ($bn-mul2 a b)
    (let ((ba ($->bn a)) (bb ($->bn b)))
      ($bn-norm (if (= (%bignum-sign ba) (%bignum-sign bb)) 0 1)
                ($mag-mul (%bignum-limbs ba) (%bignum-limbs bb)))))))
(define ($quot2 a b)
  (cond
   ((or (flonum? a) (flonum? b))
    (fltruncate (fl/ ($->fl a) ($->fl b))))
   ((and (integer? a) (integer? b))
    (when ($eq2 b 0) (errorf 'quotient "division by zero"))
    ($bn-quot2 a b))
   (else (errorf 'quotient "unsupported operand combination"))))
(%target-case
 (js)
 (wasm
  (define ($bn-quot2 a b)
    (if (and (%bignum? a) (fixnum? b) (< 0 b) (< b 16385))
        (let ((qr ($mag-divmod-small (%bignum-limbs a) b)))
          ($bn-norm (%bignum-sign a) (car qr)))
        (let* ((ba ($->bn a)) (bb ($->bn b))
               (qr ($mag-divmod (%bignum-limbs ba) (%bignum-limbs bb))))
          ($bn-norm (if (= (%bignum-sign ba) (%bignum-sign bb)) 0 1)
                    (car qr)))))))
(define ($rem2 a b)
  (cond
   ((or (flonum? a) (flonum? b))
    (let ((q (fltruncate (fl/ ($->fl a) ($->fl b)))))
      (fl- ($->fl a) (fl* q ($->fl b)))))
   ((and (integer? a) (integer? b))
    (when ($eq2 b 0) (errorf 'remainder "division by zero"))
    ($bn-rem2 a b))
   (else (errorf 'remainder "unsupported operand combination"))))
(%target-case
 (js)
 (wasm
  (define ($bn-rem2 a b)
    (if (and (%bignum? a) (fixnum? b) (< 0 b) (< b 16385))
        (let ((r (cdr ($mag-divmod-small (%bignum-limbs a) b))))
          (if ($bn-neg? a) (- 0 r) r))
        (let* ((ba ($->bn a)) (bb ($->bn b))
               (qr ($mag-divmod (%bignum-limbs ba) (%bignum-limbs bb)))
               (r ($bn-norm 0 (cdr qr))))
          (if ($bn-neg? ba) (- 0 r) r))))))
(define ($lt2 a b)
  (cond
   ((or (%complex? a) (%complex? b))
    (errorf '< "complex numbers are not ordered"))
   ((or (flonum? a) (flonum? b))
    (fl<? ($->fl a) ($->fl b)))
   ((or (%ratio? a) (%ratio? b))
    ;; denominators are positive, so cross-multiplication is safe
    ($lt2 ($mul2 (numerator a) (denominator b))
          ($mul2 (numerator b) (denominator a))))
   (else ($bn-lt2 a b))))
(%target-case
 (js)
 (wasm
  (define ($bn-lt2 a b)
    (let* ((ba ($->bn a)) (bb ($->bn b))
           (sa (%bignum-sign ba)) (sb (%bignum-sign bb)))
      (cond
       ((< sa sb) #f)
       ((< sb sa) #t)
       ((= sa 1) (< 0 ($mag-cmp (%bignum-limbs ba) (%bignum-limbs bb))))
       (else (< ($mag-cmp (%bignum-limbs ba) (%bignum-limbs bb)) 0)))))))
(define ($eq2 a b)
  (cond
   ((or (%complex? a) (%complex? b))
    (and ($eq2 (real-part a) (real-part b))
         ($eq2 (imag-part a) (imag-part b))))
   ((or (flonum? a) (flonum? b))
    (fl=? ($->fl a) ($->fl b)))
   ((or (%ratio? a) (%ratio? b))
    (and ($eq2 (numerator a) (numerator b))
         ($eq2 (denominator a) (denominator b))))
   (else ($bn-eq2 a b))))
(%target-case
 (js)
 (wasm
  (define ($bn-eq2 a b)
    (let ((ba ($->bn a)) (bb ($->bn b)))
      (and (= (%bignum-sign ba) (%bignum-sign bb))
           (zero? ($mag-cmp (%bignum-limbs ba) (%bignum-limbs bb))))))))

;; division and conversions
(define (/ a . rest)
  (if (null? rest)
      ($div2 1 a)
      (fold-left $div2 a rest)))
(define ($div2 a b)
  (cond
   ((or (%complex? a) (%complex? b))
    (let* ((ar (real-part a)) (ai (imag-part a))
           (br (real-part b)) (bi (imag-part b))
           (den ($add2 ($mul2 br br) ($mul2 bi bi))))
      ($cx ($div2 ($add2 ($mul2 ar br) ($mul2 ai bi)) den)
           ($div2 ($sub2 ($mul2 ai br) ($mul2 ar bi)) den))))
   ((or (flonum? a) (flonum? b))
    (fl/ ($->fl a) ($->fl b)))
   (else
    ($make-rat ($mul2 (numerator a) (denominator b))
               ($mul2 (denominator a) (numerator b))))))
;; $->fl has no complex case: it falls through to the bignum path
;; and the cast traps -- and a wasm trap is not a condition, so a
;; caller cannot even catch it.  A complex converts component-wise.
(define ($->inexact x)
  (if (%complex? x)
      ($cx ($->fl (%cx-re x)) ($->fl (%cx-im x)))
      ($->fl x)))
(define (exact->inexact x) ($->inexact x))
(define (inexact x) ($->inexact x))
(define ($fl->exact-integer m)
  ;; integral non-negative flonum -> exact, in 2^24 chunks
  (let ((two24 (fixnum->flonum 16777216)))
    (let loop ((m m) (acc 0) (scale 1))
      (if (fl<? m (fixnum->flonum 1))
          acc
          (let* ((q (flfloor (fl/ m two24)))
                 (digit (%fl->fx (fl- m (fl* q two24)))))
            (loop q (+ acc (* digit scale)) (* scale 16777216)))))))
(define (inexact->exact x)
  ;; NaN and the infinities have no exact equivalent, and NEITHER branch
  ;; below can say so -- each fails in its own way, and both are worse
  ;; than an error.
  ;;
  ;; NaN reaches the doubling loop, where (fl=? m (flfloor m)) is false
  ;; for NaN however many times it is doubled.  The loop never
  ;; terminates AND k doubles every pass, so it allocates bignums
  ;; without bound: measured at 47 minutes on one core with no output
  ;; and no exit.  (exact (/ 0.0 0.0)) does it too, so this is reachable
  ;; from arithmetic and not only from a literal.
  ;;
  ;; The infinities take the same loop but leave it at once, because
  ;; flfloor of an infinity is that infinity, and then
  ;; $fl->exact-integer traps in %fl->fx.  That is an abort rather than
  ;; a condition -- guard cannot catch it and the process ends.
  ;;
  ;; Both are argument errors, not implementation limits, and `exact' is
  ;; reached from data as often as from a literal: a parsed float, a
  ;; division that went 0/0, a reading off a device.  A caller has to be
  ;; able to skip the record and say which one it skipped, which an
  ;; abort does not allow and an endless loop does not even report.
  (when (and (flonum? x) (not ($fl-finite? x)))
    (error 'inexact->exact "no exact equivalent" x))
  (cond
   ;; Integral doubles inside the signed 30-bit fixnum range need no
   ;; rational construction. Fractional and larger values keep the
   ;; existing exact conversion; the range tests also reject nonfinite x.
   ((and (flonum? x) (not (fl<? x -536870912.0)) (fl<? x 536870912.0)
         (fl=? x (flfloor x)))
    (%fl->fx x))
   ((flonum? x)
      (let* ((zero (fixnum->flonum 0))
             (neg (fl<? x zero))
             (mag (if neg (fl- zero x) x)))
        (let loop ((m mag) (k 1))
          (if (fl=? m (flfloor m))
              (let ((v ($make-rat ($fl->exact-integer m) k)))
                (if neg (- 0 v) v))
              (loop (fl* m (fixnum->flonum 2)) (* k 2))))))
   (else x)))
(define (exact x) (inexact->exact x))
;; A ratio used to be returned unchanged, so (floor 7/2) was 7/2.
;; $make-rat keeps the denominator positive and collapses d = 1 to an
;; integer, so a live ratio is never integral -- which is why the
;; negative case always steps down by one rather than testing for it.
;;
;; floor and truncate differ ONLY on negatives: (floor -7/2) is -4
;; and (truncate -7/2) is -3.  A version that rounded both toward zero
;; would agree with this one on every positive input.
(define (floor x)
  (cond
   ((flonum? x) (flfloor x))
   ((%ratio? x)
    (let ((q (quotient (%ratio-num x) (%ratio-den x))))
      (if (< (%ratio-num x) 0) (- q 1) q)))
   (else x)))

(define (truncate x)
  (cond
   ((flonum? x) (fltruncate x))
   ((%ratio? x) (quotient (%ratio-num x) (%ratio-den x)))
   (else x)))
(define (sqrt x)
  (if (and (real? x) (< x 0))
      ($cx 0 (flsqrt ($->fl (- 0 x))))
      (flsqrt ($->fl x))))

;; ---- R6RS division: div/mod floor the remainder into [0, |d|),
;; div0/mod0 center it in [-|d|/2, |d|/2).  Exact integers only --
;; deliberately narrower than R6RS's real contract -- so the answers
;; are always exact and the sign corrections are total.  Built on
;; the truncating quotient/remainder generics, so fixnums and
;; bignums route the same.
(define ($div-check who n d)
  (unless (and (or (fixnum? n) (%bignum? n))
               (or (fixnum? d) (%bignum? d)))
    (errorf who "operands must be exact integers"))
  (when (= d 0) (errorf who "division by zero")))
(define ($div n d)
  (let ((q (quotient n d)) (r (remainder n d)))
    (if (< r 0) (if (< d 0) (+ q 1) (- q 1)) q)))
(define ($mod n d)
  ;; The floor below is the true one, for two reasons rather than one.
  ;; When the quotient is NOT an integer its distance to the nearest
  ;; integer is at least 1/|d|, while the division error is at most
  ;; |n/d| * 2^-53; the |d| cancels, so the error is the smaller of the
  ;; two whenever |n| < 2^53, which a signed 30-bit dividend is by a
  ;; wide margin. When the quotient IS an integer that argument says
  ;; nothing -- both quantities are zero -- and the other half applies:
  ;; the quotient is exactly representable, so a correctly rounded
  ;; division returns it exactly. The floored quotient product and
  ;; remainder are exact in binary64, even for the minimum fixnum
  ;; divisor. Keep generic remainder for larger integers and preserve
  ;; public checks.
  (if (and (fixnum? n) (fixnum? d) (not (= d 0)))
      (let* ((x (fixnum->flonum n)) (m (fixnum->flonum d))
             (m (if (fl<? m 0.0) (fl- 0.0 m) m)))
        (%fl->fx (fl- x (fl* (flfloor (fl/ x m)) m))))
      (let ((r (remainder n d)))
        (if (< r 0) (if (< d 0) (- r d) (+ r d)) r))))
(define (div n d) ($div-check 'div n d) ($div n d))
(define (mod n d) ($div-check 'mod n d) ($mod n d))
(define (div0 n d)
  ($div-check 'div0 n d)
  (let ((q ($div n d)) (r ($mod n d)))
    (if (< (+ r r) (abs d))
        q
        (if (< d 0) (- q 1) (+ q 1)))))
(define (mod0 n d)
  ($div-check 'mod0 n d)
  (let ((r ($mod n d)))
    (if (< (+ r r) (abs d))
        r
        (- r (abs d)))))

;; ---- trigonometry: reduce to [-pi/2, pi/2], one odd polynomial ----
;; The single supply of sin/cos/tan, in two layers.  $sin-fl and
;; friends take a FLONUM and are the whole implementation; sin/cos/tan
;; are the R6RS entries and only widen their argument.  The split
;; exists so the flonum layer can qualify for the compiler's f64
;; parameter specialization, which a generic $->fl on the way in
;; would disqualify.
;;
;; Measured, so nobody has to re-derive it: 40M calls, user time.
;; Calling $sin-fl directly costs 0.36 -- the same as the old
;; arrangement where the implementation lived in (gfx mat).  But
;; qualification is WHOLE-PROGRAM: one retained call site that cannot
;; be proved to pass a flonum demotes the function for every caller,
;; so merely linking a wrapper that forwards a boxed parameter puts it
;; back to 0.45.  That is why (gfx mat)'s wrappers hand over an
;; explicitly flonum expression rather than the bare parameter.
;;
;; Accuracy: error < 1e-9 measured up to |x| ~ 1e6.  Past that the
;; single-step 2pi reduction degrades with amplitude (measured ~2.4e-8
;; at 2^29), because k*2pi is itself rounded once.
(define $trig-pi 3.141592653589793)
(define $trig-2pi 6.283185307179586)
(define $trig-pi/2 1.5707963267948966)

(define ($sin-poly x)                   ; |x| <= pi/2, error < 1e-9
  (let ((x2 (fl* x x)))
    (fl* x
         (fl- 1.0 (fl* (fl/ x2 6.0)
              (fl- 1.0 (fl* (fl/ x2 20.0)
                   (fl- 1.0 (fl* (fl/ x2 42.0)
                        (fl- 1.0 (fl* (fl/ x2 72.0)
                             (fl- 1.0 (fl* (fl/ x2 110.0)
                                  (fl- 1.0 (fl* (fl/ x2 156.0)
                                       (fl- 1.0 (fl/ x2 210.0)))))))))))))))))

;; the flonum layer: what the per-frame paths call
(define ($sin-fl x)
  (let* ((k (flfloor (fl+ (fl/ x $trig-2pi) 0.5)))
         (r (fl- x (fl* k $trig-2pi))))     ; r in [-pi, pi]
    ($sin-poly
     (cond ((fl<? $trig-pi/2 r) (fl- $trig-pi r))
           ((fl<? r (fl- 0.0 $trig-pi/2)) (fl- (fl- 0.0 $trig-pi) r))
           (else r)))))
(define ($cos-fl x) ($sin-fl (fl+ x $trig-pi/2)))
(define ($tan-fl x) (fl/ ($sin-fl x) ($cos-fl x)))

;; the R6RS entries: widen, then hand over
(define (sin v) ($sin-fl ($->fl v)))
(define (cos v) ($cos-fl ($->fl v)))
(define (tan v) ($tan-fl ($->fl v)))

;; ---- the string library ----

(define (make-string n . fill)
  (let ((s (%make-string n)))
    (unless (null? fill) (string-fill! s (car fill)))
    s))
(define (string-fill! s c)
  (let loop ((i 0))
    (when (< i (string-length s))
      (string-set! s i c)
      (loop (+ i 1)))))
(define (string . chars) (list->string chars))
(define (substring s start end)
  (let ((r (%make-string (- end start))))
    (let loop ((i start))
      (when (< i end)
        (string-set! r (- i start) (string-ref s i))
        (loop (+ i 1))))
    r))
(define (string-copy s) (substring s 0 (string-length s)))
(define (string-append . ss)
  ($strings-join ss))
(define ($strings-join ss)
  (let* ((total (fold-left (lambda (n s) (+ n (string-length s))) 0 ss))
         (r (%make-string total)))
    (let outer ((ss ss) (at 0))
      (if (null? ss)
          r
          (let ((s (car ss)))
            (let inner ((i 0))
              (when (< i (string-length s))
                (string-set! r (+ at i) (string-ref s i))
                (inner (+ i 1))))
            (outer (cdr ss) (+ at (string-length s))))))))

(define ($string-cmp a b)               ; lexicographic: -1 0 1
  (let ((la (string-length a)) (lb (string-length b)))
    (let loop ((i 0))
      (cond
       ((and (= i la) (= i lb)) 0)
       ((= i la) -1)
       ((= i lb) 1)
       ((< (char->integer (string-ref a i)) (char->integer (string-ref b i))) -1)
       ((< (char->integer (string-ref b i)) (char->integer (string-ref a i))) 1)
       (else (loop (+ i 1)))))))
(define (string<? a b) (< ($string-cmp a b) 0))
(define (string>? a b) (< 0 ($string-cmp a b)))
(define (string<=? a b) (< ($string-cmp a b) 1))
(define (string>=? a b) (< -1 ($string-cmp a b)))

(define (char=? a b) (eq? a b))
(define (char<? a b) (< (char->integer a) (char->integer b)))
(define (char>? a b) (< (char->integer b) (char->integer a)))
(define (char<=? a b) (not (char>? a b)))
(define (char>=? a b) (not (char<? a b)))
;; R6RS gives integer->char a UNICODE SCALAR VALUE: an exact integer in
;; 0..#x10FFFF, excluding the surrogate block #xD800..#xDFFF.  The
;; primitive underneath only sets the tag bit -- a character here is a
;; tagged fixnum -- so without this nothing anywhere enforced the range,
;; and (integer->char 1114112) answered a "character" past the top of
;; Unicode.
;;
;; The range is R6RS's and NOT this runtime's byte model, deliberately.
;; Narrowing to 0..255 would not buy the identity it looks like it buys.
;; A character here HOLDS its value -- (char->integer (integer->char 256))
;; is 256 -- and the truncation to a byte happens when the character is
;; STORED IN A STRING: that same character read back out of a string is
;; 0.  So (string (integer->char 233)) is one byte holding #xE9 while
;; "\xE9;" is two, because a string literal names a CODE POINT and
;; stores its UTF-8 encoding.  That difference is about storage, not
;; about this procedure's range, and it survives any range.  Narrowing
;; would also start refusing calls that work today.  See docs/limits.md.
(define (integer->char n)
  (if (and (integer? n) (exact? n)
           (>= n 0) (<= n #x10FFFF)
           (not (and (>= n #xD800) (<= n #xDFFF))))
      (%integer->char n)
      (error 'integer->char "not a Unicode scalar value" n)))

(define (char-upcase c)
  (let ((n (char->integer c)))
    ;; the guard on the next line gives n 97..122, so n-32 is 65..90
    (if (and (< 96 n) (< n 123)) (%integer->char (- n 32)) c)))
(define (char-downcase c)
  (let ((n (char->integer c)))
    ;; the guard on the next line gives n 65..90, so n+32 is 97..122
    (if (and (< 64 n) (< n 91)) (%integer->char (+ n 32)) c)))
(define (char-alphabetic? c)
  (let ((n (char->integer c)))
    (or (and (< 64 n) (< n 91)) (and (< 96 n) (< n 123)))))
(define (char-numeric? c)
  (let ((n (char->integer c)))
    (and (< 47 n) (< n 58))))
(define (char-whitespace? c)
  (memv (char->integer c) '(32 9 10 13 12)))

(define (string-upcase s) (string-map (lambda (c) (char-upcase c)) s))
(define (string-downcase s) (string-map (lambda (c) (char-downcase c)) s))
(define (string-map f s) (list->string (map f (string->list s))))
(define (string-for-each f s) (for-each f (string->list s)))

;; ---- exceptions: raise and guard over escape continuations ----
;;
;; A guard pushes its escape continuation on a handler stack; raise
;; pops the nearest one and escapes to it (running dynamic-wind after
;; thunks on the way).  An unmatched guard clause re-raises outward.

(define $handlers '())
(define $exn-mark (cons 0 0))

(define (raise obj)
  (if (null? $handlers)
      ($unhandled obj)
      (let ((k (car $handlers)))
        (set! $handlers (cdr $handlers))
        (k (cons $exn-mark obj)))))
(define (raise-continuable obj) (raise obj))

(define ($try thunk)
  ;; -> result, or ($exn-mark . obj) if something raised
  (call/cc
   (lambda (k)
     (set! $handlers (cons k $handlers))
     (let ((v (thunk)))
       (set! $handlers (cdr $handlers))
       v))))
(define ($guard-hit? r)
  (and (pair? r) (eq? (car r) $exn-mark)))

(define-syntax guard
  (syntax-rules ()
    ((_ (var clause ...) body ...)
     (let ((r ($try (lambda () body ...))))
       (if ($guard-hit? r)
           (let ((var (cdr r)))
             (cond clause ... (else (raise var))))
           r)))))

;; error conditions
(define-record-type ($error-object $make-error error?)
  (fields (immutable who condition-who)
          (immutable msg condition-message)
          (immutable irritants condition-irritants)))
(define (error who msg . irritants)
  (raise ($make-error who msg irritants)))
(define ($unhandled obj)
  (display "unhandled exception: ")
  (if (error? obj)
      (begin
        (display (condition-who obj)) (display ": ")
        (display (condition-message obj))
        (for-each (lambda (x) (display " ") (write x))
                  (condition-irritants obj)))
      (write obj))
  (newline)
  (%abort))

;; ---- full bignum division (shift-subtract, bit at a time) ----

(define ($mag-shl1! v)                  ; v <<= 1 in place, returns carry-out
  (let loop ((i 0) (carry 0))
    (if (= i (vector-length v))
        carry
        (let ((t (+ (* (vector-ref v i) 2) carry)))
          (vector-set! v i (remainder t 16384))
          (loop (+ i 1) (quotient t 16384))))))
(define ($mag-copy v n)
  (let ((r (make-vector n 0)))
    (let loop ((i 0))
      (when (and (< i n) (< i (vector-length v)))
        (vector-set! r i (vector-ref v i))
        (loop (+ i 1))))
    r))
(define $powers2 (vector 1 2 4 8 16 32 64 128 256 512 1024 2048 4096 8192))
(define ($mag-bit v p)                  ; bit p, lsb-indexed
  (remainder (quotient (vector-ref v (quotient p 14))
                       (vector-ref $powers2 (remainder p 14)))
             2))
(define ($mag-divmod a b)               ; -> (quotient-vec . remainder-vec)
  (let* ((la ($mag-len a))
         (bits (* la 14))
         (q (make-vector la 0))
         (r (make-vector (+ ($mag-len b) 1) 0)))
    (let loop ((p (- bits 1)))
      (if (< p 0)
          (cons q r)
          (begin
            ($mag-shl1! r)
            (when (= 1 ($mag-bit a p))
              (vector-set! r 0 (+ (vector-ref r 0) 1)))
            (when (< -1 ($mag-cmp r b))
              (let ((d ($mag-sub r b)))
                (let copy ((j 0))
                  (when (< j (vector-length r))
                    (vector-set! r j (if (< j (vector-length d))
                                         (vector-ref d j)
                                         0))
                    (copy (+ j 1)))))
              (vector-set! q (quotient p 14)
                           (+ (vector-ref q (quotient p 14))
                              (vector-ref $powers2 (remainder p 14)))))
            (loop (- p 1)))))))

;; ---- rationals ----

(define (gcd a b)
  (let loop ((a (abs a)) (b (abs b)))
    (if ($eq2 b 0) a (loop b (remainder a b)))))
(define (lcm a b)
  (if (or ($eq2 a 0) ($eq2 b 0))
      0
      (abs (* (quotient a (gcd a b)) b))))

(define ($make-rat n d)
  (when ($eq2 d 0) (errorf '/ "division by zero"))
  (let* ((neg (if (< d 0) (not (< n 0)) (< n 0)))
         (n (abs n))
         (d (abs d))
         (g (gcd n d))
         (n (quotient n g))
         (d (quotient d g))
         (n (if neg (- 0 n) n)))
    (if ($eq2 d 1) n (%make-ratio n d))))
(define (numerator x) (if (%ratio? x) (%ratio-num x) x))
(define (denominator x) (if (%ratio? x) (%ratio-den x) 1))
;; Fixing integer? does not fix this one: the flonum? arm answered
;; #t for an infinity on its own.  A rational is a ratio of integers,
;; and an infinity is not one.
(define (rational? x)
  (or (integer? x) (%ratio? x) (and (flonum? x) ($fl-finite? x))))
(define (real? x) (and (number? x) (not (%complex? x))))
(define (complex? x) (number? x))

;; ---- complex numbers ----

(define ($cx re im)                     ; collapse an exact zero imaginary
  (cond
   ((and (exact? im) ($eq2 im 0)) re)
   ;; inexactness is contagious across the parts (r6rs), so mixed
   ;; literals read the same as under a host reader: 1.0+2i = 1.0+2.0i
   ((and (flonum? re) (not (flonum? im))) (%make-complex re ($->fl im)))
   ((and (flonum? im) (not (flonum? re))) (%make-complex ($->fl re) im))
   (else (%make-complex re im))))
(define (make-rectangular re im) ($cx re im))
(define (real-part x) (if (%complex? x) (%cx-re x) x))
(define (imag-part x) (if (%complex? x) (%cx-im x) 0))
(define (magnitude x)
  (let ((re (real-part x)) (im (imag-part x)))
    (flsqrt ($->fl (+ (* re re) (* im im))))))

;; ---- file ports ----
;;
;; The host accumulates a path pushed byte by byte, then opens it;
;; reads and writes move single bytes through the fd imports.

(define ($send-path s)
  (string-for-each (lambda (c) (%path-byte (char->integer c))) s))
(define (open-input-file path)
  ($send-path path)
  (let ((fd (%open-read)))
    (when (< fd 0) (errorf 'open-input-file "cannot open" path))
    ($make-port 'file-in fd -2 1 0)))
(define (open-output-file path)
  ($send-path path)
  (let ((fd (%open-write)))
    (when (< fd 0) (errorf 'open-output-file "cannot open" path))
    ($make-port 'file-out fd 0 1 0)))
(define (close-port p)
  (let ((k ($port-kind p)))
    (when (memq k '(file-in file-out))
      (%fclose ($port-a p)))))
(define (close-input-port p) (close-port p))
(define (close-output-port p) (close-port p))
(define (file-exists? path)
  ($send-path path)
  (let ((fd (%open-read)))
    (if (< fd 0)
        #f
        (begin (%fclose fd) #t))))
(define (call-with-input-file path proc)
  (let* ((p (open-input-file path))
         (r (proc p)))
    (close-port p)
    r))
(define (call-with-output-file path proc)
  (let* ((p (open-output-file path))
         (r (proc p)))
    (close-port p)
    r))
(define (with-input-from-file path thunk)
  (let ((p (open-input-file path)))
    (let ((r ($with-in p thunk)))
      (close-port p)
      r)))
(define (with-output-to-file path thunk)
  (let ((p (open-output-file path)))
    (let ((r ($with-out p thunk)))
      (close-port p)
      r)))

;; ---- R6RS names written over what the prelude already has ----
;;
;; Each group below adds standard names that need nothing new from the
;; compiler or the runtime: every one is a composition of procedures
;; defined above or of primitives.  Each name is also listed in the
;; compiler's (rnrs) manifest, which is what makes it importable and
;; excludable; a definition here without that line would be in scope
;; everywhere and could not be excluded.  Domains narrower than R6RS's
;; are stated in docs/limits.md ("Prelude gaps" and the sections it
;; points to), and arguments are checked only where a sibling already
;; checks them.

;; ---- numbers ----

(define (positive? x) (< 0 x))
(define (negative? x) (< x 0))

;; An inexact integer is even or odd too: (even? 4.0) is #t.  A flonum
;; that is not a finite integer is neither, which is where R6RS raises.
(define (even? n)
  (if (flonum? n)
      (and ($fl-finite? n) (fl=? (flfloor (fl/ n 2.0)) (fl/ n 2.0)))
      (eqv? 0 (remainder n 2))))
(define (odd? n)
  (if (flonum? n)
      (and ($fl-finite? n)
           (fl=? (fl- n (fl* 2.0 (flfloor (fl/ n 2.0)))) 1.0))
      (not (eqv? 0 (remainder n 2)))))

;; ceiling mirrors floor clause for clause.  A flonum is negated by
;; multiplying by -1.0, which is exact and keeps the sign of a zero:
;; (ceiling -0.5) is -0.0, as R6RS and Chez answer.  A ratio is never
;; integral here ($make-rat collapses d = 1), so its ceiling is always
;; its floor plus one.
(define (ceiling x)
  (cond
   ((flonum? x) (fl* -1.0 (flfloor (fl* -1.0 x))))
   ((%ratio? x) (+ (floor x) 1))
   (else x)))

;; round goes to the nearest integer and, on a tie, to the even one.
;; For a flonum the fraction x - floor(x) is computed exactly (it is
;; representable whenever x is finite), so the tie test is exact too;
;; a negative argument is rounded as its magnitude and negated back,
;; which keeps (round -0.4) at -0.0.  An infinity or a NaN is its own
;; rounding.
(define (round x)
  (cond
   ((flonum? x)
    (cond
     ((not ($fl-finite? x)) x)
     ((fl<? x 0.0) (fl* -1.0 ($round-magnitude (fl* -1.0 x))))
     (else ($round-magnitude x))))
   ((%ratio? x)
    (let* ((f (floor x)) (twice (* 2 (- x f))))
      (cond
       ((< twice 1) f)
       ((< 1 twice) (+ f 1))
       ((even? f) f)
       (else (+ f 1)))))
   (else x)))
(define ($round-magnitude x)
  (let* ((f (flfloor x)) (d (fl- x f)))
    (cond
     ((fl<? d 0.5) f)
     ((fl<? 0.5 d) (fl+ f 1.0))
     ((even? f) f)
     (else (fl+ f 1.0)))))

;; Only a flonum can be infinite or a NaN; every exact real is finite.
(define (finite? x) (if (flonum? x) ($fl-finite? x) #t))
(define (infinite? x)
  (and (flonum? x) (fl=? x x) (not ($fl-finite? x))))
(define (nan? x) (and (flonum? x) (not (fl=? x x))))

;; The -valued? predicates read a complex number whose imaginary part
;; is zero as its real part: (real-valued? 2.5+0.0i) is #t where
;; (real? 2.5+0.0i) is #f.  Anything that is not a number answers #f.
(define (real-valued? x)
  (or (real? x) (and (%complex? x) (zero? (%cx-im x)))))
(define ($valued-part x) (if (%complex? x) (%cx-re x) x))
(define (rational-valued? x)
  (and (real-valued? x) (rational? ($valued-part x))))
(define (integer-valued? x)
  (and (real-valued? x) (integer? ($valued-part x))))

;; The largest s with s*s <= k, and k - s*s.  The start doubles up to a
;; power of two whose square exceeds k, so it is above the root, and
;; integer Newton steps then fall monotonically to it; fixnums and
;; bignums take the same path.  Zero is answered first: its steps would
;; reach x = 0 and divide by it.
(define (exact-integer-sqrt k)
  (if (eqv? k 0)
      (values 0 0)
      (let up ((x 1))
        (if (<= (* x x) k)
            (up (* x 2))
            (let down ((x x))
              (let ((y (quotient (+ x (quotient k x)) 2)))
                (if (< y x)
                    (down y)
                    (values x (- k (* x x))))))))))

(define (div-and-mod n d)
  ($div-check 'div-and-mod n d)
  (values ($div n d) ($mod n d)))
;; the same corrections as div0 and mod0, made once for both answers
(define (div0-and-mod0 n d)
  ($div-check 'div0-and-mod0 n d)
  (let ((q ($div n d)) (r ($mod n d)))
    (if (< (+ r r) (abs d))
        (values q r)
        (values (if (< d 0) (- q 1) (+ q 1)) (- r (abs d))))))

;; Two or more arguments, compared neighbour to neighbour.
(define ($chain same? a b rest)
  (and (same? a b)
       (or (null? rest) ($chain same? b (car rest) (cdr rest)))))
(define (boolean=? a b . rest) ($chain eq? a b rest))
(define (symbol=? a b . rest) ($chain eq? a b rest))

;; A fixnum is 30 bits on both back ends: compile-datum's fits-fixnum?
;; and the runtime's fixnum? agree on -2^29 .. 2^29-1.
(define (greatest-fixnum) 536870911)
(define (least-fixnum) -536870912)
(define (fixnum-width) 30)

;; ---- lists ----

;; exists and for-all make their last call to pred in tail position and
;; answer its value, as R6RS asks.  Over several lists they stop at the
;; end of the shortest.
(define (exists pred ls . more)
  (if (null? more) ($exists1 pred ls) ($existsn pred (cons ls more))))
(define ($exists1 pred ls)
  (cond
   ((null? ls) #f)
   ((null? (cdr ls)) (pred (car ls)))
   (else (or (pred (car ls)) ($exists1 pred (cdr ls))))))
(define ($existsn pred lists)
  (cond
   (($any-null? lists) #f)
   (($any-null? ($tails lists)) (apply pred ($heads lists)))
   (else (or (apply pred ($heads lists)) ($existsn pred ($tails lists))))))
(define (for-all pred ls . more)
  (if (null? more) ($for-all1 pred ls) ($for-alln pred (cons ls more))))
(define ($for-all1 pred ls)
  (cond
   ((null? ls) #t)
   ((null? (cdr ls)) (pred (car ls)))
   (else (and (pred (car ls)) ($for-all1 pred (cdr ls))))))
(define ($for-alln pred lists)
  (cond
   (($any-null? lists) #t)
   (($any-null? ($tails lists)) (apply pred ($heads lists)))
   (else (and (apply pred ($heads lists)) ($for-alln pred ($tails lists))))))

(define (find pred ls)
  (cond
   ((null? ls) #f)
   ((pred (car ls)) (car ls))
   (else (find pred (cdr ls)))))
(define (memp pred ls)
  (cond
   ((null? ls) #f)
   ((pred (car ls)) ls)
   (else (memp pred (cdr ls)))))
(define (assp pred ls)
  (cond
   ((null? ls) #f)
   ((pred (caar ls)) (car ls))
   (else (assp pred (cdr ls)))))
(define (remp pred ls) (filter (lambda (x) (not (pred x))) ls))
(define (remove x ls) (remp (lambda (y) (equal? y x)) ls))
(define (remv x ls) (remp (lambda (y) (eqv? y x)) ls))
;; both lists keep the order the elements had
(define (partition pred ls)
  (let loop ((ls ls) (in '()) (out '()))
    (cond
     ((null? ls) (values (reverse in) (reverse out)))
     ((pred (car ls)) (loop (cdr ls) (cons (car ls) in) out))
     (else (loop (cdr ls) in (cons (car ls) out))))))

;; A merge sort, stable as R6RS requires: on a tie the merge takes the
;; element from the left run, which came first.  The merge accumulates
;; and reverses, so a long list does not deepen the stack; the split
;; recursion is only log n deep.
(define (list-sort less? ls) ($sort-prefix less? ls (length ls)))
(define ($sort-prefix less? ls n)
  (cond
   ((= n 0) '())
   ((= n 1) (list (car ls)))
   (else
    (let ((h (quotient n 2)))
      ($merge-runs less?
                   ($sort-prefix less? ls h)
                   ($sort-prefix less? (list-tail ls h) (- n h)))))))
(define ($merge-runs less? a b)
  (let loop ((a a) (b b) (acc '()))
    (cond
     ((null? a) ($rev-onto acc b))
     ((null? b) ($rev-onto acc a))
     ((less? (car b) (car a)) (loop a (cdr b) (cons (car b) acc)))
     (else (loop (cdr a) b (cons (car a) acc))))))

;; the three- and four-level accessors the prelude did not have yet
(define (caaar p) (car (caar p)))
(define (cdaar p) (cdr (caar p)))
(define (cddar p) (cdr (cdar p)))
(define (caaaar p) (car (caaar p)))
(define (caaadr p) (car (caadr p)))
(define (caadar p) (car (cadar p)))
(define (caaddr p) (car (caddr p)))
(define (cadaar p) (car (cdaar p)))
(define (cadadr p) (car (cdadr p)))
(define (caddar p) (car (cddar p)))
(define (cdaaar p) (cdr (caaar p)))
(define (cdaadr p) (cdr (caadr p)))
(define (cdadar p) (cdr (cadar p)))
(define (cdaddr p) (cdr (caddr p)))
(define (cddaar p) (cdr (cdaar p)))
(define (cddadr p) (cdr (cdadr p)))
(define (cdddar p) (cdr (cddar p)))
(define (cddddr p) (cdr (cdddr p)))

;; ---- characters and strings, ignoring case ----

;; Folding is char-downcase, so it covers the range char-downcase
;; covers: A to Z.  Every other character folds to itself, which is
;; narrower than R6RS (docs/limits.md, "Prelude gaps").
(define (char-foldcase c) (char-downcase c))
(define (char-upper-case? c)
  (let ((n (char->integer c))) (and (< 64 n) (< n 91))))
(define (char-lower-case? c)
  (let ((n (char->integer c))) (and (< 96 n) (< n 123))))
(define (string-foldcase s) (string-map char-foldcase s))

(define (char-ci=? a b . rest)
  ($chain char=? (char-foldcase a) (char-foldcase b) (map char-foldcase rest)))
(define (char-ci<? a b . rest)
  ($chain char<? (char-foldcase a) (char-foldcase b) (map char-foldcase rest)))
(define (char-ci>? a b . rest)
  ($chain char>? (char-foldcase a) (char-foldcase b) (map char-foldcase rest)))
(define (char-ci<=? a b . rest)
  ($chain char<=? (char-foldcase a) (char-foldcase b) (map char-foldcase rest)))
(define (char-ci>=? a b . rest)
  ($chain char>=? (char-foldcase a) (char-foldcase b) (map char-foldcase rest)))
(define (string-ci=? a b . rest)
  ($chain string=? (string-foldcase a) (string-foldcase b)
          (map string-foldcase rest)))
(define (string-ci<? a b . rest)
  ($chain string<? (string-foldcase a) (string-foldcase b)
          (map string-foldcase rest)))
(define (string-ci>? a b . rest)
  ($chain string>? (string-foldcase a) (string-foldcase b)
          (map string-foldcase rest)))
(define (string-ci<=? a b . rest)
  ($chain string<=? (string-foldcase a) (string-foldcase b)
          (map string-foldcase rest)))
(define (string-ci>=? a b . rest)
  ($chain string>=? (string-foldcase a) (string-foldcase b)
          (map string-foldcase rest)))

;; ---- vectors ----

;; vector-sort is list-sort's merge, so it is stable; vector-sort!
;; writes the same order back in place.
(define (vector-sort less? v)
  (list->vector (list-sort less? (vector->list v))))
(define (vector-sort! less? v)
  ($vfill! v (list-sort less? (vector->list v)) 0))

;; ---- bytevectors ----

(define (bytevector-copy bv)
  (let* ((n (bytevector-length bv)) (r (%make-bytevector n 0)))
    (bytevector-copy! bv 0 r 0 n)
    r))
;; The source and the target may be one bytevector with overlapping
;; ranges; copying from the high end when the target starts later keeps
;; every byte read before it is overwritten.
(define (bytevector-copy! src s dst d k)
  (if (and (eq? src dst) (< s d))
      (let loop ((i (- k 1)))
        (when (<= 0 i)
          (bytevector-u8-set! dst (+ d i) (bytevector-u8-ref src (+ s i)))
          (loop (- i 1))))
      (let loop ((i 0))
        (when (< i k)
          (bytevector-u8-set! dst (+ d i) (bytevector-u8-ref src (+ s i)))
          (loop (+ i 1))))))
;; R6RS takes an octet or a signed byte; a negative fill is stored as
;; the byte with the same bits.
(define (bytevector-fill! bv fill)
  (let ((b (if (< fill 0) (+ fill 256) fill)))
    (let loop ((i 0))
      (when (< i (bytevector-length bv))
        (bytevector-u8-set! bv i b)
        (loop (+ i 1))))))
(define (bytevector->u8-list bv)
  (let loop ((i (- (bytevector-length bv) 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))
(define (u8-list->bytevector ls)
  (let ((bv (%make-bytevector (length ls) 0)))
    ($bvfill! bv ls 0)
    bv))

(define (bytevector-s8-ref bv k)
  (let ((b (bytevector-u8-ref bv k))) (if (< b 128) b (- b 256))))
(define (bytevector-s8-set! bv k n)
  (bytevector-u8-set! bv k (if (< n 0) (+ n 256) n)))

;; (endianness big) and (endianness little) are the symbols; any other
;; name is refused when the form is expanded.
(define-syntax endianness
  (syntax-rules (big little)
    ((_ big) 'big)
    ((_ little) 'little)))
;; wasm memory and every JS host this runs on are little-endian
(define (native-endianness) 'little)

;; The integer accessors of every size are these four, each told the
;; name of the procedure the program called so that a refusal names it.
;; An endianness other than big or little is refused.  A value is
;; assembled with generic arithmetic, so a 32- or 64-bit answer past the
;; fixnum range comes back as a bignum.  A value to store is reduced to
;; its low 8*size bits without a check, as bytevector-u8-set! reduces a
;; byte.  The list conversions refuse a bytevector whose length is not a
;; multiple of the size.
(define ($byte-span size)
  (let loop ((i 0) (p 1)) (if (= i size) p (loop (+ i 1) (* p 256)))))
(define ($endianness who e)
  (unless (or (eq? e 'big) (eq? e 'little))
    (error who "unrecognized endianness" e)))
(define (bytevector-uint-ref bv k e size)
  ($uint-ref 'bytevector-uint-ref bv k e size))
(define (bytevector-sint-ref bv k e size)
  ($sint-ref 'bytevector-sint-ref bv k e size))
(define (bytevector-uint-set! bv k n e size)
  ($uint-set! 'bytevector-uint-set! bv k n e size))
(define (bytevector-sint-set! bv k n e size)
  ($sint-set! 'bytevector-sint-set! bv k n e size))
(define ($uint-ref who bv k e size)
  ($endianness who e)
  (if (eq? e 'big)
      (let loop ((i 0) (acc 0))
        (if (= i size)
            acc
            (loop (+ i 1) (+ (* acc 256) (bytevector-u8-ref bv (+ k i))))))
      (let loop ((i (- size 1)) (acc 0))
        (if (< i 0)
            acc
            (loop (- i 1) (+ (* acc 256) (bytevector-u8-ref bv (+ k i))))))))
(define ($sint-ref who bv k e size)
  (let ((u ($uint-ref who bv k e size))
        (top (bytevector-u8-ref bv (if (eq? e 'big) k (+ k (- size 1))))))
    (if (< top 128) u (- u ($byte-span size)))))
(define ($uint-set! who bv k n e size)
  ($endianness who e)
  (let loop ((i 0) (v n))
    (when (< i size)
      (bytevector-u8-set! bv
                          (if (eq? e 'big) (+ k (- size 1 i)) (+ k i))
                          (mod v 256))
      (loop (+ i 1) (div v 256)))))
(define ($sint-set! who bv k n e size)
  ($uint-set! who bv k (if (< n 0) (+ n ($byte-span size)) n) e size))

(define (bytevector-u16-ref bv k e)
  ($uint-ref 'bytevector-u16-ref bv k e 2))
(define (bytevector-s16-ref bv k e)
  ($sint-ref 'bytevector-s16-ref bv k e 2))
(define (bytevector-u32-ref bv k e)
  ($uint-ref 'bytevector-u32-ref bv k e 4))
(define (bytevector-s32-ref bv k e)
  ($sint-ref 'bytevector-s32-ref bv k e 4))
(define (bytevector-u64-ref bv k e)
  ($uint-ref 'bytevector-u64-ref bv k e 8))
(define (bytevector-s64-ref bv k e)
  ($sint-ref 'bytevector-s64-ref bv k e 8))
(define (bytevector-u16-set! bv k n e)
  ($uint-set! 'bytevector-u16-set! bv k n e 2))
(define (bytevector-s16-set! bv k n e)
  ($sint-set! 'bytevector-s16-set! bv k n e 2))
(define (bytevector-u32-set! bv k n e)
  ($uint-set! 'bytevector-u32-set! bv k n e 4))
(define (bytevector-s32-set! bv k n e)
  ($sint-set! 'bytevector-s32-set! bv k n e 4))
(define (bytevector-u64-set! bv k n e)
  ($uint-set! 'bytevector-u64-set! bv k n e 8))
(define (bytevector-s64-set! bv k n e)
  ($sint-set! 'bytevector-s64-set! bv k n e 8))
(define (bytevector-u16-native-ref bv k)
  (bytevector-uint-ref bv k (native-endianness) 2))
(define (bytevector-s16-native-ref bv k)
  (bytevector-sint-ref bv k (native-endianness) 2))
(define (bytevector-u32-native-ref bv k)
  (bytevector-uint-ref bv k (native-endianness) 4))
(define (bytevector-s32-native-ref bv k)
  (bytevector-sint-ref bv k (native-endianness) 4))
(define (bytevector-u64-native-ref bv k)
  (bytevector-uint-ref bv k (native-endianness) 8))
(define (bytevector-s64-native-ref bv k)
  (bytevector-sint-ref bv k (native-endianness) 8))
(define (bytevector-u16-native-set! bv k n)
  (bytevector-uint-set! bv k n (native-endianness) 2))
(define (bytevector-s16-native-set! bv k n)
  (bytevector-sint-set! bv k n (native-endianness) 2))
(define (bytevector-u32-native-set! bv k n)
  (bytevector-uint-set! bv k n (native-endianness) 4))
(define (bytevector-s32-native-set! bv k n)
  (bytevector-sint-set! bv k n (native-endianness) 4))
(define (bytevector-u64-native-set! bv k n)
  (bytevector-uint-set! bv k n (native-endianness) 8))
(define (bytevector-s64-native-set! bv k n)
  (bytevector-sint-set! bv k n (native-endianness) 8))

(define ($whole-elements who bv size)
  (unless (= 0 (remainder (bytevector-length bv) size))
    (error who "bytevector length is not a multiple of size"
           (bytevector-length bv) size)))
(define (bytevector->uint-list bv e size)
  ($endianness 'bytevector->uint-list e)
  ($whole-elements 'bytevector->uint-list bv size)
  (let loop ((k (- (bytevector-length bv) size)) (acc '()))
    (if (< k 0)
        acc
        (loop (- k size)
              (cons ($uint-ref 'bytevector->uint-list bv k e size) acc)))))
(define (bytevector->sint-list bv e size)
  ($endianness 'bytevector->sint-list e)
  ($whole-elements 'bytevector->sint-list bv size)
  (let loop ((k (- (bytevector-length bv) size)) (acc '()))
    (if (< k 0)
        acc
        (loop (- k size)
              (cons ($sint-ref 'bytevector->sint-list bv k e size) acc)))))
(define (uint-list->bytevector ls e size)
  ($endianness 'uint-list->bytevector e)
  (let ((bv (%make-bytevector (* size (length ls)) 0)))
    (let loop ((ls ls) (k 0))
      (unless (null? ls)
        ($uint-set! 'uint-list->bytevector bv k (car ls) e size)
        (loop (cdr ls) (+ k size))))
    bv))
(define (sint-list->bytevector ls e size)
  ($endianness 'sint-list->bytevector e)
  (let ((bv (%make-bytevector (* size (length ls)) 0)))
    (let loop ((ls ls) (k 0))
      (unless (null? ls)
        ($sint-set! 'sint-list->bytevector bv k (car ls) e size)
        (loop (cdr ls) (+ k size))))
    bv))

;; ---- R6RS names, second batch: flonums, fixnums, bitwise, string ports
;;
;; Like the batch above: plain procedures over what exists, each listed
;; in the (rnrs) manifest.  The fl and fx procedures are ordinary calls
;; here, not the compiler's unboxed flonum or fixnum paths; they answer
;; what those would, only slower.

;; ---- flonums ----
;;
;; These take flonums.  Given another real, each does what the primitive
;; under it does with one (docs/limits.md); real->flonum takes any real.

(define ($fl<= x y) (if (fl<? x y) #t (fl=? x y)))
(define (fl>? a b . rest) ($chain (lambda (x y) (fl<? y x)) a b rest))
(define (fl<=? a b . rest) ($chain $fl<= a b rest))
(define (fl>=? a b . rest) ($chain (lambda (x y) ($fl<= y x)) a b rest))

;; -0.0 is not less than 0.0, so a negative zero is told apart by the
;; sign of its reciprocal; negating by multiplying keeps a NaN a NaN
(define (flabs x)
  (if (or (fl<? x 0.0) (and (fl=? x 0.0) (fl<? (fl/ 1.0 x) 0.0)))
      (fl* -1.0 x)
      x))
;; A NaN among the arguments is the answer; of two equal arguments
;; (a zero of either sign included) the later one is, as on Chez.
(define (flmax a . rest)
  (fold-left (lambda (m x)
               (cond ((not (fl=? m m)) m)
                     ((not (fl=? x x)) x)
                     ((fl<? x m) m)
                     (else x)))
             a rest))
(define (flmin a . rest)
  (fold-left (lambda (m x)
               (cond ((not (fl=? m m)) m)
                     ((not (fl=? x x)) x)
                     ((fl<? m x) m)
                     (else x)))
             a rest))

(define (flzero? x) (fl=? x 0.0))
(define (flpositive? x) (fl<? 0.0 x))
(define (flnegative? x) (fl<? x 0.0))
(define (flinteger? x) (and ($fl-finite? x) (fl=? x (flfloor x))))
(define (flfinite? x) ($fl-finite? x))
(define (flinfinite? x) (and (fl=? x x) (not ($fl-finite? x))))
(define (flnan? x) (not (fl=? x x)))
;; as even? and odd? read a flonum: neither, for one that is not a
;; finite integer
(define (fleven? x) (even? x))
(define (flodd? x) (odd? x))
(define (flceiling x) (ceiling x))
(define (flround x) (round x))

;; R6RS's division on reals: x = d * q + m with 0 <= m < |d| for div
;; and mod, -|d|/2 <= m < |d|/2 for div0 and mod0.  q is floor(x / d)
;; for a positive d and the negation of floor(x / -d) for a negative one.
(define ($fldiv x d)
  (if (fl<? d 0.0)
      (fl* -1.0 (flfloor (fl/ x (fl* -1.0 d))))
      (flfloor (fl/ x d))))
(define (fldiv x d) ($fldiv x d))
(define (flmod x d) (fl- x (fl* d ($fldiv x d))))
(define (fldiv-and-mod x d)
  (let ((q ($fldiv x d)))
    (values q (fl- x (fl* d q)))))
(define (fldiv0-and-mod0 x d)
  (let* ((q ($fldiv x d))
         (m (fl- x (fl* d q)))
         (ad (flabs d)))
    (if (fl<? (fl+ m m) ad)
        (values q m)
        (values (if (fl<? d 0.0) (fl- q 1.0) (fl+ q 1.0)) (fl- m ad)))))
(define (fldiv0 x d)
  (call-with-values (lambda () (fldiv0-and-mod0 x d)) (lambda (q m) q)))
(define (flmod0 x d)
  (call-with-values (lambda () (fldiv0-and-mod0 x d)) (lambda (q m) m)))

;; A zero is its own numerator (keeping its sign), and an infinity's
;; denominator is 1.0; a NaN answers itself for both.
(define (flnumerator x)
  (if (or (fl=? x 0.0) (not ($fl-finite? x)))
      x
      (inexact (numerator (exact x)))))
(define (fldenominator x)
  (cond ((not (fl=? x x)) x)
        ((not ($fl-finite? x)) 1.0)
        ((fl=? x 0.0) 1.0)
        (else (inexact (denominator (exact x))))))

;; The flonum layer of the trig above, as (gfx mat) has always exported
;; it.  (fl* x 1.0) is NOT redundant, however much it looks it.  The
;; compiler's f64 parameter specialization is whole-program: it keeps
;; $sin-fl's parameter unboxed only while EVERY call site in the
;; program provably passes a flonum.  A bare symbol can be such a proof
;; -- the pass accepts one that is itself a specialized parameter of
;; the enclosing function -- but these wrappers' own parameters do not
;; qualify, so forwarding x bare from here is not, and one wrapper like
;; that, merely linked in, costs every other caller.  Measured at 40M
;; calls (user time): 0.37 with the explicit expression, 0.45 without.
;;
;; What it buys is conditional on the whole program, not absolute: one
;; that ALSO uses the generic sin/cos/tan (whose argument passes
;; through $->fl) demotes the layer again and measures 0.46.  Not every
;; indirection costs it -- taking flsin itself as a first-class value
;; still measures 0.36 -- so the rule to carry away is the general one:
;; the layer stays fast only while EVERY call site in the program
;; provably passes a flonum.
;;
;; It must stay a MULTIPLICATION: (fl+ x 0.0) looks equally harmless
;; and collapses -0.0 to +0.0, changing (flsin -0.0) -- test/trig.ss
;; pins that with a run-time-built negative zero.
(define (flsin x) ($sin-fl (fl* x 1.0)))
(define (flcos x) ($cos-fl (fl* x 1.0)))
(define (fltan x) ($tan-fl (fl* x 1.0)))
(define (real->flonum x) (inexact x))

;; ---- fixnums ----
;;
;; A fixnum is 30 bits here (fixnum-width).  An fx operation computes
;; its exact result and refuses one outside the fixnum range, naming
;; itself and its arguments; it never answers a bignum and never wraps.

(define ($fx who r args)
  (if (fixnum? r) r (apply error who "result is not a fixnum" args)))

(define (fx+ a b) ($fx 'fx+ (+ a b) (list a b)))
(define (fx- a . b)
  (if (null? b)
      ($fx 'fx- (- 0 a) (list a))
      ($fx 'fx- (- a (car b)) (list a (car b)))))
(define (fx* a b) ($fx 'fx* (* a b) (list a b)))

(define (fx=? a b . rest) ($chain = a b rest))
(define (fx<? a b . rest) ($chain < a b rest))
(define (fx>? a b . rest) ($chain (lambda (x y) (< y x)) a b rest))
(define (fx<=? a b . rest) ($chain <= a b rest))
(define (fx>=? a b . rest) ($chain >= a b rest))
(define (fxzero? a) (eqv? a 0))
(define (fxpositive? a) (< 0 a))
(define (fxnegative? a) (< a 0))
(define (fxodd? a) (odd? a))
(define (fxeven? a) (even? a))
(define (fxmax a . rest) (apply max a rest))
(define (fxmin a . rest) (apply min a rest))

(define (fxdiv a b)
  ($div-check 'fxdiv a b)
  ($fx 'fxdiv ($div a b) (list a b)))
(define (fxmod a b)
  ($div-check 'fxmod a b)
  ($mod a b))
(define (fxdiv-and-mod a b)
  ($div-check 'fxdiv-and-mod a b)
  (values ($fx 'fxdiv-and-mod ($div a b) (list a b)) ($mod a b)))
(define (fxdiv0-and-mod0 a b)
  ($div-check 'fxdiv0-and-mod0 a b)
  (call-with-values (lambda () (div0-and-mod0 a b))
    (lambda (q r) (values ($fx 'fxdiv0-and-mod0 q (list a b)) r))))
(define (fxdiv0 a b)
  ($div-check 'fxdiv0 a b)
  (call-with-values (lambda () (div0-and-mod0 a b))
    (lambda (q r) ($fx 'fxdiv0 q (list a b)))))
(define (fxmod0 a b)
  ($div-check 'fxmod0 a b)
  (call-with-values (lambda () (div0-and-mod0 a b)) (lambda (q r) r)))

;; R6RS's carrying operations for width w = 30: the low part is the sum
;; (or difference, or product plus addend) modulo 2^30 centred on zero,
;; and the high part what is left over, divided by 2^30.  Both are
;; fixnums for every fixnum argument.
(define $fx-span 1073741824)
(define ($fx-carry s)
  (values (mod0 s $fx-span) (div0 s $fx-span)))
(define (fx+/carry a b c) ($fx-carry (+ a b c)))
(define (fx-/carry a b c) ($fx-carry (- a b c)))
(define (fx*/carry a b c) ($fx-carry (+ (* a b) c)))

(define (fxnot a) (- -1 a))
(define (fxand . xs) (fold-left (lambda (r x) (bitwise-and r x)) -1 xs))
(define (fxior . xs) (fold-left (lambda (r x) (bitwise-ior r x)) 0 xs))
(define (fxxor . xs) (fold-left (lambda (r x) (bitwise-xor r x)) 0 xs))
(define (fxif a b c) (bitwise-ior (bitwise-and a b) (bitwise-and (fxnot a) c)))
(define (fxbit-count a) (bitwise-bit-count a))
(define (fxlength a) (bitwise-length a))
(define (fxfirst-bit-set a) (bitwise-first-bit-set a))
(define (fxbit-set? a i) (bitwise-bit-set? a i))
(define (fxcopy-bit a i b)
  ($fx 'fxcopy-bit (bitwise-copy-bit a i b) (list a i b)))
(define (fxbit-field a s e) ($fx 'fxbit-field (bitwise-bit-field a s e) (list a s e)))
(define (fxcopy-bit-field a s e b)
  ($fx 'fxcopy-bit-field (bitwise-copy-bit-field a s e b) (list a s e b)))
(define (fxarithmetic-shift a k)
  ($fx 'fxarithmetic-shift (bitwise-arithmetic-shift a k) (list a k)))
(define (fxarithmetic-shift-left a k)
  ($fx 'fxarithmetic-shift-left (bitwise-arithmetic-shift a k) (list a k)))
(define (fxarithmetic-shift-right a k)
  ($fx 'fxarithmetic-shift-right (bitwise-arithmetic-shift a (- 0 k)) (list a k)))
(define (fxrotate-bit-field a s e c)
  ($fx 'fxrotate-bit-field (bitwise-rotate-bit-field a s e c) (list a s e c)))
(define (fxreverse-bit-field a s e)
  ($fx 'fxreverse-bit-field (bitwise-reverse-bit-field a s e) (list a s e)))

;; ---- bitwise operations on exact integers of any size ----
;;
;; bitwise-and, bitwise-ior and bitwise-xor are fixnum primitives; these
;; are written over generic exact arithmetic instead, so they take
;; bignums.  An integer is read as an infinite two's complement string:
;; floor division by 2^k is a right shift and mod 2^k the low k bits, for
;; negative integers as for positive ones.

(define (bitwise-not n) (- -1 n))
(define (bitwise-arithmetic-shift n k)
  (if (< k 0) (div n ($pow2 (- 0 k))) (* n ($pow2 k))))
;; the ones of a non-negative integer, and for a negative one the
;; complement of its complement's count, as R6RS defines it
(define (bitwise-bit-count n)
  (if (< n 0)
      (bitwise-not (bitwise-bit-count (bitwise-not n)))
      (let loop ((n n) (c 0))
        (if (eqv? n 0) c (loop (div n 2) (+ c (mod n 2)))))))
(define (bitwise-length n)
  (if (< n 0)
      (bitwise-length (bitwise-not n))
      (let loop ((n n) (c 0))
        (if (eqv? n 0) c (loop (div n 2) (+ c 1))))))
(define (bitwise-first-bit-set n)
  (if (eqv? n 0)
      -1
      (let loop ((n n) (i 0))
        (if (odd? n) i (loop (div n 2) (+ i 1))))))
(define (bitwise-bit-set? n i) (odd? (bitwise-arithmetic-shift n (- 0 i))))
(define (bitwise-copy-bit n i b)
  (let ((set? (bitwise-bit-set? n i)))
    (cond ((and set? (eqv? b 0)) (- n ($pow2 i)))
          ((and (not set?) (eqv? b 1)) (+ n ($pow2 i)))
          (else n))))
(define (bitwise-bit-field n s e)
  (mod (bitwise-arithmetic-shift n (- 0 s)) ($pow2 (- e s))))
;; bits s..e-1 of to replaced by the low e-s bits of from
(define (bitwise-copy-bit-field to s e from)
  (let ((p ($pow2 s)))
    (+ (- to (* (bitwise-bit-field to s e) p))
       (* (mod from ($pow2 (- e s))) p))))
(define (bitwise-rotate-bit-field n s e count)
  (let ((w (- e s)))
    (if (<= w 0)
        n
        (let* ((c (mod count w))
               (f (bitwise-bit-field n s e))
               (r (mod (+ (* f ($pow2 c)) (div f ($pow2 (- w c)))) ($pow2 w))))
          (bitwise-copy-bit-field n s e r)))))
(define (bitwise-reverse-bit-field n s e)
  (let loop ((f (bitwise-bit-field n s e)) (i s) (r 0))
    (if (< i e)
        (loop (div f 2) (+ i 1) (+ (* r 2) (mod f 2)))
        (bitwise-copy-bit-field n s e r))))
;; Bit by bit: where a has a one the bit comes from b, elsewhere from c.
;; Once all three are 0 or -1 every remaining bit is the same, so the
;; rest of the answer is that sign, placed above what has been built.
(define (bitwise-if a b c)
  (let loop ((a a) (b b) (c c) (p 1) (acc 0))
    (if (and (memv a '(0 -1)) (memv b '(0 -1)) (memv c '(0 -1)))
        (+ acc (* (if (eqv? a -1) b c) p))
        (loop (div a 2) (div b 2) (div c 2) (* p 2)
              (+ acc (* p (if (eqv? (mod a 2) 1) (mod b 2) (mod c 2))))))))

;; ---- string ports ----

;; The port and a procedure that answers what was written since the last
;; time it was called, and empties the port.
(define (open-string-output-port)
  (let ((p (open-output-string)))
    (values p
            (lambda ()
              (let ((s (get-output-string p)))
                ($port-a! p '())
                s)))))
(define (call-with-string-output-port proc)
  (let ((p (open-output-string)))
    (proc p)
    (get-output-string p)))
(define (open-string-input-port s) (open-input-string s))

;; ---- R6RS names, third batch: case-lambda, textual ports, hashtables
;;
;; As the two batches above: prelude definitions over what exists, each
;; listed in the (rnrs) manifest.

;; ---- case-lambda ----
;;
;; One variadic procedure that tries its clauses in order: the first
;; whose formals accept the number of arguments is applied to them, and
;; a call no clause accepts raises.  Each clause's procedure is made
;; once, when the case-lambda is evaluated; its formals are kept quoted
;; only to read their shape.
(define-syntax case-lambda
  (syntax-rules ()
    ((_ (formals body1 body2 ...) ...)
     ($case-lambda (list (cons 'formals (lambda formals body1 body2 ...))
                         ...)))))
(define ($case-lambda clauses)
  (lambda args ($case-lambda-apply clauses args (length args))))
(define ($case-lambda-apply clauses args n)
  (cond
   ((null? clauses)
    (error 'case-lambda "no clause accepts this number of arguments" n))
   (($formals-accept? (car (car clauses)) n)
    (apply (cdr (car clauses)) args))
   (else ($case-lambda-apply (cdr clauses) args n))))
(define ($formals-accept? f n)
  (cond ((pair? f) (and (< 0 n) ($formals-accept? (cdr f) (- n 1))))
        ((null? f) (= n 0))
        (else #t)))

;; ---- textual ports ----
;;
;; Every port here is textual, and reading takes one byte per character
;; (as read-char does), so these answer what read-char, peek-char and
;; write-char would.

(define (get-char p) (read-char p))
(define (lookahead-char p) (peek-char p))
(define (port-eof? p) (eof-object? (peek-char p)))
(define (textual-port? x) (port? x))
(define (binary-port? x) #f)

;; the characters up to the next newline, which is consumed and not
;; returned; the end of input with nothing read before it answers the
;; end-of-file object
(define (get-line p)
  (let ((c (read-char p)))
    (if (eof-object? c)
        c
        (let loop ((c c) (acc '()))
          (if (or (eof-object? c) (char=? c #\newline))
              (list->string (reverse acc))
              (loop (read-char p) (cons c acc)))))))
;; up to n characters; the end of input before any answers end-of-file
(define (get-string-n p n)
  (let loop ((i 0) (acc '()))
    (let ((c (if (< i n) (read-char p) #f)))
      (cond ((not c) (list->string (reverse acc)))
            ((eof-object? c)
             (if (null? acc) c (list->string (reverse acc))))
            (else (loop (+ i 1) (cons c acc)))))))
;; up to count characters into s from start; the number read, or
;; end-of-file when the input ended before any
(define (get-string-n! p s start count)
  (let loop ((i 0))
    (let ((c (if (< i count) (read-char p) #f)))
      (cond ((not c) i)
            ((eof-object? c) (if (= i 0) c i))
            (else (string-set! s (+ start i) c) (loop (+ i 1)))))))
(define (get-string-all p)
  (let loop ((acc '()))
    (let ((c (read-char p)))
      (if (eof-object? c)
          (if (null? acc) c (list->string (reverse acc)))
          (loop (cons c acc))))))
(define (get-datum p) (read p))

(define (put-char p c) (write-char c p))
;; the whole string, or from start to its end, or count characters
(define (put-string p s . range)
  (let* ((start (if (pair? range) (car range) 0))
         (end (if (and (pair? range) (pair? (cdr range)))
                  (+ start (cadr range))
                  (string-length s))))
    (let loop ((i start))
      (when (< i end)
        (write-char (string-ref s i) p)
        (loop (+ i 1))))))
(define (put-datum p x) (write x p))
;; A string port holds what was written until it is read; the console
;; hands each byte to the host as it is written; a file port writes each
;; byte through.  So there is nothing to flush.
(define (flush-output-port p) (void))

;; proc's values, after the port is closed
(define (call-with-port p proc)
  (call-with-values (lambda () (proc p))
    (lambda vals (close-port p) (apply values vals))))

;; ---- hashtables ----

;; A copy with the same hash and equivalence and the same entries,
;; immutable unless the second argument is true.
(define (hashtable-copy ht . mutable)
  (let ((c ($make-ht ($ht-hash ht) ($ht-equiv ht) 0
                     (make-vector (vector-length ($ht-buckets ht)) '())
                     #t)))
    ($ht-fold ht (lambda (k v acc) ($ht-set! c k v) acc) #f)
    (if (and (pair? mutable) (car mutable))
        c
        ($make-ht ($ht-hash c) ($ht-equiv c) ($ht-size c) ($ht-buckets c)
                  #f))))
(define (hashtable-mutable? ht) ($ht-mutable? ht))
;; a size hint is accepted and does not change the result
(define (hashtable-clear! ht . k)
  ($ht-writable! 'hashtable-clear! ht)
  ($ht-buckets-set! ht (make-vector 8 '()))
  ($ht-size-set! ht 0))
;; the keys and the values, as two vectors in the same order
(define (hashtable-entries ht)
  (let ((pairs ($ht-fold ht (lambda (k v acc) (cons (cons k v) acc)) '())))
    (values (list->vector (map car pairs))
            (list->vector (map cdr pairs)))))
(define (hashtable-equivalence-function ht) ($ht-equiv ht))
;; #f for an eq or eqv table, whose hash is the implementation's own
(define (hashtable-hash-function ht)
  (if (eq? ($ht-hash ht) $eqv-hash) #f ($ht-hash ht)))
(define (symbol-hash s) (string-hash (symbol->string s)))
(define (string-ci-hash s) (string-hash (string-foldcase s)))

;; ---- R6RS names, fourth batch: enumerations and rationalize ----

;; ---- enumerations ----
;;
;; Each make-enumeration makes a new TYPE: its symbols, in order, with
;; duplicates dropped.  Two calls over the same symbols are two types,
;; told apart by identity, and the operations that need one type refuse
;; sets of two.  A set is its type and the sorted indices of its members.
(define-record-type ($enum-type $make-enum-type $enum-type?)
  (fields (immutable symbols $enum-symbols)))
(define-record-type ($enum-set $make-enum-set $enum-set?)
  (fields (immutable type $enum-set-type)
          (immutable indices $enum-set-indices)))

(define ($enum-index type sym)
  (let loop ((ss ($enum-symbols type)) (i 0))
    (cond ((null? ss) #f)
          ((eq? (car ss) sym) i)
          (else (loop (cdr ss) (+ i 1))))))
(define ($enum-all type)
  (let loop ((i (- (length ($enum-symbols type)) 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons i acc)))))
;; the sorted, duplicate-free index list of a list of indices
(define ($enum-sort is)
  (let loop ((is (list-sort < is)) (acc '()))
    (cond ((null? is) (reverse acc))
          ((and (pair? acc) (= (car acc) (car is))) (loop (cdr is) acc))
          (else (loop (cdr is) (cons (car is) acc))))))

(define (make-enumeration syms)
  (let loop ((ss syms) (acc '()))
    (if (null? ss)
        (let ((type ($make-enum-type (reverse acc))))
          ($make-enum-set type ($enum-all type)))
        (loop (cdr ss) (if (memq (car ss) acc) acc (cons (car ss) acc))))))
(define (enum-set-universe s)
  (let ((type ($enum-set-type s))) ($make-enum-set type ($enum-all type))))
(define (enum-set-indexer s)
  (let ((type ($enum-set-type s)))
    (lambda (sym) ($enum-index type sym))))
(define (enum-set-constructor s)
  (let ((type ($enum-set-type s)))
    (lambda (syms)
      ($make-enum-set
       type
       ($enum-sort
        (map (lambda (sym)
               (or ($enum-index type sym)
                   (error 'enum-set-constructor
                          "not a symbol of the enumeration" sym)))
             syms))))))
(define (enum-set->list s)
  (let ((syms ($enum-symbols ($enum-set-type s))))
    (map (lambda (i) (list-ref syms i)) ($enum-set-indices s))))
(define (enum-set-member? sym s)
  (let ((i ($enum-index ($enum-set-type s) sym)))
    (and i (memv i ($enum-set-indices s)) #t)))
;; R6RS compares two sets by their symbols, across types: s1's universe
;; within s2's and s1's members within s2's
(define (enum-set-subset? s1 s2)
  (and (for-all (lambda (sym) ($enum-index ($enum-set-type s2) sym))
                ($enum-symbols ($enum-set-type s1)))
       (for-all (lambda (sym) (enum-set-member? sym s2))
                (enum-set->list s1))))
(define (enum-set=? s1 s2)
  (and (enum-set-subset? s1 s2) (enum-set-subset? s2 s1)))
(define ($enum-same-type who s1 s2)
  (unless (eq? ($enum-set-type s1) ($enum-set-type s2))
    (error who "the enum-sets are not of the same enumeration type" s1 s2))
  ($enum-set-type s1))
(define (enum-set-union s1 s2)
  (let ((type ($enum-same-type 'enum-set-union s1 s2)))
    ($make-enum-set type ($enum-sort (append ($enum-set-indices s1)
                                             ($enum-set-indices s2))))))
(define (enum-set-intersection s1 s2)
  (let ((type ($enum-same-type 'enum-set-intersection s1 s2)))
    ($make-enum-set type (filter (lambda (i) (memv i ($enum-set-indices s2)))
                                 ($enum-set-indices s1)))))
(define (enum-set-difference s1 s2)
  (let ((type ($enum-same-type 'enum-set-difference s1 s2)))
    ($make-enum-set type (remp (lambda (i) (memv i ($enum-set-indices s2)))
                               ($enum-set-indices s1)))))
(define (enum-set-complement s)
  (let ((type ($enum-set-type s)))
    ($make-enum-set type (remp (lambda (i) (memv i ($enum-set-indices s)))
                               ($enum-all type)))))
;; s1's members that s2's universe has, as a set of s2's type
(define (enum-set-projection s1 s2)
  (let ((type ($enum-set-type s2)))
    ($make-enum-set
     type
     ($enum-sort (filter (lambda (i) i)
                         (map (lambda (sym) ($enum-index type sym))
                              (enum-set->list s1)))))))

;; (define-enumeration type-name (symbol ...) constructor-syntax)
;;
;; type-name is a macro with one clause per symbol, so (type-name x) for
;; an x outside the set matches no clause and is refused when it is
;; expanded.  constructor-syntax takes its symbols through type-name, so
;; it refuses the same way, and builds the set with the constructor of
;; one enumeration made once, at the definition.
(define-syntax define-enumeration
  (syntax-rules ()
    ((_ type-name (sym ...) constructor-syntax)
     (begin
       (define universe (make-enumeration '(sym ...)))
       (define-syntax type-name
         (syntax-rules (sym ...)
           ((_ sym) 'sym) ...))
       (define-syntax constructor-syntax
         (syntax-rules ()
           ((_ s (... ...))
            ((enum-set-constructor universe)
             (list (type-name s) (... ...))))))))))

;; ---- rationalize ----
;;
;; The simplest rational within y of x: of the rationals in the closed
;; interval, the one with the smallest denominator, then numerator.
;; Exact when both arguments are exact; when either is inexact the
;; search runs on exact values and the answer is made inexact.  An
;; infinite tolerance answers 0.0 for a finite x; an infinite x is its
;; own answer; a NaN anywhere, or both infinite, is a NaN.
(define (rationalize x y)
  (if (or (inexact? x) (inexact? y))
      (let ((fx (inexact x)) (fy (inexact y)))
        (cond ((or (not (fl=? fx fx)) (not (fl=? fy fy))) +nan.0)
              ((not ($fl-finite? fy)) (if ($fl-finite? fx) 0.0 +nan.0))
              ((not ($fl-finite? fx)) fx)
              (else (inexact ($rationalize (exact fx) (exact fy))))))
      ($rationalize x y)))
(define ($rationalize x y)
  (let ((y (abs y)))
    ($simplest-between (- x y) (+ x y))))
(define ($simplest-between lo hi)
  (cond ((= lo hi) lo)
        ((< 0 lo) ($simplest-positive lo hi))
        ((< hi 0) (- 0 ($simplest-positive (- 0 hi) (- 0 lo))))
        (else 0)))
;; 0 < lo < hi
(define ($simplest-positive lo hi)
  (let ((fl (floor lo)))
    (cond ((= fl lo) fl)
          ((< fl (floor hi)) (+ fl 1))
          (else (+ fl (/ 1 ($simplest-positive (/ 1 (- hi fl))
                                               (/ 1 (- lo fl)))))))))

;; expect: #t
;; What the wire MEANS, for the whole value model.
;;
;; test/sexpr-golden.ss checks a fixed point: parse the authority's
;; bytes, write them back, compare.  That is blind to a matching pair of
;; mistakes -- decode a flonum big-endian AND encode it big-endian and
;; every byte still agrees while every value in between is wrong.  This
;; file closes that by never letting the codec supply the value: each
;; anchor in test/sexpr-vectors.json carries a SPEC, this file builds
;; the value from the spec with its own code, and both directions are
;; asserted against the authority's bytes.
;;
;; The anchors used to be a hand-kept list, one entry appearing each
;; time a reviewer named a paired mutation that survived.  That is the
;; same shape the symbol corpus had before it was made a cross product,
;; and it has the same answer: the fixture's anchors are now type x
;; spelling branch over the value model, and the branch names are
;; PINNED below.  A branch that stops being generated fails here by
;; name rather than by lowering a count nobody reads.
;;
;; THE OTHER LEG.  test/sexpr-limits.ss holds a smaller, CLOSED set of
;; the same value-level checks whose expected bytes are literals in its
;; own source.  Everything this file knows it learns from the fixture,
;; so a fixture regenerated against a broken authority takes this whole
;; file with it and leaves that one standing -- two mechanisms reaching
;; one answer by different routes, which is worth more than two copies
;; of this one.  Neither is redundant with the other; do not delete
;; either without reading why the other exists.  New value coverage
;; belongs in the generator's matrix, here, not there.
;;
;; Nothing in this file may go through (web sexpr) to obtain a value.
;; The spec reader, the decimal reader and the flonum bit helpers below
;; are deliberate re-implementations; if they were shared with the codec
;; a mutation in the shared part would move both sides at once and this
;; file would agree with it.
(import (rnrs) (web js) (web fs) (web sexpr))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))

(define (refusal? e)
  (and (list? e) (= 3 (length e)) (eq? (car e) 'sexpr-error)))

;; ---- flonum bits, independent of the codec's copy --------------------
;; The codec has helpers of the same shape.  These are separate on
;; purpose: sharing them would mean a mutation in the shared helper
;; moved the expectation along with the thing being measured.

(define _anchor-bits
  (js-eval "globalThis.__saB2F=(a,b,c,d,e,f,g,h)=>{
              const dv=new DataView(new ArrayBuffer(8));
              const u=[a,b,c,d,e,f,g,h];
              for(let i=0;i<8;i++)dv.setUint8(i,u[i]);
              return dv.getFloat64(0,true);};
            globalThis.__saF2B=(x,i)=>{
              const dv=new DataView(new ArrayBuffer(8));
              dv.setFloat64(0,x,true);
              return new Uint8Array(dv.buffer)[i];}"))

(define __saB2F (js-get (js-global) "__saB2F"))
(define __saF2B (js-get (js-global) "__saF2B"))

;; js->number hands an integral JS double back as a FIXNUM, and -0 is
;; integral, so the sign of a negative zero is gone before any Scheme
;; code sees it.  The bytes still carry it, so rebuild from byte 7.
(define (bytes->fl b0 b1 b2 b3 b4 b5 b6 b7)
  (let ((v (exact->inexact
            (js->number (js-call __saB2F (js-undefined)
                                 b0 b1 b2 b3 b4 b5 b6 b7)))))
    (if (and (fl=? v 0.0) (>= b7 128)) (fl* (fl- 0.0 1.0) 0.0) v)))

(define (fl-byte x i)
  (js->number (js-call __saF2B (js-undefined) x i)))

(define (fl-bits=? a b)
  (let loop ((i 0))
    (or (= i 8)
        (and (= (fl-byte a i) (fl-byte b i)) (loop (+ i 1))))))

;; ---- comparing data ---------------------------------------------------
;; Flonums compare as BITS: eqv? joins all NaNs and this fixture anchors
;; NaN payloads, where "some NaN came back" is not the question.

(define (same-datum? a b)
  (cond ((and (flonum? a) (flonum? b)) (fl-bits=? a b))
        ((or (flonum? a) (flonum? b)) #f)
        ((and (pair? a) (pair? b))
         (and (same-datum? (car a) (car b)) (same-datum? (cdr a) (cdr b))))
        ((and (vector? a) (vector? b))
         (and (= (vector-length a) (vector-length b))
              (let loop ((i 0))
                (or (= i (vector-length a))
                    (and (same-datum? (vector-ref a i) (vector-ref b i))
                         (loop (+ i 1)))))))
        ((and (string? a) (string? b)) (string=? a b))
        ((and (bytevector? a) (bytevector? b)) (bytevector=? a b))
        ((and (number? a) (number? b))
         ;; exactness is part of the datum: an integer arriving where a
         ;; flonum was anchored must not pass on numeric equality alone
         (and (eq? (exact? a) (exact? b)) (= a b)))
        (else (eqv? a b))))

;; ---- the spec language ------------------------------------------------
;; A prefix token program; every payload is a decimal integer and all
;; text is carried as UTF-8 bytes, so reading one involves no string
;; escaping -- which is the layer these tests exist to check, and so the
;; last layer that should be load-bearing in the harness.  The grammar
;; is documented beside the generator in test/gen-sexpr-vectors.sc.

(define (spec-split s)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s))
           (reverse (if (> i start) (cons (substring s start i) acc) acc)))
          ((char=? (string-ref s i) #\space)
           (loop (+ i 1) (+ i 1)
                 (if (> i start) (cons (substring s start i) acc) acc)))
          (else (loop (+ i 1) start acc)))))

;; Digits folded by hand rather than through string->number: the codec
;; reads its numbers from text too, and a shared reader is a shared
;; mistake.
;;
;; -> the integer, or #f when the token is not a numeral in THIS
;; language.  Folding every character as a digit made `N Z` denote 42
;; (#\Z minus #\0), so a spec could name a value with a token that is
;; not a number at all -- and the three readers each answered
;; differently, which is worse than any one of them being wrong.
(define (spec-int tok)
  (let* ((m (string-length tok))
         (neg (and (> m 0) (char=? (string-ref tok 0) #\-)))
         (start (if neg 1 0)))
    (and (> m start)
         (let loop ((i start) (acc 0))
           (cond ((= i m) (if neg (- 0 acc) acc))
                 ((and (char<=? #\0 (string-ref tok i))
                       (char<=? (string-ref tok i) #\9))
                  (loop (+ i 1)
                        (+ (* acc 10) (- (char->integer (string-ref tok i)) 48))))
                 (else #f))))))

;; a count: a numeral that is not negative
(define (spec-count tok)
  (let ((n (spec-int tok))) (and n (>= n 0) n)))

;; This runtime's strings are UTF-8 byte strings, so a byte list is a
;; string directly.  (On a code-point host the same spec decodes the
;; bytes instead; that is the point of carrying bytes.)
(define (bytes->str bs)
  (let loop ((bs bs) (acc '()))
    (if (null? bs)
        (list->string (reverse acc))
        (loop (cdr bs) (cons (integer->char (car bs)) acc)))))

;; ...but the bytes must BE a string.  This runtime would keep any byte
;; sequence, Chez turns a bad one into U+FFFD and the JS reader refuses
;; it, so `S 1 255` denoted three different things in the three readers.
;; The wire has no string that is not well-formed UTF-8, so the spec
;; language has none either.  Written out here rather than borrowed from
;; the codec: the codec's copy is one of the things under test.
(define (spec-utf8-ok? bs)
  (let loop ((bs bs))
    (if (null? bs)
        #t
        (let ((b (car bs)) (rest (cdr bs)))
          (define (cont n xs)
            (and (>= (length xs) n)
                 (let check ((k 0) (ys xs))
                   (or (= k n)
                       (and (>= (car ys) 128) (< (car ys) 192)
                            (check (+ k 1) (cdr ys)))))))
          (cond
           ((< b 128) (loop rest))
           ((< b 194) #f)                       ; continuation or overlong
           ((< b 224) (and (cont 1 rest) (loop (list-tail rest 1))))
           ((< b 240)
            (and (cont 2 rest)
                 (let ((cp (+ (* (- b 224) 4096)
                              (* (- (car rest) 128) 64)
                              (- (cadr rest) 128))))
                   (and (>= cp 2048)
                        (not (and (>= cp 55296) (< cp 57344)))))
                 (loop (list-tail rest 2))))
           ((< b 245)
            (and (cont 3 rest)
                 (let ((cp (+ (* (- b 240) 262144)
                              (* (- (car rest) 128) 4096)
                              (* (- (cadr rest) 128) 64)
                              (- (caddr rest) 128))))
                   (and (>= cp 65536) (<= cp 1114111)))
                 (loop (list-tail rest 3))))
           (else #f))))))

(define (spec-read toks)
  ;; -> (cons value remaining-tokens), or #f when the program is
  ;; malformed.  Success is ALWAYS a pair, so #f is unambiguous even
  ;; though `F` reads as the value #f.
  ;;
  ;; Failure has to propagate rather than be reported in place.  The
  ;; first version returned a sentinel VALUE and dropped the rest of the
  ;; program, and the sentinel was only ever looked for at top level --
  ;; so `L 1 Z` read as the perfectly good datum `(spec-unknown-tag)`,
  ;; and an anchor pairing that spec with the wire `(spec-unknown-tag)`
  ;; passed.  A malformed spec must not be readable as a shorter valid
  ;; value; running out of tokens must not be readable as a shorter one
  ;; either, which is why every arm checks that its tokens are there.
  (if (null? toks)
      #f
      (let ((tag (car toks)) (r (cdr toks)))
        (define (take-nums n rest)
          (let loop ((k 0) (rest rest) (acc '()))
            (cond ((= k n) (cons (reverse acc) rest))
                  ((null? rest) #f)
                  (else
                   (let ((b (spec-int (car rest))))
                     ;; not a numeral, or not a byte
                     (and b (>= b 0) (< b 256)
                          (loop (+ k 1) (cdr rest) (cons b acc))))))))
        (define (take-vals n rest)
          (let loop ((k 0) (rest rest) (acc '()))
            (if (= k n)
                (cons (reverse acc) rest)
                (let ((got (spec-read rest)))
                  (and got (loop (+ k 1) (cdr got) (cons (car got) acc)))))))
        ;; read the count token, then hand the remainder to k
        (define (counted k)
          (and (pair? r)
               (let ((n (spec-count (car r))))
                 (and n (k n (cdr r))))))
        (define (bytes-then k)
          (counted (lambda (n rest)
                     (let ((got (take-nums n rest)))
                       (and got (cons (k (car got)) (cdr got)))))))
        ;; the S and Y payloads additionally have to be a string
        (define (text-then k)
          (counted (lambda (n rest)
                     (let ((got (take-nums n rest)))
                       (and got (spec-utf8-ok? (car got))
                            (cons (k (car got)) (cdr got)))))))
        (cond
         ((string=? tag "T") (cons #t r))
         ((string=? tag "F") (cons #f r))
         ((string=? tag "NIL") (cons '() r))
         ((string=? tag "N")
          (and (pair? r)
               (let ((v (spec-int (car r)))) (and v (cons v (cdr r))))))
         ((string=? tag "Q")
          ;; a zero denominator is not a datum, and neither reader may
          ;; invent one
          (and (pair? r) (pair? (cdr r))
               (let ((n (spec-int (car r))) (d (spec-int (cadr r))))
                 (and n d (not (= d 0))
                      ;; Q must denote a RATIO: `Q 4 2` is 2 and
                      ;; `Q 0 7` is 0, which N already spells.  Same
                      ;; aliasing as P, one tag over -- a tag that can
                      ;; produce a datum outside the kind it names has
                      ;; stopped naming that kind.  (Needing reduction,
                      ;; as `Q 2 4` does, is still a ratio.)
                      (not (integer? (/ n d)))
                      (cons (/ n d) (cddr r))))))
         ((string=? tag "D")
          (let ((got (take-nums 8 r)))
            (and got
                 (let ((b (car got)))
                   (cons (bytes->fl (list-ref b 0) (list-ref b 1) (list-ref b 2)
                                    (list-ref b 3) (list-ref b 4) (list-ref b 5)
                                    (list-ref b 6) (list-ref b 7))
                         (cdr got))))))
         ((string=? tag "S") (text-then bytes->str))
         ((string=? tag "Y")
          (text-then (lambda (bs) (string->symbol (bytes->str bs)))))
         ((string=? tag "B")
          (bytes-then (lambda (bs)
                        (let ((bv (make-bytevector (length bs) 0)))
                          (let fill ((i 0) (xs bs))
                            (unless (null? xs)
                              (bytevector-u8-set! bv i (car xs))
                              (fill (+ i 1) (cdr xs))))
                          bv))))
         ((string=? tag "L")
          (counted (lambda (n rest)
                     (let ((got (take-vals n rest)))
                       (and got (cons (car got) (cdr got)))))))
         ((string=? tag "P")
          ;; at least one element, or this is a spelling of its own tail
          ;; -- `P 0 X` denotes X, which would be a second name for an
          ;; anchor that already exists
          (counted (lambda (n rest)
                     (and (> n 0)
                          (let ((got (take-vals n rest)))
                            (and got
                                 (let ((tail (spec-read (cdr got))))
                                   ;; the tail must be an ATOM: neither
                                   ;; () nor a pair.  A tail that is a
                                   ;; list merges into the enclosing
                                   ;; one, so `P 1 N 1 NIL` is `(1)`,
                                   ;; `P 1 N 1 L 1 N 2` is `(1 2)` and
                                   ;; `P 1 N 1 P 1 N 2 N 3` is
                                   ;; `(1 2 . 3)` -- each a second
                                   ;; spelling of a datum that has one.
                                   ;; Refusing only () fixed one level
                                   ;; and a nested P walked through it.
                                   (and tail
                                        (not (null? (car tail)))
                                        (not (pair? (car tail)))
                                        (cons (let build ((xs (car got)))
                                                (if (null? xs)
                                                    (car tail)
                                                    (cons (car xs) (build (cdr xs)))))
                                              (cdr tail))))))))))
         ((string=? tag "V")
          (counted (lambda (n rest)
                     (let ((got (take-vals n rest)))
                       (and got (cons (list->vector (car got)) (cdr got)))))))
         (else #f)))))

;; -> (list value) when the whole program reads, #f otherwise.  Wrapped
;; because the value itself may be #f.
(define (spec->value s)
  (let ((got (spec-read (spec-split s))))
    (and (pair? got) (null? (cdr got)) (list (car got)))))

;; The spec reader is itself a piece of evidence, so it gets its own
;; check: a handful of programs whose values this file can state without
;; any help from the fixture.  A reader that silently mis-parsed lengths
;; would otherwise make every anchor below agree with a wrong value.
(define (reads-to? spec v)
  (let ((got (spec->value spec)))
    (and (pair? got) (same-datum? (car got) v))))
(define (refuses-spec? spec) (not (spec->value spec)))

;; The spec reader is itself a piece of evidence, so it gets its own
;; check against values stated here rather than taken from the fixture.
;; A reader that mis-counted a length would otherwise make every anchor
;; below agree with a wrong value.
(define spec-reader-ok
  (and (reads-to? "L 2 N 1 S 1 65" (list 1 "A"))
       (reads-to? "P 1 N 1 N 2" (cons 1 2))
       (reads-to? "V 2 T NIL" (vector #t '()))
       (reads-to? "N -42" -42)
       (reads-to? "D 0 0 0 0 0 0 248 63" 1.5)
       (reads-to? "F" #f)))          ; the value #f is not the failure #f

;; ...and the SHARED CORPUS, read from the fixture rather than copied
;; here.  It used to be three hand-kept lists in three languages, and a
;; round shipped with two extended and this one left behind while the
;; report said "one shared list, all three".  Copies cannot be kept in
;; step by discipline; the generator emits the list it ran against its
;; own reader, and this runs the same programs.
;;
;; The wellformed half is not decoration: a reader that refused
;; everything would satisfy the malformed half perfectly.
(define (no-duplicates? len-fn get-fn)
  (let dup ((i 0) (ok #t))
    (if (= i (js->number (call-js len-fn)))
        ok
        (let ((a (js->string (call-js get-fn i))))
          (let scan ((j (+ i 1)) (ok ok))
            (if (= j (js->number (call-js len-fn)))
                (dup (+ i 1) ok)
                (let ((b (js->string (call-js get-fn j))))
                  (when (string=? a b)
                    (display "  duplicate in the corpus: ")
                    (display a) (newline))
                  (scan (+ j 1) (and ok (not (string=? a b)))))))))))

(define (corpus-ok)
  (and (> (js->number (call-js "__saMalformedLen")) 0)
       (> (js->number (call-js "__saWellformedLen")) 0)
       (let bad ((i 0) (ok #t))
         (if (= i (js->number (call-js "__saMalformedLen")))
             (let good ((i 0) (ok ok))
               (if (= i (js->number (call-js "__saWellformedLen")))
                   ok
                   ;; ACCEPTED is not READ RIGHT.  These used to be
                   ;; checked only for "does not raise", so a reader
                   ;; taking a ratio as n/|d| made `Q 1 -2` denote +1/2
                   ;; and stayed on the list.  Each program now carries
                   ;; the authority's bytes for the value it denotes.
                   (let* ((spec (js->string (call-js "__saWellformed" i)))
                          (wire (js->string (call-js "__saWellformedWire" i)))
                          (got (spec->value spec))
                          (back (and (pair? got)
                                     (guard (e ((refusal? e) 'raised))
                                       (sexpr->string (car got))))))
                     (unless (and (string? back) (string=? back wire))
                       (display "  well-formed spec reads as the wrong value: ")
                       (display spec) (display " -> ")
                       (display (if (string? back) back "refused"))
                       (display " but the authority writes ") (display wire)
                       (newline))
                     (good (+ i 1)
                           (and ok (string? back) (string=? back wire))))))
             (let ((spec (js->string (call-js "__saMalformed" i))))
               (unless (refuses-spec? spec)
                 (display "  accepted a malformed spec: ")
                 (display spec) (newline))
               (bad (+ i 1) (and ok (refuses-spec? spec))))))))

;; ---- the fixture ------------------------------------------------------

(define FIXTURE-PATH "test/sexpr-vectors.json")
(define fixture-present? (fs-exists? FIXTURE-PATH))

(define parse-fixture
  (js-eval "globalThis.__saFixture=(text)=>{const d=JSON.parse(text);
    const dec=(b64)=>{const bin=atob(b64);
      const bytes=new Uint8Array(bin.length);
      for(let i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
      return new TextDecoder('utf-8',{fatal:true}).decode(bytes);};
    // the probe runs THIS closure's decoder, not a fresh one: a
    // hard-coded fatal decoder here would stay fatal while this one was
    // reverted, and prove only that TextDecoder CAN be fatal
    globalThis.__saDecodeProbe=(b64)=>{try{dec(b64);return 0;}catch(e){return 1;}};
    const a=d.anchors||[];
    globalThis.__saLen=()=>a.length;
    globalThis.__saDeclared=()=>(d.counts&&d.counts.anchors)|0;
    globalThis.__saType=(i)=>a[i].type;
    globalThis.__saBranch=(i)=>a[i].branch;
    globalThis.__saSpec=(i)=>a[i].spec;
    globalThis.__saWire=(i)=>dec(a[i].wire_b64);
    globalThis.__saDir=(i)=>a[i].direction;
    // every anchor carries an atom; only `position` is nesting-only,
    // and '' is how an absent field arrives
    globalThis.__saMalformedLen=()=>(d.spec_malformed||[]).length;
    globalThis.__saMalformed=(i)=>d.spec_malformed[i];
    globalThis.__saWellformedLen=()=>(d.spec_wellformed||[]).length;
    globalThis.__saWellformed=(i)=>d.spec_wellformed[i].spec;
    globalThis.__saWellformedWhy=(i)=>d.spec_wellformed[i].why||'';
    globalThis.__saWellformedWire=(i)=>dec(d.spec_wellformed[i].wire_b64);
    globalThis.__saHoleLen=()=>(d.nesting_holes||[]).length;
    globalThis.__saHoleAtom=(i)=>d.nesting_holes[i].atom;
    globalThis.__saHolePosition=(i)=>d.nesting_holes[i].position;
    globalThis.__saHoleReason=(i)=>d.nesting_holes[i].reason||'';
    globalThis.__saAtom=(i)=>a[i].atom||'';
    globalThis.__saPosition=(i)=>a[i].position||'';
    return a.length;}"))

(define (call-js name . args)
  (apply js-call (js-get (js-global) name) (js-undefined) args))
(define (sa-len) (js->number (call-js "__saLen")))
(define (sa-declared) (js->number (call-js "__saDeclared")))
(define (sa-str name i) (js->string (call-js name i)))

(define loaded
  (and fixture-present?
       (let ((text (fs-slurp-string FIXTURE-PATH)))
         (js->number (js-call (js-get (js-global) "__saFixture")
                              (js-undefined) (string->js text))))))

;; ---- the type column is load-bearing, not a label --------------------
;; Asserted against the value the CODEC returned, so a decoder handing
;; back an integer where a flonum is anchored fails on the type name
;; even in the cases where the two would compare numerically equal.

(define (type-matches? type v)
  (cond ((string=? type "boolean") (boolean? v))
        ((string=? type "null") (null? v))
        ((string=? type "integer") (and (number? v) (exact? v) (integer? v)))
        ((string=? type "ratio")
         (and (number? v) (exact? v) (not (integer? v))))
        ((string=? type "flonum") (flonum? v))
        ((string=? type "string") (string? v))
        ((string=? type "symbol") (symbol? v))
        ((string=? type "bytevector") (bytevector? v))
        ((string=? type "vector") (vector? v))
        ((string=? type "list") (pair? v))
        ;; an atom placed inside a compound: the compound is what comes
        ;; back, and same-datum? is what checks the atom in its place
        ((string=? type "nesting") (or (pair? v) (vector? v)))
        (else #f)))

;; ---- what a nesting cell claims about itself -------------------------
;; A branch called "bytevector-in-list" is a name, and a name is not a
;; check: swapping the bytevector atom for the integer 255 upstream left
;; every such branch holding an integer with nothing red anywhere.  The
;; fixture therefore carries the atom's type and the position it sits
;; in, and both are asserted against the DECODED value.

(define (atom-at position v)
  ;; -> the value at the named position, or 'no-such-position
  (cond ((and (string=? position "head-of-list") (pair? v)) (car v))
        ((and (string=? position "in-list") (pair? v) (pair? (cdr v)))
         (cadr v))
        ((and (string=? position "in-vector") (vector? v)
              (> (vector-length v) 1))
         (vector-ref v 1))
        ((and (string=? position "as-tail") (pair? v)) (cdr v))
        ((and (string=? position "deep") (pair? v) (pair? (cdr v))
              (pair? (cadr v)) (pair? (cdr (cadr v))))
         (cadr (cadr v)))
        (else 'no-such-position)))

;; THE SAME FUNCTION the generator used to name the cell, recomputed
;; here on the DECODED value and compared by equality.
;;
;; This replaced a table of predicates, because a predicate table only
;; means something if its clauses are mutually exclusive and ours were
;; not: `-0.0` satisfied both `negative-zero` and a generic `flonum`, a
;; string with a control character AND a multi-byte sequence satisfied
;; two, and nothing asserted exclusivity anywhere.  A total function
;; into one label cannot have that problem.
;;
;; A loose check is not enough either, and that is measured: with the
;; atom verified only as "an integer", swapping the bignum for 255
;; passed; with it verified only as "a bytevector", a four-byte value
;; moved `bytevector-pad1` into the `==` class and silently undid a
;; whole round's padding coverage.
(define fixnum-max 536870911)
(define fixnum-min -536870912)   ; i31 with a tag bit: NOT symmetric

(define (string-label str)
  (let loop ((i 0) (control #f) (escape #f) (high #f))
    (if (= i (string-length str))
        (let ((n (+ (if control 1 0) (if escape 1 0) (if high 1 0))))
          (cond ((= n 0) "plain-string")
                ((> n 1) "ambiguous-string")
                (control "control-string")
                (escape "escape-string")
                (else "utf8-string")))
        (let ((b (char->integer (string-ref str i))))
          (loop (+ i 1)
                (or control (< b 32))
                (or escape (or (= b 34) (= b 92)))
                (or high (>= b 128)))))))

(define (nesting-label v)
  (cond
   ((eq? v #f) "false")
   ((eq? v #t) "true")
   ((flonum? v)
    ;; the sign bit, which is the whole reason a negative zero nests
    (if (and (fl=? v 0.0) (>= (fl-byte v 7) 128)) "negative-zero" "flonum"))
   ((and (number? v) (exact? v) (integer? v))
    ;; asymmetric on purpose: -536870912 IS a fixnum, and testing the
    ;; absolute value called it a bignum -- so every bignum-* cell
    ;; could have held a fixnum and stayed green
    (if (or (> v fixnum-max) (< v fixnum-min)) "bignum" "small-integer"))
   ((and (number? v) (exact? v) (not (integer? v))) "ratio")
   ((bytevector? v)
    (string-append "bytevector-pad"
                   (number->string (mod (- 3 (mod (bytevector-length v) 3)) 3))))
   ((null? v) "empty-list")
   ((vector? v) "vector")
   ((pair? v)
    ;; the tail loop's null arm and its dotted arm are two branches, so
    ;; a proper list and a dotted pair are two atoms, not one
    (let walk ((x v))
      (cond ((null? (cdr x)) "proper-list")
            ((pair? (cdr x)) (walk (cdr x)))
            (else "dotted-pair"))))
   ((string? v) (string-label v))
   ((symbol? v)
    (let ((str (symbol->string v)))
      (let loop ((i 0))
        (cond ((= i (string-length str)) "plain-symbol")
              ((memv (char->integer (string-ref str i))
                     '(42 43 45 60 61 62 63 33))
               "punctuation-symbol")
              (else (loop (+ i 1)))))))
   (else "no-label")))

;; ...and the NAME has to say the same thing as the columns, or a
;; fixture can label a depth-two cell "in-list" (whose extractor finds
;; the intermediate list, which passes a loose test) while the branch
;; still advertises "deep".
(define (atom-claim-holds? atom position branch v)
  (and (or (string=? branch (string-append atom "-" position))
           (string=? branch (string-append atom "-" position "-escaped")))
       (let ((found (atom-at position v)))
         (and (not (eq? found 'no-such-position))
              (string=? atom (nesting-label found))))))

;; ---- the sweep --------------------------------------------------------

(define seen-branches '())

(define anchors-ok
  (and loaded
       (let loop ((i 0) (ok #t))
         (if (= i (sa-len))
             ok
             (let* ((type (sa-str "__saType" i))
                    (branch (sa-str "__saBranch" i))
                    (where (string-append type "/" branch))
                    (spec (sa-str "__saSpec" i))
                    (wire (sa-str "__saWire" i))
                    (dir (sa-str "__saDir" i))
                    (atom (sa-str "__saAtom" i))
                    (position (sa-str "__saPosition" i))
                    (wrapped (spec->value spec))
                    (want (and (pair? wrapped) (car wrapped)))
                    (got (guard (e ((refusal? e) 'raised))
                           (string->sexpr wire)))
                    ;; The writer runs for EVERY anchor, not only the
                    ;; ones marked "both".  direction is the generator's
                    ;; measurement of the authority, and a fixture that
                    ;; downgraded a "both" to "read" would otherwise buy
                    ;; itself a skipped writer check -- so "read" is
                    ;; asserted too, as the writer NOT producing that
                    ;; wire (our writer must agree with the authority,
                    ;; and the authority does not emit it).
                    (back (and (pair? wrapped)
                               (guard (e ((refusal? e) 'raised))
                                 (sexpr->string want))))
                    (bad (lambda (why)
                           (display "  anchor ") (display where)
                           (display ": ") (display why) (newline)
                           #f)))
               (set! seen-branches (cons where seen-branches))
               (loop (+ i 1)
                     (and ok
                          (cond
                           ((not (pair? wrapped))
                            (bad "this file cannot read the spec -- an \
unknown tag, a count past the end, or tokens left over"))
                           ((eq? got 'raised)
                            (bad "the reader refuses the authority's wire"))
                           ((not (type-matches? type got))
                            (bad "the decoded value is not of the anchored type"))
                           ((not (same-datum? got want))
                            (bad "the decoded value is not the anchored value"))
                           ;; the atom/position claim, checked against
                           ;; the DECODED value: without it the branch
                           ;; name is the only thing saying a bytevector
                           ;; is involved, and a name is not a check
                           ;; EVERY anchor names what its value is; a
                           ;; top-level branch used to be checked
                           ;; against nothing finer than its type, so
                           ;; swapping the values and wires of
                           ;; `boolean/true` and `boolean/false` left
                           ;; both names false with everything green
                           ((and (string=? position "")
                                 (not (string=? atom (nesting-label got))))
                            (bad (string-append "filed as " atom
                                                " but the value is a "
                                                (nesting-label got))))
                           ((and (> (string-length position) 0)
                                 (not (atom-claim-holds? atom position
                                                         branch got)))
                            (bad (string-append "the name or the columns are "
                                                "not true of the value: no "
                                                atom " " position)))
                           ((eq? back 'raised)
                            (bad "the writer refuses the anchored value"))
                           ((and (string=? dir "both") (not (string=? back wire)))
                            (begin (display "  anchor ") (display where)
                                   (display ": written as ") (display back)
                                   (display " but the authority writes ")
                                   (display wire) (newline)
                                   #f))
                           ((and (string=? dir "read") (string=? back wire))
                            (bad "marked read-only, but our writer emits \
exactly this wire -- either the fixture downgraded a measured direction \
or the writer disagrees with the authority"))
                           ((not (or (string=? dir "both") (string=? dir "read")))
                            (bad "unknown direction"))
                           (else #t)))))))))

;; ---- the branch matrix, pinned by name -------------------------------
;; A count alone would let an equal-sized substitution pass.  These are
;; the branches the generator's cross product produces; if it stops
;; producing one, that is a decision to make, not a number to update.

;; (branch . atom) PAIRS, not names.  The atom column was checked
;; against the decoded value but never against the branch that carries
;; it, so swapping the complete contents of `boolean/true` and
;; `boolean/false` -- atom included -- left both names false with
;; everything green.  Pinning the pair is the same move the well-formed
;; corpus needed: a claim has to be attached to something.
;;
;; It does not make every branch name a checked claim.  `flonum/half`
;; and `flonum/repeating` are both `flonum`; `integer/positive` and
;; `integer/negative` are both `small-integer`.  Where two branches
;; share a label, their names stay conventions.
(define expected-branches
  '(
    ("boolean/true"
     . "true")
    ("boolean/false"
     . "false")
    ("null/empty-list"
     . "empty-list")
    ("integer/zero"
     . "small-integer")
    ("integer/positive"
     . "small-integer")
    ("integer/negative"
     . "small-integer")
    ("integer/bignum-positive"
     . "bignum")
    ("integer/bignum-negative"
     . "bignum")
    ("integer/fixnum-edge-positive"
     . "small-integer")
    ("integer/fixnum-edge-negative"
     . "small-integer")
    ("integer/fixnum-edge-past"
     . "bignum")
    ("ratio/positive"
     . "ratio")
    ("ratio/negative"
     . "ratio")
    ("flonum/half"
     . "flonum")
    ("flonum/integral"
     . "flonum")
    ("flonum/repeating"
     . "flonum")
    ("flonum/negative"
     . "flonum")
    ("flonum/positive-zero"
     . "flonum")
    ("flonum/negative-zero"
     . "negative-zero")
    ("flonum/positive-infinity"
     . "flonum")
    ("flonum/negative-infinity"
     . "flonum")
    ("flonum/nan-quiet"
     . "flonum")
    ("flonum/nan-payload"
     . "flonum")
    ("flonum/nan-negative"
     . "flonum")
    ("flonum/min-subnormal"
     . "flonum")
    ("flonum/min-normal"
     . "flonum")
    ("flonum/max-finite"
     . "flonum")
    ("string/empty"
     . "plain-string")
    ("string/ascii"
     . "plain-string")
    ("string/quote"
     . "escape-string")
    ("string/backslash"
     . "escape-string")
    ("string/latin1"
     . "utf8-string")
    ("string/cjk"
     . "utf8-string")
    ("string/astral"
     . "utf8-string")
    ("symbol/plain"
     . "plain-symbol")
    ("symbol/hyphenated"
     . "punctuation-symbol")
    ("symbol/punctuation"
     . "punctuation-symbol")
    ("symbol/case-lower"
     . "plain-symbol")
    ("symbol/case-upper"
     . "plain-symbol")
    ("symbol/case-mixed"
     . "plain-symbol")
    ("bytevector/empty"
     . "bytevector-pad0")
    ("bytevector/one-byte"
     . "bytevector-pad2")
    ("bytevector/two-bytes"
     . "bytevector-pad1")
    ("bytevector/three-bytes"
     . "bytevector-pad0")
    ("bytevector/zero-byte"
     . "bytevector-pad2")
    ("bytevector/whole-alphabet"
     . "bytevector-pad0")
    ("vector/empty"
     . "vector")
    ("vector/single"
     . "vector")
    ("vector/nested"
     . "vector")
    ("vector/mixed"
     . "vector")
    ("list/single"
     . "proper-list")
    ("list/proper"
     . "proper-list")
    ("list/dotted-pair"
     . "dotted-pair")
    ("list/dotted-tail"
     . "dotted-pair")
    ("list/nested"
     . "proper-list")
    ("list/alist"
     . "proper-list")
    ("list/mixed"
     . "proper-list")
    ("list/containing-empty"
     . "proper-list")
    ("nesting/negative-zero-head-of-list"
     . "negative-zero")
    ("nesting/negative-zero-in-list"
     . "negative-zero")
    ("nesting/negative-zero-in-vector"
     . "negative-zero")
    ("nesting/negative-zero-as-tail"
     . "negative-zero")
    ("nesting/negative-zero-deep"
     . "negative-zero")
    ("nesting/ratio-head-of-list"
     . "ratio")
    ("nesting/ratio-in-list"
     . "ratio")
    ("nesting/ratio-in-vector"
     . "ratio")
    ("nesting/ratio-as-tail"
     . "ratio")
    ("nesting/ratio-deep"
     . "ratio")
    ("nesting/bignum-head-of-list"
     . "bignum")
    ("nesting/bignum-in-list"
     . "bignum")
    ("nesting/bignum-in-vector"
     . "bignum")
    ("nesting/bignum-as-tail"
     . "bignum")
    ("nesting/bignum-deep"
     . "bignum")
    ("nesting/bytevector-pad2-head-of-list"
     . "bytevector-pad2")
    ("nesting/bytevector-pad2-in-list"
     . "bytevector-pad2")
    ("nesting/bytevector-pad2-in-vector"
     . "bytevector-pad2")
    ("nesting/bytevector-pad2-as-tail"
     . "bytevector-pad2")
    ("nesting/bytevector-pad2-deep"
     . "bytevector-pad2")
    ("nesting/bytevector-pad1-head-of-list"
     . "bytevector-pad1")
    ("nesting/bytevector-pad1-in-list"
     . "bytevector-pad1")
    ("nesting/bytevector-pad1-in-vector"
     . "bytevector-pad1")
    ("nesting/bytevector-pad1-as-tail"
     . "bytevector-pad1")
    ("nesting/bytevector-pad1-deep"
     . "bytevector-pad1")
    ("nesting/bytevector-pad0-head-of-list"
     . "bytevector-pad0")
    ("nesting/bytevector-pad0-in-list"
     . "bytevector-pad0")
    ("nesting/bytevector-pad0-in-vector"
     . "bytevector-pad0")
    ("nesting/bytevector-pad0-as-tail"
     . "bytevector-pad0")
    ("nesting/bytevector-pad0-deep"
     . "bytevector-pad0")
    ("nesting/control-string-head-of-list"
     . "control-string")
    ("nesting/control-string-in-list"
     . "control-string")
    ("nesting/control-string-in-vector"
     . "control-string")
    ("nesting/control-string-as-tail"
     . "control-string")
    ("nesting/control-string-deep"
     . "control-string")
    ("nesting/escape-string-head-of-list"
     . "escape-string")
    ("nesting/escape-string-in-list"
     . "escape-string")
    ("nesting/escape-string-in-vector"
     . "escape-string")
    ("nesting/escape-string-as-tail"
     . "escape-string")
    ("nesting/escape-string-deep"
     . "escape-string")
    ("nesting/utf8-string-head-of-list"
     . "utf8-string")
    ("nesting/utf8-string-in-list"
     . "utf8-string")
    ("nesting/utf8-string-in-vector"
     . "utf8-string")
    ("nesting/utf8-string-as-tail"
     . "utf8-string")
    ("nesting/utf8-string-deep"
     . "utf8-string")
    ("nesting/punctuation-symbol-head-of-list"
     . "punctuation-symbol")
    ("nesting/punctuation-symbol-in-list"
     . "punctuation-symbol")
    ("nesting/punctuation-symbol-in-vector"
     . "punctuation-symbol")
    ("nesting/punctuation-symbol-as-tail"
     . "punctuation-symbol")
    ("nesting/punctuation-symbol-deep"
     . "punctuation-symbol")
    ("nesting/false-head-of-list"
     . "false")
    ("nesting/false-in-list"
     . "false")
    ("nesting/false-in-vector"
     . "false")
    ("nesting/false-as-tail"
     . "false")
    ("nesting/false-deep"
     . "false")
    ("nesting/true-head-of-list"
     . "true")
    ("nesting/true-in-list"
     . "true")
    ("nesting/true-in-vector"
     . "true")
    ("nesting/true-as-tail"
     . "true")
    ("nesting/true-deep"
     . "true")
    ("nesting/empty-list-head-of-list"
     . "empty-list")
    ("nesting/empty-list-in-list"
     . "empty-list")
    ("nesting/empty-list-in-vector"
     . "empty-list")
    ("nesting/empty-list-deep"
     . "empty-list")
    ("nesting/vector-head-of-list"
     . "vector")
    ("nesting/vector-in-list"
     . "vector")
    ("nesting/vector-in-vector"
     . "vector")
    ("nesting/vector-as-tail"
     . "vector")
    ("nesting/vector-deep"
     . "vector")
    ("nesting/proper-list-head-of-list"
     . "proper-list")
    ("nesting/proper-list-in-list"
     . "proper-list")
    ("nesting/proper-list-in-vector"
     . "proper-list")
    ("nesting/proper-list-deep"
     . "proper-list")
    ("nesting/dotted-pair-head-of-list"
     . "dotted-pair")
    ("nesting/dotted-pair-in-list"
     . "dotted-pair")
    ("nesting/dotted-pair-in-vector"
     . "dotted-pair")
    ("nesting/dotted-pair-deep"
     . "dotted-pair")
    ("nesting/control-string-head-of-list-escaped"
     . "control-string")
    ("nesting/control-string-in-list-escaped"
     . "control-string")
    ("nesting/control-string-in-vector-escaped"
     . "control-string")
    ("nesting/control-string-as-tail-escaped"
     . "control-string")
    ("nesting/control-string-deep-escaped"
     . "control-string")
    ("string/control-newline-raw"
     . "control-string")
    ("string/control-newline-escaped"
     . "control-string")
    ("string/control-tab-raw"
     . "control-string")
    ("string/control-tab-escaped"
     . "control-string")
    ("string/control-return-raw"
     . "control-string")
    ("string/control-return-escaped"
     . "control-string")))

(define (branch-names ls) (map car ls))

(define (missing-from ls names what)
  (let loop ((ns names) (ok #t))
    (if (null? ns)
        ok
        (loop (cdr ns)
              (and ok
                   (or (member (car ns) ls)
                       (begin (display "  ") (display what) (display ": ")
                              (display (car ns)) (newline)
                              #f)))))))

;; Both directions.  "Every expected branch is present" alone would pass
;; a fixture that also carried a branch nobody here knows about, which
;; is how an anchor gets added upstream and asserted nowhere.
;; Set membership BOTH ways, and then multiplicity.  Two membership
;; sweeps say nothing about how many times a name occurs: adding a
;; second, different `ratio/negative` anchor and bumping the declared
;; count passed both of them.  The JS suite compares the whole sorted
;; multiset and rejected it -- the asymmetry was the hole, as every
;; asymmetry between these two suites has been.
(define (no-repeats? ls what)
  (let loop ((xs ls) (ok #t))
    (if (null? xs)
        ok
        (loop (cdr xs)
              (and ok
                   (or (not (member (car xs) (cdr xs)))
                       (begin (display "  ") (display what)
                              (display " appears twice: ")
                              (display (car xs)) (newline)
                              #f)))))))

(define matrix-ok
  (and (missing-from seen-branches (branch-names expected-branches)
                     "branch missing from the fixture")
       (missing-from (branch-names expected-branches) seen-branches
                     "fixture has a branch this file does not pin")
       ;; ...and each branch carries the atom it is pinned with
       (let loop ((ps expected-branches) (ok #t))
         (if (null? ps)
             ok
             (let find ((i 0))
               (cond ((= i (sa-len))
                      (loop (cdr ps) ok))   ; absence is the sweep above
                     ((string=? (caar ps)
                                (string-append (sa-str "__saType" i) "/"
                                               (sa-str "__saBranch" i)))
                      (let ((got (sa-str "__saAtom" i)))
                        (unless (string=? got (cdar ps))
                          (display "  ") (display (caar ps))
                          (display " is pinned as ") (display (cdar ps))
                          (display " but carries ") (display got) (newline))
                        (loop (cdr ps) (and ok (string=? got (cdar ps))))))
                     (else (find (+ i 1)))))))
       (no-repeats? seen-branches "branch")
       ;; ...and on the list this file pins.  Only the observed side was
       ;; checked, so a name duplicated in the expectation passed while
       ;; the JS suite's sorted-multiset equality caught the same edit.
       (no-repeats? (branch-names expected-branches) "pinned branch")))


;; NOT HERE: a "these pairs must be different wires" check.  It was
;; here, and it never had a mutation of its own.  If two anchors denote
;; different data and carry one wire, that wire decodes to one of them
;; and the other fails the sweep above; if they denote the SAME datum
;; and carry one wire, they are a duplicate and fail the check below.
;; Both collapses were measured to stay red once it was removed.  A
;; check that cannot fail is not evidence, and leaving it in reads as
;; coverage that is not there.

;; A product can have degenerate cells: consing the empty list as a tail
;; gives back a proper list, so that cell would be an existing anchor
;; under a second name -- a row that looks like coverage and adds none.
;; The generator refuses to emit such a pair; this says so here too,
;; because a fixture can also be edited.
;; ---- the product is a PRODUCT, checked as one -----------------------
;; Every gap this matrix has had was a cell of a cross product that was
;; never filled, and every one was found by hand-running a sweep over
;; the fixture afterwards.  The last was introduced BY the edit that
;; fixed the one before it: a fifth position joined the atom product and
;; not the escaped-spelling cells, so `direction=read` existed at four
;; positions and not the fifth.
;;
;; So the sweep stops being something to remember.  Two dimension PAIRS,
;; asserted full -- and it has to be pairs: a per-dimension count sees
;; every atom and every position present and cannot see that two of them
;; never varied together.

(define (positions-of i)
  ;; top-level anchors carry no position column; they are their own row
  (let ((p (sa-str "__saPosition" i)))
    (if (string=? p "") "top" p)))

(define (values-of of keep?)
  (let loop ((i 0) (acc '()))
    (if (= i (sa-len))
        (reverse acc)
        (let ((v (of i)))
          (loop (+ i 1)
                (if (and (keep? i) (not (member v acc))) (cons v acc) acc))))))

(define (has-pair? a-of b-of a b keep?)
  (let loop ((i 0))
    (cond ((= i (sa-len)) #f)
          ((and (keep? i) (string=? (a-of i) a) (string=? (b-of i) b)) #t)
          (else (loop (+ i 1))))))

(define (product-full? name a-of b-of keep?)
  (let ((as (values-of a-of keep?)) (bs (values-of b-of keep?)))
    (let outer ((xs as) (ok #t))
      (if (null? xs)
          ok
          (let inner ((ys bs) (ok ok))
            (if (null? ys)
                (outer (cdr xs) ok)
                (let* ((have (has-pair? a-of b-of (car xs) (car ys) keep?))
                       ;; ...or a RECORDED hole.  Some cells of this
                       ;; product are not data the format has: a tail
                       ;; that is an empty or proper list collapses into
                       ;; the list itself.  The generator drops those
                       ;; and writes down which, with the reason, so an
                       ;; absent cell is either a fact about the format
                       ;; or a failure -- never a silence.
                       (excused (and (not have) (hole? (car xs) (car ys)))))
                  (unless (or have excused)
                    (display "  ") (display name)
                    (display ": no cell for ") (display (car xs))
                    (display " x ") (display (car ys)) (newline))
                  (inner (cdr ys) (and ok (or have excused))))))))))

;; A hole is excused only if its reason SAYS THE THING that makes it a
;; hole.  "Non-empty" was the whole test, so any non-empty sentence --
;; true or not -- excused a missing cell: the same gap that pinning only
;; the size of the well-formed corpus left, one section over.  The
;; substring below is the format identity the holes rest on; requiring
;; it means a reason cannot be replaced by a plausible-sounding one that
;; rests on nothing.
(define hole-reason-must-contain
  "a tail that is itself a list or a pair merges into the enclosing list")

(define (hole? atom position)
  (let loop ((i 0))
    (cond ((= i (js->number (call-js "__saHoleLen"))) #f)
          ((and (string=? atom (js->string (call-js "__saHoleAtom" i)))
                (string=? position (js->string (call-js "__saHolePosition" i)))
                (string-contains? (js->string (call-js "__saHoleReason" i))
                                  hole-reason-must-contain))
           #t)
          (else (loop (+ i 1))))))

(define (string-contains? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

;; nesting cells are the ones with a POSITION; every anchor now carries
;; an atom, so that column no longer distinguishes them
(define (nesting? i) (not (string=? (sa-str "__saPosition" i) "")))
(define (always? i) #t)

(define products-full
  (and loaded
       (product-full? "atom x position"
                      (lambda (i) (sa-str "__saAtom" i))
                      positions-of
                      nesting?)
       (product-full? "position x direction"
                      positions-of
                      (lambda (i) (sa-str "__saDir" i))
                      always?)))

(define anchors-are-distinct
  (and loaded
       (let outer ((i 0) (ok #t))
         (if (= i (sa-len))
             ok
             (let inner ((j (+ i 1)) (ok ok))
               (if (= j (sa-len))
                   (outer (+ i 1) ok)
                   ;; the VALUE each spec denotes, not the spec text:
                   ;; `Q 710 226` and `Q 355 113` are one datum spelled
                   ;; two ways, so text comparison lets a semantic
                   ;; duplicate through
                   (let* ((vi (spec->value (sa-str "__saSpec" i)))
                          (vj (spec->value (sa-str "__saSpec" j)))
                          (same (and (pair? vi) (pair? vj)
                                     (same-datum? (car vi) (car vj))
                                     (string=? (sa-str "__saWire" i)
                                               (sa-str "__saWire" j)))))
                     (when same
                       (display "  duplicate anchor: ")
                       (display (sa-str "__saBranch" i)) (display " and ")
                       (display (sa-str "__saBranch" j)) (newline))
                     (inner (+ j 1) (and ok (not same))))))))))

;; The escaped and raw spellings must ALSO describe the same value --
;; two different wires that decoded to two different things would
;; satisfy the check above without saying anything about escaping.
(define (branch-spec where)
  (let loop ((i 0))
    (cond ((= i (sa-len)) #f)
          ((string=? where (string-append (sa-str "__saType" i) "/"
                                          (sa-str "__saBranch" i)))
           (sa-str "__saSpec" i))
          (else (loop (+ i 1))))))

;; ...at every position, not only at top level.  The five nested
;; `control-string-<position>-escaped` cells are read-only spellings
;; whose whole point is that they denote the same value as the cell
;; beside them, and only the top-level pairs were tied together: a
;; nested escaped cell could have described a different value and the
;; "the writer does not emit this wire" check would have been satisfied
;; anyway.  Half a family again.
(define nested-spellings-agree
  (and loaded
       (let loop ((ps '("head-of-list" "in-list" "in-vector"
                        "as-tail" "deep"))
                  (ok #t))
         (if (null? ps)
             ok
             (let ((plain (branch-spec (string-append "nesting/control-string-"
                                                      (car ps))))
                   (esc (branch-spec (string-append "nesting/control-string-"
                                                    (car ps) "-escaped"))))
               (unless (and (string? plain) (string? esc))
                 (display "  missing a spelling at ") (display (car ps))
                 (newline))
               (loop (cdr ps)
                     (and ok (string? plain) (string? esc)
                          (let ((a (spec->value plain)) (b (spec->value esc)))
                            (and (pair? a) (pair? b)
                                 (same-datum? (car a) (car b)))))))))))

(define spellings-agree
  (and loaded
       (let loop ((cs '("newline" "tab" "return")) (ok #t))
         (if (null? cs)
             ok
             (let ((raw (branch-spec (string-append "string/control-"
                                                    (car cs) "-raw")))
                   (esc (branch-spec (string-append "string/control-"
                                                    (car cs) "-escaped"))))
               (loop (cdr cs)
                     (and ok (string? raw) (string? esc)
                          (let ((a (spec->value raw)) (b (spec->value esc)))
                            (and (pair? a) (pair? b)
                                 (same-datum? (car a) (car b)))))))))))

;; ---- verdict ----------------------------------------------------------

;; The fatal decoder is only evidence if something would notice it being
;; reverted, and the fixture is valid UTF-8 so every entry passes either
;; way.  The other two suites probe theirs; this one did not, which is
;; the kind of asymmetry every previous round turned into a hole.
(define (decoder-refuses? b64)
  (= 1 (js->number (call-js "__saDecodeProbe" (string->js b64)))))

(check "fixture present" fixture-present?)
(check "the fixture decoder refuses malformed UTF-8"
       (and (decoder-refuses? "Iv8i")            ; 22 ff 22 -- a lone #xff
            (not (decoder-refuses? "IuS4rSI="))))  ; 22 e4 b8 ad 22 -- valid CJK
(check "the spec reader reads specs" spec-reader-ok)
(when fixture-present?
  ;; the fixture states its own anchor count; if the array were
  ;; truncated in transit every sweep below would simply run over fewer
  ;; entries and still pass
  (check "anchor count matches the fixture's own record"
         (and (> (sa-len) 0) (= (sa-len) (sa-declared))))
  (check "every anchor decodes and re-encodes to the authority's bytes"
         anchors-ok)
  (check "the branch matrix is exactly what this file pins" matrix-ok)
  (check "the cross products are full in both dimensions" products-full)
  ;; The holes are pinned like the branches: a new one is a decision
  ;; about the format, not a number to update.
  (check "the product's holes are the three the format itself creates"
         (and (= 3 (js->number (call-js "__saHoleLen")))
              (hole? "empty-list" "as-tail")
              (hole? "proper-list" "as-tail")
              (hole? "dotted-pair" "as-tail")))
  ;; The corpus comes from the fixture, so its SIZE is pinned here and
  ;; the programs that were actual defects are named: a truncated list
  ;; would otherwise pass every line of it.
  (check "the shared spec corpus is the size it was"
         (and (= 32 (js->number (call-js "__saMalformedLen")))
              (= 23 (js->number (call-js "__saWellformedLen")))))
  (check "the corpus still names the programs that were real defects"
         ;; every member of an aliasing family, not just the first: the
         ;; P rule was fixed one level too shallow twice, and a corpus
         ;; naming only `P 1 N 1 NIL` lets the other two be swapped for
         ;; a duplicate while the size still matches
         (let loop ((want '("N Z" "L 1 Z" "S 1 255" "P 0 N 1" "L -1"
                            "P 1 N 1 NIL" "P 1 N 1 L 1 N 2"
                            "P 1 N 1 P 1 N 2 N 3"))
                    (ok #t))
           (if (null? want)
               ok
               (let find ((i 0))
                 (cond ((= i (js->number (call-js "__saMalformedLen")))
                        (display "  corpus no longer names: ")
                        (display (car want)) (newline)
                        (loop (cdr want) #f))
                       ((string=? (car want)
                                  (js->string (call-js "__saMalformed" i)))
                        (loop (cdr want) ok))
                       (else (find (+ i 1))))))))
  (check "every reader of the spec language refuses the same programs"
         (corpus-ok))
  ;; ...and no program appears twice, which is what let one be swapped
  ;; out for a duplicate while the size still matched.  BOTH halves --
  ;; this covered only the malformed one, while the report said "both
  ;; consumers reject corpus duplicates".  Half a family again.
  (check "no program appears twice in either half of the corpus"
         (and (no-duplicates? "__saMalformedLen" "__saMalformed")
              (no-duplicates? "__saWellformedLen" "__saWellformed")))
  ;; EVERY pair, not a chosen eight.  Two rounds of narrowing here:
  ;; first the corpus was pinned only by size (so a program could be
  ;; swapped for an equivalent one), then only by `why` (so a program
  ;; could be swapped while its claim stayed), and pinning eight of the
  ;; twenty-three left fifteen entries whose stated reason could be
  ;; replaced by a false one with nothing red.  The corpus is small and
  ;; the claims are the point, so all of it is stated here -- the same
  ;; treatment the branch matrix gets, and for the same reason: a new
  ;; claimed reader path should be a decision in both consumers, not a
  ;; number that drifts.
  (check "every program in the corpus still claims what it claims"
         (let loop ((want '(
                            ("N 42"
                             . "a plain numeral")
                            ("N -42"
                             . "a negative numeral")
                            ("N 0"
                             . "zero")
                            ("T"
                             . "true")
                            ("F"
                             . "false -- and the value #f is not the failure #f")
                            ("NIL"
                             . "the empty list")
                            ("Q 355 113"
                             . "a ratio already in lowest terms")
                            ("Q 1 -2"
                             . "the sign arriving on the DENOMINATOR")
                            ("Q -1 2"
                             . "the sign arriving on the NUMERATOR")
                            ("Q 2 4"
                             . "a ratio that needs reducing")
                            ("L 2 N 1 S 1 65"
                             . "a list of mixed kinds")
                            ("L 0"
                             . "the counted-list path at length zero")
                            ("P 1 N 1 N 2"
                             . "an improper list")
                            ("V 2 T NIL"
                             . "a vector of mixed kinds")
                            ("V 0"
                             . "the empty vector, which is not the empty list")
                            ("B 2 1 2"
                             . "a bytevector")
                            ("B 0"
                             . "the empty bytevector")
                            ("D 0 0 0 0 0 0 248 63"
                             . "a flonum from its bits")
                            ("D 0 0 0 0 0 0 0 128"
                             . "a NEGATIVE ZERO, whose sign no decimal carries")
                            ("S 0"
                             . "the empty string")
                            ("Y 2 111 107"
                             . "a symbol")
                            ("S 4 240 159 152 128"
                             . "a four-byte UTF-8 sequence")
                            ("S 3 97 10 98"
                             . "a control character inside a string")))
                    (ok #t))
           (if (null? want)
               ok
               (let find ((i 0))
                 (cond ((= i (js->number (call-js "__saWellformedLen")))
                        (display "  no entry pairs ")
                        (display (caar want)) (display " with ")
                        (display (cdar want)) (newline)
                        (loop (cdr want) #f))
                       ((and (string=? (caar want)
                                       (js->string (call-js "__saWellformed" i)))
                             (string=? (cdar want)
                                       (js->string (call-js "__saWellformedWhy" i))))
                        (loop (cdr want) ok))
                       (else (find (+ i 1))))))))
  (check "no anchor is another one under a second name" anchors-are-distinct)
  ;; The branch NAME is a claim about the payload, and pinning only its
  ;; `bytevector-pad0` label left that claim unchecked here -- the value
  ;; it names was wrong for a long time (38 distinct characters out of
  ;; 64) with everything green.  The generator refuses to emit a wrong
  ;; one; this is the consumer end of the same claim.
  (check "the whole-alphabet bytevector uses the whole alphabet"
         (let find ((i 0))
           (cond ((= i (sa-len)) #f)
                 ((string=? "whole-alphabet" (sa-str "__saBranch" i))
                  (string=? (sa-str "__saWire" i)
                            (string-append
                             "#vu8\""
                             "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                             "abcdefghijklmnopqrstuvwxyz0123456789+/"
                             "\"")))
                 (else (find (+ i 1))))))
  (check "both spellings of a control character mean the same value"
         spellings-agree)
  (check "...and at every nested position too" nested-spellings-agree))

(= fails 0)

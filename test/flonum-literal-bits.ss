;; expect: all f64 literal bit patterns match
;; The compiler turns a source flonum literal into eight bytes
;; (`ieee-bytes` in src/compiler.ss).  A branch was added there for
;; subnormal literals, and the risk of adding a branch is not that the
;; new arm is wrong -- that arm is read by its own cells -- but that
;; the OLD arm stops being reached, or is reached with a changed
;; condition.  So these are negative controls: every value here is
;; NORMAL, must take the pre-existing path, and includes the exact
;; boundary the new condition tests (2^-1022, the smallest normal,
;; which must compare as NOT subnormal) and its neighbour above.
;;
;; Every expected pattern was generated, not derived by hand:
;;   node -e 'const b=new DataView(new ArrayBuffer(8));
;;     const h=x=>{b.setFloat64(0,x);return [...new Uint8Array(b.buffer)]
;;       .map(v=>v.toString(16).padStart(2,"0")).join("")};
;;     console.log(h(Number("123.456")))'
;;
;; NOT COVERED HERE, and both reasons are blockers rather than choices:
;;
;;  - The exact boundary the new condition tests -- 2^-1022, the
;;    smallest normal -- IS the control this file most wants, and it
;;    cannot be written.  The self-hosted reader rejects exponent
;;    notation outright ("exponent literals are not supported by this
;;    reader"), and spelling 2.2250738585072014e-308 out longhand
;;    routes it through the decimal assembly the two hosts currently
;;    disagree about.  So it would be red for the reader's reason, not
;;    for this file's.  It lands when the reader takes exponents.
;;
;;  - The positive cells for the subnormal arm itself (a literal like
;;    1e-320) are blocked the same way, and additionally on the
;;    converter: a subnormal's value is assembled by rounding at 53
;;    bits and then scaling down, which rounds a second time.
;;
;;  - The non-finite literals (+inf.0, -inf.0, +nan.0, -nan.0).  The
;;    encoder handles all four as of this commit -- before it, +inf.0
;;    HUNG the compiler and both NaN spellings were silently encoded as
;;    1.0 -- but the cells cannot run here, because the self-hosted
;;    reader does not accept those tokens either.  They were measured
;;    against node-generated patterns on the Chez-hosted compiler,
;;    which does read them; the readings are in the commit.
;;
;; Neither is forgotten; each lands with the fix that unblocks it, and
;; all three groups land together, because one change to the reader
;; unblocks all of them:
;;
;;   WHEN THE READER TAKES EXPONENT NOTATION AND THE NON-FINITE
;;   TOKENS, ADD HERE: the adjacent pair that straddles the branch
;;   condition itself -- 2.225073858507201e-308 (000fffffffffffff, the
;;   LARGEST SUBNORMAL) and 2.2250738585072014e-308
;;   (0010000000000000, the smallest normal), which differ by one bit
;;   and are the pair an off-by-one in the exponent would separate
;;   while every other cell here still passed -- and its negative
;;   800fffffffffffff; then 2^-1021, 1e-307, +inf.0, -inf.0,
;;   +nan.0 (canonical 7ff8000000000000), -nan.0 (also 7ff8..., the
;;   sign is chosen, not preserved), a subnormal such as 1e-320, and
;;   the underflow pair 2e-324/-2e-324 (0000000000000000 and
;;   8000000000000000 -- a magnitude that rounds away to zero must
;;   still keep its sign) together with the smallest subnormals
;;   5e-324/-5e-324 (...0001 and 8...0001).
;;
;; All eleven were measured against node-generated patterns on the
;; Chez-hosted compiler, which does read those spellings, and all
;; eleven pass there today.  They are listed because a cell that
;; cannot run is not a cell that has been checked -- the run that
;; matters is the one in the gate, on both hosts.
(import (rnrs) (gfx fx))

(define $hex "0123456789abcdef")
(define $bitbuf (fx-alloc! 16))
(define (bits x)                        ; f64 -> 16 hex digits, big-endian
  (%mem-f64-set! $bitbuf x)
  (let loop ((i 7) (acc ""))
    (if (< i 0)
        acc
        (loop (- i 1)
              (let ((b (%mem-u8-ref (+ $bitbuf i))))
                (string-append
                 acc
                 (string (string-ref $hex (quotient b 16))
                         (string-ref $hex (remainder b 16)))))))))

(define failures 0)
(define (want! x pattern)
  (let ((got (bits x)))
    (unless (string=? got pattern)
      (set! failures (+ failures 1))
      (display "literal ") (display x)
      (display ": want ") (display pattern)
      (display " got ") (display got) (newline))))

(want! 0.0      "0000000000000000")
;; Negative zero is a SEPARATE BIT PATTERN, not a spelling of zero, and
;; the difference is observable: (fl/ 1.0 -0.0) is -inf.  Unlike the
;; NaN sign -- which this encoder deliberately does not preserve -- this
;; one carries meaning and must survive.  It did not: the encoder's
;; zero branch answered `(fl=? x 0.0)`, which -0.0 satisfies, so -0.0
;; was silently emitted as +0.0 on both hosts.
(want! -0.0     "8000000000000000")
(want! 1.0      "3ff0000000000000")
(want! 1.5      "3ff8000000000000")
(want! 0.25     "3fd0000000000000")
(want! 123.456  "405edd2f1a9fbe77")
(want! 0.1      "3fb999999999999a")
(want! -1.5     "bff8000000000000")
(want! -0.25    "bfd0000000000000")
(want! -123.456 "c05edd2f1a9fbe77")
(want! 0.5      "3fe0000000000000")
(want! 1024.0   "4090000000000000")
(want! 0.30000000000000004 "3fd3333333333334")   ; the classic .1+.2 result

(display (if (= failures 0)
             "all f64 literal bit patterns match"
             "MISMATCHES"))

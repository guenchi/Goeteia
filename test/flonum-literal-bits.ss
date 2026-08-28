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
;; WHAT IS AND IS NOT COVERED
;;
;; This file once carried a list of cells it could not run: the reader
;; had no exponent notation and no +inf.0 / +nan.0 spellings, so the
;; boundary values this encoder most needs checking at could not be
;; WRITTEN.  They can now, and they are below -- the promotion is the
;; point of keeping such a list rather than a vague note.
;;
;; One blocker is left, and it is not this encoder's:
;;
;;   A decimal in the subnormal range whose value needs many mantissa
;;   bits is converted by rounding at 53 bits and then scaling down,
;;   which rounds a second time.  1e-317 is the witness -- the
;;   Chez-hosted host reads it as ...1ee257 and the self-hosted one
;;   produces ...1ee256, one low -- and it is the conversion that is
;;   wrong, not the reader or the encoder.  Subnormals needing FEW
;;   bits are fine and are cells below (1e-320, 3e-320, 5e-324), which
;;   is why "subnormals are blocked" would have been the wrong summary.
;;
;; NaN gets TWO cells, because two different things are worth holding
;; and one cell cannot hold both:
;;   - a SPEC cell: it is a NaN at all (exponent field all ones,
;;     mantissa non-zero).  What the format requires, and it must not
;;     be tightened into a bit pattern or an implementation choice
;;     gets recorded as though it were a guarantee.
;;   - a POLICY cell: exactly 7ff8000000000000.  Not a spec cell.  It
;;     pins the choice src/compiler.ss states -- canonical quiet NaN,
;;     sign and payload chosen rather than preserved -- so changing
;;     the policy means changing this cell in the same commit, which
;;     is the point of it.
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

;; ---- the boundary values, now that they can be written ------------
;; The adjacent pair that straddles the encoder's own branch condition:
;; these two differ by ONE BIT, and an off-by-one in the exponent would
;; separate them while every other cell in this file still passed.
(want! 2.225073858507201e-308  "000fffffffffffff")  ; largest subnormal
(want! 2.2250738585072014e-308 "0010000000000000")  ; smallest normal
(want! -2.225073858507201e-308 "800fffffffffffff")
(want! 4.450147717014403e-308  "0020000000000000")  ; 2^-1021
(want! 1e-307                  "0031fa182c40c60d")
(want! 1e308                   "7fe1ccf385ebc8a0")

;; Subnormals the converter handles exactly: few mantissa bits needed.
(want! 1e-320  "00000000000007e8")
(want! 3e-320  "00000000000017b8")
(want! 5e-324  "0000000000000001")   ; the smallest positive subnormal
(want! -5e-324 "8000000000000001")
;; and the underflow pair -- a magnitude that rounds away to zero must
;; still keep its sign
(want! 2e-324  "0000000000000000")
(want! -2e-324 "8000000000000000")

;; ---- the non-finite literals ---------------------------------------
;; Before the encoder had these branches, +inf.0 HUNG the compiler and
;; both NaN spellings were silently encoded as 1.0.
(want! +inf.0 "7ff0000000000000")
(want! -inf.0 "fff0000000000000")
;; the SPEC cell: a NaN at all, asked without naming a pattern
(let ((n +nan.0))
  (unless (and (flonum? n) (not (fl=? n n)))
    (set! failures (+ failures 1))
    (display "literal +nan.0 is not a NaN") (newline)))
(let ((n -nan.0))
  (unless (and (flonum? n) (not (fl=? n n)))
    (set! failures (+ failures 1))
    (display "literal -nan.0 is not a NaN") (newline)))
;; the POLICY cells: exactly the canonical quiet NaN, both spellings
(want! +nan.0 "7ff8000000000000")
(want! -nan.0 "7ff8000000000000")

(display (if (= failures 0)
             "all f64 literal bit patterns match"
             "MISMATCHES"))

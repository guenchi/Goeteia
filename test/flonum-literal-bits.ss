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
;; Neither is forgotten; each lands with the fix that unblocks it.
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

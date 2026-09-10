;; expect: #t
;; G12 and G13 (2026-09-06 review, still live): the deflate and zstd
;; decoders read past the length they were given, and zstd believes a
;; frame header it never checks.
;;
;; RED ON PURPOSE.  Same family as G11 (meshopt, fixed) and G10 (UASTC,
;; fixed): a length is carried and not enforced.  In linear memory
;; that is not a crash -- the bytes past the end are the next buffer's,
;; so what comes out is real data mixed with somebody else's, from a
;; file off the network.
;;
;; Each red has its control beside it, because a decoder that refused
;; everything would satisfy every refusal here.  The controls are the
;; smallest inputs each decoder is supposed to accept.
;;
;; This pair is also where a prediction gets tested.  The two bounds
;; already written differ by format: UASTC's requirement is a function
;; of the dimensions, so one up-front check settles it; meshopt's stream
;; is variable-length and self-describing, so it needs a per-byte
;; window.  deflate and zstd are variable-length too, so they are
;; predicted to want meshopt's shape rather than UASTC's.  If the fix
;; turns out to be a single up-front check, that prediction is wrong and
;; the family does not split the way it was said to.
(import (rnrs) (gfx image) (gfx zstd))

(define SRC 8192)
(define DST 16384)
(define DST2 32768)
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (load! base bs)
  (let put ((b bs) (i 0))
    (when (pair? b) (%mem-u8-set! (+ base i) (car b)) (put (cdr b) (+ i 1)))))

;; ---- G12: raw DEFLATE ----
;; `(3 0)` is a complete empty stored block; `(3)` is that block's first
;; byte and nothing else.
(load! SRC '(3 0))
(check "G12-CONTROL: a complete empty deflate stream decodes"
       (not (refuses? (lambda () (inflate! SRC 2 DST 16)))))
(load! SRC '(3 0))
(check "G12-TRUNCATED: the same stream one byte short is refused"
       (refuses? (lambda () (inflate! SRC 1 DST 16))))
(load! SRC '(3 0))
(check "G12-EMPTY: a source length of zero is refused"
       (refuses? (lambda () (inflate! SRC 0 DST 16))))

;; ---- G13: zstd frame header ----
;; A minimal frame: magic, a descriptor byte, one raw block.  The three
;; rejects each flip one bit of the descriptor that the decoder does not
;; look at.
(define zstd-ok '(40 181 47 253 32 1 9 0 0 65))
(define (zstd-case bs) (load! SRC bs)
  (lambda () (zstd-decode! SRC (length bs) DST2 1024 16 16)))
(check "G13-CONTROL: a well-formed minimal frame decodes"
       (not (refuses? (zstd-case zstd-ok))))
;; the descriptor says a checksum follows, and none does
(check "G13-CHECKSUM: a frame promising a checksum it does not carry is refused"
       (refuses? (zstd-case '(40 181 47 253 36 1 9 0 0 65))))
;; the descriptor's content-size field disagrees with the frame
(check "G13-CONTENT-LENGTH: a declared content size that is not the frame's is refused"
       (refuses? (zstd-case '(40 181 47 253 32 2 9 0 0 65))))
;; the reserved bit is set, which the spec says must be zero
(check "G13-RESERVED: the reserved descriptor bit set is refused"
       (refuses? (zstd-case '(40 181 47 253 40 1 9 0 0 65))))
;; and the same source truncated
(check "G13-TRUNCATED: a frame one byte short is refused"
       (refuses? (lambda () (load! SRC zstd-ok)
                            (zstd-decode! SRC (- (length zstd-ok) 1) DST2 1024 16 16))))
(display (= failed 0))

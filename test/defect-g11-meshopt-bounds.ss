;; expect: #t
;; G11 (2026-09-06 review; written as a red witness at 7e333ab, green
;; since): the meshopt decoders read past the length their caller gave
;; them.
;;
;; REGRESSION GUARD.  Every entry point takes `slen`, the number of bytes
;; the caller has, and none of them treats it as a bound: a one-byte
;; source is accepted and decoded, which means the bytes that were
;; decoded came from whatever happened to be after it.
;;
;; In linear memory that is not a crash.  Reading past the end of a
;; buffer returns the next buffer's contents, so the failure is silent
;; and the result is plausible -- a mesh made of somebody else's data.
;; The observable is not "it trapped" but "it RETURNED, from an input
;; that cannot possibly contain a mesh".
;;
;; The data these decoders read is a file off the network.  A length
;; that is carried but not enforced is the shape where a malformed asset
;; stops being a rendering problem.
;;
;; KNOWN LIMITATION, recorded so nobody later tries to close it: a
;; slen that is too LARGE is not detectable here.  The format allows
;; slack between the data and the tail, so a caller who reports more
;; bytes than the stream really has is indistinguishable from one whose
;; stream simply has more slack.  The bound below is about the data not
;; fitting, which is a different and checkable thing.
;;
;; Reported location: lib/gfx/meshopt.ss (the three entry points).
(import (rnrs) (gfx meshopt))

(define SRC 8192)
(define DST 16384)
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
;; `guard` cannot catch a wasm trap, so a decoder that walked off the
;; end of memory would kill this file rather than fail a cell.  That is
;; a worse red than a FAIL line but it is still a red, and the file's
;; header says where to look.  What is being asked for here is a named
;; refusal, which IS a condition.
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (load! base bs)
  (let put ((b bs) (i 0))
    (when (pair? b) (%mem-u8-set! (+ base i) (car b)) (put (cdr b) (+ i 1)))))

;; A valid-looking header and nothing else.  0xA0 is the vertex magic,
;; 0xE0 the index magic, so each decoder gets past its first check and
;; then has no data at all.
(load! SRC '(160))
(check "G11-VERTEX: one byte of source is refused, not decoded"
       (refuses? (lambda () (meshopt-vertex! SRC 1 DST 24 4))))
(load! SRC '(224))
(check "G11-INDEX: one byte of source is refused"
       (refuses? (lambda () (meshopt-index! SRC 1 DST 24 2))))
(load! SRC '(0))
(check "G11-SEQUENCE: one byte of source is refused"
       (refuses? (lambda () (meshopt-index-sequence! SRC 1 DST 24 2))))

;; Zero bytes is the same question without even a header to read.
(check "G11-EMPTY: a source length of zero is refused by all three"
       (and (refuses? (lambda () (meshopt-vertex! SRC 0 DST 1 4)))
            (refuses? (lambda () (meshopt-index! SRC 0 DST 3 2)))
            (refuses? (lambda () (meshopt-index-sequence! SRC 0 DST 3 2)))))

;; And the twin, which matters as much: a decoder that refused
;; everything would pass every line above.  These are the real streams
;; the suite already decodes, at their real lengths, and they must go on
;; working -- so the bound has to be a bound and not a rejection.
(define ok-comp
  '(160 5 0 0 192 0 254 192 192 0 0 4 254 5 0 192 0 192 253 254 192 192 0 0
    253 253 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 127 0))
(define (llen l) (let c ((x l) (n 0)) (if (null? x) n (c (cdr x) (+ n 1)))))
(load! SRC ok-comp)
(check "G11-TWIN: a complete stream at its real length still decodes"
       (not (refuses? (lambda () (meshopt-vertex! SRC (llen ok-comp) DST 24 4)))))
;; The bound, from BOTH sides.  The first version of this cell asked
;; for "one byte short is refused" and was wrong -- not too weak, wrong.
;;
;; Slack is normal in this format: this sixty-byte stream's data ends at
;; offset 28 and its tail sits at 56, so twenty-eight bytes in the
;; middle are spare, and the canonical stream in test/meshopt.ss has
;; twenty-four spare the same way.  A length one byte short therefore
;; still contains every byte the decoder reads; what shrank was the
;; slack.  -> It is not a truncated stream, it is a length reported one
;; too large -- and this format carries nothing that could tell the
;; difference.  A rule that demanded the data reach the tail exactly
;; would refuse the suite's own known-good stream, which was measured
;; rather than supposed.
;;
;; So the cell asks where the bound actually is.  28 bytes of data plus
;; a 4-byte tail is 32, and the decoder refuses at 31 and decodes at 32
;; -- measured across the whole range, on all three targets.  Both
;; halves are needed: without the 32, a decoder that refused everything
;; short of the full sixty would pass; without the 31, one with no bound
;; at all would.
(load! SRC ok-comp)
(check "G11-BOUND: 31 bytes cannot hold the data and the tail, and are refused"
       (refuses? (lambda () (meshopt-vertex! SRC 31 DST 24 4))))
(load! SRC ok-comp)
(check "G11-BOUND: 32 bytes exactly can, and still decode"
       (not (refuses? (lambda () (meshopt-vertex! SRC 32 DST 24 4)))))
(display (= failed 0))

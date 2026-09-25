;; expect: #t
;; linear->srgb and srgb->linear, the CPU half of (gfx srgb).
;;
;; The glTF loader encodes a base colour factor on the CPU before the
;; shader decodes it on the GPU, so the two halves must agree: the CPU
;; curve here is the same curve as encode_srgb and decode_srgb, linear
;; near black and a 2.4 power above.  The runtime binds no expt, exp or
;; log, so the power is computed privately from square roots; these rows
;; hold it to the curve.
;;
;; Every expected value was computed in double precision from the sRGB
;; definition before the functions existed.  The tolerance is 1e-9.
;; Measured 2026-09-25 against the host's Math.pow at 10001 points in
;; [0,1], on both back ends, the largest error was about 2e-15 (encode),
;; 2e-15 (decode) and 5e-15 (round trip).  1e-9 is far finer than any
;; colour use needs -- an 8-bit level is about 4e-3, and a 32-bit float
;; upload keeps about 6e-8 -- and looser than the measured error by six
;; orders, so these rows do not promise full double precision.
(import (rnrs) (gfx srgb))

(define fails '())
(define (near name got want)
  (unless (and (real? got) (< (abs (- got want)) 1e-9))
    (set! fails (cons (list name 'got got 'want want) fails))))

;; encoding: the linear segment, the threshold, the curve, the ends
(near "encode 0" (linear->srgb 0.0) 0.0)
;; The row that tells this curve from the plain power law the tree used
;; before: that law gives 0.0754 here, which no tolerance below 0.05 could
;; confuse with 0.0258.
(near "encode 0.002, on the linear segment" (linear->srgb 0.002) 0.025840000000000002)
(near "encode the threshold" (linear->srgb 0.0031308) 0.040449936)
(near "encode 0.01, just above it" (linear->srgb 0.01) 0.09985282273412832)
(near "encode 0.18, middle grey" (linear->srgb 0.18) 0.46135612950044164)
(near "encode 0.5" (linear->srgb 0.5) 0.7353569830524495)
(near "encode 0.9" (linear->srgb 0.9) 0.9546871718858662)
(near "encode 1" (linear->srgb 1.0) 1.0)
(near "encode a negative value as 0, as encode_srgb does" (linear->srgb -0.5) 0.0)

;; decoding
(near "decode 0" (srgb->linear 0.0) 0.0)
(near "decode 0.02, on the linear segment" (srgb->linear 0.02) 0.0015479876160990713)
(near "decode the threshold" (srgb->linear 0.04045) 0.0031308049535603713)
(near "decode 0.1" (srgb->linear 0.1) 0.010022825574869039)
(near "decode 0.5" (srgb->linear 0.5) 0.21404114048223255)
(near "decode 1" (srgb->linear 1.0) 1.0)

;; Outside [0,1], the same answers the GLSL pair gives: encoding above one
;; continues the curve, decoding a negative value follows the straight
;; segment, decoding above one continues the power.
(near "encode 2, above the range" (linear->srgb 2.0) 1.3532560461493863)
(near "decode -0.02, a negative value" (srgb->linear -0.02) -0.0015479876160990713)
(near "decode 1.5, above the range" (srgb->linear 1.5) 2.537155239391517)

;; exact inputs are accepted, as the rest of the library accepts them
(near "encode an exact 1/2" (linear->srgb 1/2) 0.7353569830524495)

;; The round trip, at a thousand and one points.  Each half above could
;; be right at the listed points and wrong between them; this is where
;; the two halves are held to each other.  It COUNTS the points that are
;; not within tolerance rather than tracking the worst error, because a
;; NaN compares false with everything and a running maximum would keep
;; the last finite value and pass.
(let loop ((i 0) (bad '()))
  (if (<= i 1000)
      (let* ((x (/ i 1000.0)) (e (abs (- (srgb->linear (linear->srgb x)) x))))
        (loop (+ i 1) (if (< e 1e-9) bad (cons x bad))))
      (unless (null? bad)
        (set! fails (cons (list "round trip over [0,1]" 'bad-at (reverse bad)) fails)))))

(display (if (null? fails) #t (reverse fails)))

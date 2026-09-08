;; expect: #t
;; (sim random): a generator whose state the caller holds.
;;
;; A simulation that can be replayed needs its randomness to come from a
;; seed it wrote down, not from the host.  The framework had none, so a
;; consumer wrote one against the fixnum range and ended up with a
;; modulus of 65537 -- a period of 65536 draws, which one particle
;; system exhausts in a few seconds, after which the "random" numbers
;; repeat exactly.  This library exists so nobody has to make that
;; trade against arithmetic they did not choose.
;;
;; What is pinned here is behaviour, not an algorithm: the same seed
;; gives the same sequence, two generators do not touch each other,
;; ranges are respected and never exceeded, and the sequence does not
;; come back around inside the span this test walks.  The golden vector
;; that pins the algorithm itself is a separate cell, added once the
;; algorithm is documented and re-derived independently from that
;; document, so it checks the implementation rather than quoting it.
(import (rnrs) (sim random))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))

(define (draws r n)
  (let loop ((i 0) (out '()))
    (if (= i n) (reverse out) (loop (+ i 1) (cons (random-integer! r 1000000) out)))))

;; ---- the same seed replays ----
(check "one seed, one sequence"
       (equal? (draws (make-rng 12345) 50) (draws (make-rng 12345) 50)))
(check "different seeds, different sequences"
       (not (equal? (draws (make-rng 12345) 50) (draws (make-rng 12346) 50))))

;; ---- two generators are independent ----
(check "advancing one generator does not move another"
       (let ((a (make-rng 7)) (b (make-rng 7)))
         (draws a 20)                            ; a runs ahead
         (equal? (draws b 10) (draws (make-rng 7) 10))))

;; ---- ranges hold ----
(check "an integer draw stays inside its bound"
       (let ((r (make-rng 99)))
         (let loop ((i 0))
           (or (= i 2000)
               (let ((v (random-integer! r 10)))
                 (and (integer? v) (>= v 0) (< v 10) (loop (+ i 1))))))))
(check "a real draw stays in [0,1)"
       (let ((r (make-rng 5)))
         (let loop ((i 0))
           (or (= i 2000)
               (let ((v (random-real! r)))
                 (and (>= v 0.0) (< v 1.0) (loop (+ i 1))))))))
(check "a range draw stays between its ends"
       (let ((r (make-rng 3)))
         (let loop ((i 0))
           (or (= i 2000)
               (let ((v (random-range! r -2.5 4.0)))
                 (and (>= v -2.5) (< v 4.0) (loop (+ i 1))))))))
(check "a bound of one always answers zero"
       (let ((r (make-rng 1)))
         (let loop ((i 0)) (or (= i 100) (and (= 0 (random-integer! r 1)) (loop (+ i 1)))))))

;; ---- every bucket gets hits ----
;; A generator whose low bits are stuck, or whose modulus is small, fails
;; this without failing anything above it.
(check "ten buckets all see draws over ten thousand"
       (let ((r (make-rng 2026)) (hits (make-vector 10 0)))
         (let loop ((i 0))
           (when (< i 10000)
             (let ((b (random-integer! r 10)))
               (vector-set! hits b (+ 1 (vector-ref hits b))))
             (loop (+ i 1))))
         (let scan ((i 0))
           (or (= i 10)
               (and (> (vector-ref hits i) 700) (< (vector-ref hits i) 1300)
                    (scan (+ i 1)))))))

;; ---- the sequence does not come back around here ----
;; The consumer's generator repeated after 65536 draws: the same numbers
;; in the same order, forever.  Asking "did any pair of draws ever
;; recur" would not catch that and would fail a good generator anyway --
;; from a finite alphabet, repeats are expected, and with a hundred
;; thousand draws they are close to certain.  A repeat is not the
;; question; a REPLAY is.
;;
;; So this remembers the opening run, walks past the period that broke
;; the generator this library replaces, and requires the sequence not to
;; start over.  A generator with a period of 65536 reproduces the
;; opening run exactly at that offset and fails here; one with a long
;; period disagrees almost everywhere.
(check "the sequence does not start over after sixty-five thousand draws"
       (let* ((r (make-rng 4242))
              (opening (let loop ((i 0) (out '()))
                         (if (= i 200) (reverse out)
                             (loop (+ i 1) (cons (random-integer! r 1000000) out))))))
         ;; The comparison has to land exactly 65536 draws after the
         ;; opening, not 65536 after the end of it: a generator whose
         ;; period divides 65536 repeats at that offset and nowhere near
         ;; it.  Two hundred were already drawn, so 65336 more.
         (let skip ((i 0)) (when (< i 65336) (random-integer! r 1000000) (skip (+ i 1))))
         (let compare ((l opening) (same 0) (n 0))
           (if (null? l)
               (< same 20)                    ; a replay would match all two hundred
               (let ((v (random-integer! r 1000000)))
                 (compare (cdr l) (if (= v (car l)) (+ same 1) same) (+ n 1)))))))

;; ---- refusals ----
(check "a seed that is not a fixnum is refused"
       (refused? 'make-rng (lambda () (make-rng "seed"))))
(check "a bound that is not positive is refused"
       (and (refused? 'random-integer! (lambda () (random-integer! (make-rng 1) 0)))
            (refused? 'random-integer! (lambda () (random-integer! (make-rng 1) -3)))))
(check "an empty range is refused"
       (refused? 'random-range! (lambda () (random-range! (make-rng 1) 2.0 2.0))))

(display (= failed 0))
(newline)

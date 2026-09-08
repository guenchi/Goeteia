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

;; Randomness a replay can reproduce, out of arithmetic that is exact.
;;
;; A simulation that can be replayed needs its draws to come from a seed
;; someone wrote down, not from the host.  Nothing here reads a clock,
;; a device or a global: the whole state is one integer the caller
;; holds, so two generators never interfere and a run is repeated by
;; repeating its seed.
;;
;; The algorithm is the Lehmer generator standardised as MINSTD:
;;
;;     s <- 48271 * s  mod  2147483647
;;
;; on states s in [1, 2147483646], with the modulus 2^31-1 prime and 48271
;; a primitive root of it.  Both facts matter and neither is decorative:
;; primality is why no state can drift into a shorter orbit, and a
;; primitive root is why the orbit is all of the non-zero residues.  The
;; period is therefore exactly 2147483646, and the sequence visits every
;; state once before any of them comes back.
;;
;; Why this one, rather than a generator with a wider state: it needs no
;; bitwise operation at all.  Bitwise operators here work on i31-tagged
;; fixnums and trap at 2^29 (docs/limits.md), while `*` and `mod` stay
;; exact without bound -- the intermediate 48271 * s reaches 2^47 and the
;; product inside an integer draw reaches 2^60, both exact.  A generator
;; written against the fixnum range instead of against the arithmetic
;; ends up with a modulus that fits in a fixnum, and a period short
;; enough for one particle system to walk in seconds; that failure is
;; what this library exists to remove from callers.
;;
;; What it is not: this is not a cryptographic generator.  Two successive
;; draws determine the state, so any third party who sees output can
;; predict the rest.  It is for simulation, sampling and content
;; generation, and nothing that keeps a secret.
;;
;; Reimplementing it from this description alone: state is one integer in
;; [1, 2147483646]; a seed becomes the state 1 + (seed mod 2147483646),
;; after which three draws are discarded so that seeds one apart do not
;; open with neighbouring values; each draw advances the state once, and
;; the drawn quantity is derived from the NEW state s as
;;
;;     integer in [0,n)  ->  floor((s - 1) * n / 2147483646)
;;     real in [0,1)     ->  (s - 1) / 2147483646  in binary64
;;
;; using the high end of the state rather than its low bits, since the
;; low bits of a Lehmer generator are the weakest part of it.
(library (sim random)
  (export make-rng random-integer! random-real! random-range!)
  (import (rnrs))

  (define $modulus 2147483647)          ; 2^31 - 1, prime
  (define $multiplier 48271)            ; a primitive root of $modulus
  (define $span 2147483646)             ; $modulus - 1: the count of states

  ;; #(rng state); tagged so that a value that is not a generator is
  ;; refused by name rather than by a vector-ref into a stranger.
  (define ($rng? r)
    (and (vector? r) (= (vector-length r) 2) (eq? (vector-ref r 0) 'rng)))

  (define ($need-rng who r)
    (unless ($rng? r) (error who "not a generator" r)))

  ;; One step of the recurrence, answering the state it moved to.  Every
  ;; drawn value comes from exactly one step, so a caller counting draws
  ;; is counting state transitions.
  (define ($step! r)
    (let ((s (mod (* $multiplier (vector-ref r 1)) $modulus)))
      (vector-set! r 1 s)
      s))

  ;; A seed is folded into the state space rather than checked against
  ;; it, so that every fixnum is a usable seed, including a negative one:
  ;; `mod` by a positive divisor is non-negative, and the +1 keeps the
  ;; state off zero, which is the one residue this recurrence cannot
  ;; leave.  The three discarded draws matter more than they look: the
  ;; recurrence is linear, so two seeds one apart open with states one
  ;; apart and their first draws would differ by a step's worth of the
  ;; range instead of by all of it.  Three steps multiply that difference
  ;; by 48271^3 mod 2147483647 and spread it across the whole span.
  (define (make-rng seed)
    (unless (fixnum? seed) (error 'make-rng "seed must be a fixnum" seed))
    (let ((r (vector 'rng (+ 1 (mod seed $span)))))
      ($step! r)
      ($step! r)
      ($step! r)
      r))

  ;; The state minus one is uniform on [0, $span - 1]; scaling it by n
  ;; and dividing by $span lands in [0, n-1] without ever reaching n,
  ;; because the largest numerator is ($span - 1) * n < $span * n.  The
  ;; multiplication is exact at any n this accepts, so nothing is lost
  ;; before the division rounds down.  The residual bias is the one every
  ;; scaled generator has, at most n / $span in relative terms, which for
  ;; a bound a simulation would use is far below the sampling noise of
  ;; the draws themselves.
  (define (random-integer! r n)
    ($need-rng 'random-integer! r)
    (unless (and (fixnum? n) (> n 0))
      (error 'random-integer! "bound must be a positive fixnum" n))
    (div (* (- ($step! r) 1) n) $span))

  ;; Exact until the last operation: the numerator is an integer below
  ;; 2^31 and so is the denominator, both exactly representable in
  ;; binary64, and their quotient is correctly rounded.  The largest
  ;; possible result is ($span - 1) / $span, which rounds to a double
  ;; strictly below 1.0, so the half-open promise holds at the top end
  ;; and not only in the limit.
  (define (random-real! r)
    ($need-rng 'random-real! r)
    (/ (exact->inexact (- ($step! r) 1)) (exact->inexact $span)))

  ;; The ends are coerced before they are compared, because that is the
  ;; comparison the arithmetic below actually performs: two exact ends
  ;; that differ can land on the same double, and a range that is empty
  ;; in the precision it will be computed in is refused rather than
  ;; silently answered with its own upper end.
  ;;
  ;; The final guard is not redundant with the guarantee on random-real!.
  ;; u < 1 makes (h - l) * u < (h - l), but adding l back can round up to
  ;; h whenever l is large enough that h - l falls below the spacing of
  ;; doubles near l.  Answering l there keeps the interval half-open,
  ;; which is the promise callers scissor and index against; the
  ;; alternative is a value equal to h, and a caller who indexes an array
  ;; with it reads past the end.
  (define (random-range! r lo hi)
    ($need-rng 'random-range! r)
    (unless (real? lo) (error 'random-range! "lower end must be a real number" lo))
    (unless (real? hi) (error 'random-range! "upper end must be a real number" hi))
    (let ((l (exact->inexact lo)) (h (exact->inexact hi)))
      (unless (< l h)
        (error 'random-range! "the range must be non-empty" lo hi))
      (let ((v (+ l (* (- h l) (random-real! r)))))
        (if (< v h) v l)))))

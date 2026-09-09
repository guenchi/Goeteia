;; expect: #t
;; (gam effects): named states that end by themselves.
;;
;; Shipped, documented, and until now imported by no test -- the same
;; hole as (gam abilities), found the same way, and worth saying twice:
;; ⚠️ an API index that lists every export is a complete index and not
;; a line of coverage.
;;
;; Three decisions in this library are decisions rather than
;; consequences, and each one has another answer a reasonable person
;; would have picked.  Those are the cells that matter:
;;
;;   SET-REPLACES   setting a running name again REPLACES the duration.
;;                  It does not refresh-to-the-longer and it does not
;;                  add.  All three are rules a game can want and they
;;                  feel different to a player.
;;   TICK-ORDER     subtract, then drop what has run out -- so an effect
;;                  with exactly dt left is gone after that tick, not
;;                  one tick later.  Reaching zero IS running out.
;;   ORDER-STABLE   the listing order is maintained, not computed.  Two
;;                  compiler targets agree byte for byte here, which is
;;                  a tested property of this tree, and an order that
;;                  came out of a hash table would break it invisibly.
(import (rnrs) (gam effects))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; ---- what it is ----
(check "MAKE: a fresh set is empty"
       (let ((f (make-effects)))
         (and (null? (effects-names f))
              (not (effect-active? f 'slow))
              (not (effect-ref f 'slow)))))

;; ⭐ #f rather than 0 for a name that is not running.  Zero is a
;; duration this library never stores, so answering it would put a real
;; value and an absence into one answer -- and a caller writing
;; (if (> (effect-ref f 'slow) 0) ...) would then be right by accident
;; until the day it is handed the absence.
(check "ABSENT: a name that is not running answers #f, not zero"
       (eq? #f (effect-ref (make-effects) 'slow)))

;; ---- SET-REPLACES ----
(check "SET-REPLACES: setting a running name again replaces its duration"
       (let ((f (make-effects)))
         (effect-set! f 'slow 10.0)
         (effect-set! f 'slow 2.0)
         (= 2.0 (effect-ref f 'slow))))
(check "SET-REPLACES: it does not take the longer of the two"
       (let ((f (make-effects)))
         (effect-set! f 'slow 2.0)
         (effect-set! f 'slow 10.0)
         (effect-set! f 'slow 3.0)
         (= 3.0 (effect-ref f 'slow))))
(check "SET-REPLACES: nor does it add them"
       (let ((f (make-effects)))
         (effect-set! f 'slow 2.0)
         (effect-set! f 'slow 3.0)
         (= 3.0 (effect-ref f 'slow))))
(check "SET-REPLACES: and a replaced name is still one effect, not two"
       (let ((f (make-effects)))
         (effect-set! f 'slow 2.0)
         (effect-set! f 'slow 3.0)
         (equal? '(slow) (effects-names f))))

;; ---- TICK-ORDER ----
;; ⭐ Exactly-dt-left is the discriminating case.  Dropping first and
;; subtracting after, or treating zero as still running, both leave an
;; effect alive for one extra tick -- a difference no cell with a
;; comfortable margin can see, and one a player feels as a state that
;; outlives its bar.
(check "TICK-ORDER: an effect with exactly dt left is gone after that tick"
       (let ((f (make-effects)))
         (effect-set! f 'slow 1.0)
         (effects-tick! f 1.0)
         (and (not (effect-active? f 'slow))
              (null? (effects-names f)))))
(check "TICK-ORDER: with a hair more than dt it survives"
       (let ((f (make-effects)))
         (effect-set! f 'slow 1.001)
         (effects-tick! f 1.0)
         (effect-active? f 'slow)))
(check "TICK-ORDER: overshooting removes it rather than leaving a negative"
       (let ((f (make-effects)))
         (effect-set! f 'slow 1.0)
         (effects-tick! f 100.0)
         (and (not (effect-active? f 'slow)) (eq? #f (effect-ref f 'slow)))))
(check "TICK-ORDER: a tick of zero changes nothing and removes nothing"
       (let ((f (make-effects)))
         (effect-set! f 'slow 1.0)
         (effects-tick! f 0.0)
         (and (effect-active? f 'slow) (= 1.0 (effect-ref f 'slow)))))
(check "TICK-ORDER: each effect is counted down on its own clock"
       (let ((f (make-effects)))
         (effect-set! f 'slow 1.0)
         (effect-set! f 'hidden 5.0)
         (effects-tick! f 1.0)
         (and (not (effect-active? f 'slow))
              (effect-active? f 'hidden)
              (= 4.0 (effect-ref f 'hidden)))))

;; ---- ORDER-STABLE ----
;; The rule has two halves and they differ: a name refreshed while it is
;; still running keeps its place, because it is the same effect; a name
;; that ran out and was set again is a new one and goes at the end.
;; ⚠️ With only the first half, "always keep the first position ever
;; seen" passes; with only the second, "always append" passes.
(check "ORDER-STABLE: names come back in the order they were first set"
       (let ((f (make-effects)))
         (effect-set! f 'a 5.0) (effect-set! f 'b 5.0) (effect-set! f 'c 5.0)
         (equal? '(a b c) (effects-names f))))
(check "ORDER-STABLE: a refresh keeps its place -- it is the same effect"
       (let ((f (make-effects)))
         (effect-set! f 'a 5.0) (effect-set! f 'b 5.0) (effect-set! f 'c 5.0)
         (effect-set! f 'a 9.0)
         (equal? '(a b c) (effects-names f))))
(check "ORDER-STABLE: one that ran out and came back is a new one, and goes last"
       (let ((f (make-effects)))
         (effect-set! f 'a 1.0) (effect-set! f 'b 5.0) (effect-set! f 'c 5.0)
         (effects-tick! f 1.0)                ; a runs out
         (effect-set! f 'a 5.0)
         (equal? '(b c a) (effects-names f))))
(check "ORDER-STABLE: removals do not disturb the survivors' order"
       (let ((f (make-effects)))
         (effect-set! f 'a 5.0) (effect-set! f 'b 1.0) (effect-set! f 'c 5.0)
         (effects-tick! f 1.0)
         (equal? '(a c) (effects-names f))))
(check "CLEAR: clearing empties it and leaves it usable"
       (let ((f (make-effects)))
         (effect-set! f 'a 5.0)
         (effects-clear! f)
         (and (null? (effects-names f))
              (begin (effect-set! f 'b 5.0) (equal? '(b) (effects-names f))))))

;; ---- what it refuses ----
;; ⭐ A name has to be something eq? is dependable on across BOTH
;; compiler targets.  A string would be accepted by a looser check and
;; then never match itself on lookup -- an effect that is set, reported
;; as not running, and never expires.  The refusal is what turns that
;; into a message at the call site.
(check "REFUSE: names eq? cannot be trusted on are refused"
       (let ((f (make-effects)))
         (and (refuses? (lambda () (effect-set! f "slow" 1.0)))
              (refuses? (lambda () (effect-set! f 1.5 1.0)))
              (refuses? (lambda () (effect-set! f '(a) 1.0)))
              (refuses? (lambda () (effect-ref f "slow")))
              (refuses? (lambda () (effect-active? f "slow"))))))
(check "REFUSE: but symbols, characters, booleans and fixnums are all fine"
       (let ((f (make-effects)))
         (effect-set! f 'sym 1.0)
         (effect-set! f #\c 1.0)
         (effect-set! f #t 1.0)
         (effect-set! f 42 1.0)
         (and (= 4 (length (effects-names f)))
              (= 1.0 (effect-ref f #\c))
              (= 1.0 (effect-ref f #t))
              (= 1.0 (effect-ref f 42)))))
;; ⭐ A duration of zero is refused rather than treated as already over:
;; an effect set and instantly gone is never observable between two
;; ticks, so a caller asking for one has computed it wrongly and would
;; never see why.  ⚠️ The green twin is the smallest positive duration a
;; caller would really write -- a tightening that demanded "at least one
;; frame" would take it away.
(check "REFUSE: a duration of zero or less is refused"
       (let ((f (make-effects)))
         (and (refuses? (lambda () (effect-set! f 'a 0)))
              (refuses? (lambda () (effect-set! f 'a 0.0)))
              (refuses? (lambda () (effect-set! f 'a -1.0))))))
(check "REFUSE: but a very short positive duration is accepted"
       (let ((f (make-effects)))
         (effect-set! f 'a 0.0001)
         (effect-active? f 'a)))
(check "REFUSE: time that runs backwards is refused"
       (refuses? (lambda () (effects-tick! (make-effects) -0.5))))
(check "REFUSE: every entry point refuses something that is not an effects value"
       (and (refuses? (lambda () (effect-set! 7 'a 1.0)))
            (refuses? (lambda () (effect-ref 7 'a)))
            (refuses? (lambda () (effect-active? 7 'a)))
            (refuses? (lambda () (effects-tick! 7 1.0)))
            (refuses? (lambda () (effects-clear! 7)))
            (refuses? (lambda () (effects-names 7)))))

;; ---- the boundary the library's comment claims ----
;; It knows nothing about pools, abilities, or anything it might gate.
;; What that buys is that a duration is just a number: an effect can be
;; set from any clock, in any unit, and two effects can share a name
;; space with anything else the caller keeps.  Nothing here to assert
;; beyond the exactness that carries through, which is the one way a
;; library can silently impose a unit on its caller.
(check "BOUNDARY: exact durations stay exact"
       (let ((f (make-effects)))
         (effect-set! f 'a 5)
         (effects-tick! f 2)
         (and (= 3 (effect-ref f 'a)) (exact? (effect-ref f 'a)))))
(display (= failed 0))

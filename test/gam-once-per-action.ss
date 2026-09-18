;; expect: #t
;; A set of the things one action has already affected.
;;
;; WHAT IT IS FOR.  A sword swing is sampled every frame for the length
;; of the swing, a beam pulses while it is held, a piercing shot crosses
;; several bodies -- and in each the same target must be affected once,
;; not once per sample.  The shape is: an episode with a lifetime, read
;; repeatedly, where each object gets at most one turn.
;;
;; IDENTITY, NOT EQUALITY.  Two actors with identical contents are two
;; actors.  eq? is a reference comparison in this runtime and is exactly
;; the right test; what this runtime has no way to do is HASH by
;; identity -- no address, no serial, no object hash, no weak reference
;; (docs/limits.md) -- so a hashtable keyed by an actor degenerates to a
;; linear scan with the worst possible constant.  A list and memq is the
;; same complexity honestly, and an action touches few things.
;;
;; (gam window) ALREADY HAS THIS SHAPE, and it is named here so nobody
;; takes this library for the first of its kind.  window-mark! answers
;; and records in one call for the same stated reason.  Two things keep
;; this from being that: window-marked? compares by equal?, and two
;; actors with identical contents are two actors -- the a-twin row below
;; is the row window-mark! would fail; and a window is a timed thing,
;; with a duration to step and a span to report, while a piercing shot
;; that crosses three bodies in one frame has no clock to attach a
;; ledger to.  Neither is a reason to give window an eq? mode: a library
;; whose comparison changes with a flag is a part whose meaning depends
;; on where it is used.
;;
;; once-first! EXISTS SO THE TWO-STEP CANNOT BE WRITTEN WRONG.  The
;; obvious API is seen? then mark!, and the obvious defect is a caller
;; that tests and forgets to mark -- which is the defect this whole
;; structure is against, reintroduced one level up.  once-first! answers
;; and records in one call, so the caller's shape is
;;   (when (once-first! hits target) ...)
;; and there is nothing to forget.  seen? is still here for a caller
;; that wants to ask without taking the turn.
(import (rnrs) (gam once))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (refused? who thunk)
  (guard (e (#t (eq? (condition-who e) who))) (thunk) #f))

(define a (vector 'actor 1))
(define b (vector 'actor 2))
;; Structurally identical to a, and a DIFFERENT actor.  This row is what
;; separates identity from equality: an implementation built on member
;; and equal? passes every other row in this cell and fails this one.
(define a-twin (vector 'actor 1))

(let ((s (make-once)))
  (want "a fresh set is one" (once? s) #t)
  (want "and has affected nothing" (once-count s) 0)
  (want "nothing has been seen" (once-seen? s a) #f)

  (want "the first turn is granted" (once-first! s a) #t)
  (want "and is recorded" (once-seen? s a) #t)
  (want "the second is refused" (once-first! s a) #f)
  (want "and refusing does not add a second entry" (once-count s) 1)

  ;; IDENTITY: a-twin is equal? to a and is not a.
  (want "an equal but distinct object has not been seen" (once-seen? s a-twin) #f)
  (want "and gets its own turn" (once-first! s a-twin) #t)
  (want "so the set holds two" (once-count s) 2)

  (want "another object is independent" (once-first! s b) #t)
  (want "and the set holds three" (once-count s) 3)

  ;; seen? must not take the turn.
  (let ((c (vector 'actor 3)))
    (want "asking does not record" (once-seen? s c) #f)
    (want "asking again still does not" (once-seen? s c) #f)
    (want "and the count is unmoved" (once-count s) 3)
    (want "so the turn is still available" (once-first! s c) #t))

  ;; reset! starts the next pulse.
  (once-reset! s)
  (want "a reset set has affected nothing" (once-count s) 0)
  (want "and forgets what it saw" (once-seen? s a) #f)
  (want "so the turn comes round again" (once-first! s a) #t))

;; Two sets do not share.
(let ((s (make-once)) (t (make-once)))
  (once-first! s a)
  (want "one set's record is not another's" (once-seen? t a) #f)
  (want "and the counts are separate" (list (once-count s) (once-count t)) '(1 0)))

;; The type check, in both directions.
(want "a vector of the right width is not a set" (once? (vector 'gam-once '())) #f)
(want "nor is a list" (once? '()) #f)
(want "operations on a non-set are refused" (refused? 'once-first! (lambda () (once-first! (vector 1 2) a))) #t)
(want "seen? too" (refused? 'once-seen? (lambda () (once-seen? '() a))) #t)
(want "reset! too" (refused? 'once-reset! (lambda () (once-reset! 7))) #t)
(want "count too" (refused? 'once-count (lambda () (once-count "s"))) #t)

(display (if (null? fails) #t fails))

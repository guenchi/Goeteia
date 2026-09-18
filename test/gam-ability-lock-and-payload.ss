;; expect: #t
;; Two additions to (gam abilities), from a consumer that had written its
;; own parallel library and is being asked to migrate to this one.
;;
;; ability-lock! EXTENDS the remaining time and never shortens it.  That
;; is the whole of it, and the direction is the part worth pinning: a
;; global cooldown or a silence is longer than the ability's own
;; cooldown, so locking has to be able to exceed it, while a lock for
;; less than what is already owed must leave the longer wait alone.
;;
;; ability-payload is storage the library never reads.  Only the
;; cooldown is acted on here -- tick! and use! move the remaining time
;; and ready? reads it.  The cost is NOT: ready? never looks at it and
;; use! never spends it, as this library's own comment says.  So cost is
;; already a carried field with a slot of its own, kept because every
;; caller compares it against a resource; payload is the general form of
;; the same thing, for whatever else an ability has to carry.  It is here so a caller's damage, range,
;; animation clip or status effect travels with the ability instead of
;; living in a second table keyed by id, and the library stays silent
;; about which of those a game has.
(import (rnrs) (gam abilities))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (refused? who thunk)
  (guard (e (#t (eq? (condition-who e) who))) (thunk) #f))

;; ---- ability-lock! ----
(let ((a (make-ability 'strike 0 10)))
  (want "a fresh ability owes nothing" (ability-remaining a) 0)
  (ability-lock! a 4)
  (want "locking sets the remaining time" (ability-remaining a) 4)
  (want "and a locked ability is not ready" (ability-ready? a) #f)
  ;; THE DIRECTION.  A shorter lock must not shorten the longer wait
  ;; already owed -- that is the difference between "lock for at least"
  ;; and "set to".
  (ability-lock! a 1)
  (want "a shorter lock leaves the longer wait alone" (ability-remaining a) 4)
  (ability-lock! a 7)
  (want "a longer lock extends it" (ability-remaining a) 7)
  ;; It may exceed the ability's own cooldown: that is the case it
  ;; exists for.
  (ability-lock! a 25)
  (want "a lock may exceed the cooldown" (ability-remaining a) 25)
  (want "the cooldown itself is unchanged" (ability-cooldown a) 10)
  ;; Zero is a legal lock and a no-op, unlike a zero cooldown, because
  ;; here it is an elapsed-time argument rather than a configuration.
  (ability-lock! a 0)
  (want "locking for zero changes nothing" (ability-remaining a) 25)
  ;; And it composes with the clock rather than replacing it.
  (ability-tick! a 25)
  (want "ticking still clears a lock" (ability-remaining a) 0)
  (want "and the ability is ready again" (ability-ready? a) #t))

;; A refused lock must change nothing, the same contract ability-use!
;; keeps: a caller can branch on the error without first checking.
(let ((a (make-ability 'strike 0 10)))
  (ability-lock! a 3)
  (want "a negative lock is refused" (refused? 'ability-lock! (lambda () (ability-lock! a -1))) #t)
  (want "and leaves the remaining time alone" (ability-remaining a) 3)
  (want "a non-real lock is refused" (refused? 'ability-lock! (lambda () (ability-lock! a 'soon))) #t)
  ;; NaN is a real that is not negative, so a check written as
  ;; (not (< x 0)) lets it through and the lock becomes a silent no-op.
  (want "a NaN lock is refused" (refused? 'ability-lock! (lambda () (ability-lock! a +nan.0))) #t)
  (want "and it too leaves the remaining time alone" (ability-remaining a) 3)
  (want "a lock on a non-ability is refused" (refused? 'ability-lock! (lambda () (ability-lock! (vector 1 2 3) 1))) #t))

;; ---- payload ----
(let ((a (make-ability 'heal 5 3)))
  (want "an ability made without one carries #f" (ability-payload a) #f))
(let* ((p (list 'damage 12 'range 4.5))
       (a (make-ability 'bolt 5 3 p)))
  (want "the payload is handed back" (ability-payload a) p)
  (want "and is the same object, not a copy" (eq? (ability-payload a) p) #t)
  (want "adding one does not disturb the cost" (ability-cost a) 5)
  (want "or the cooldown" (ability-cooldown a) 3)
  (want "or readiness" (ability-ready? a) #t)
  (ability-use! a)
  (want "or the cooldown the use starts" (ability-remaining a) 3)
  (want "and the payload survives a use" (ability-payload a) p))
;; A caller storing #f is indistinguishable from one storing nothing.
;; That is stated rather than worked around: no operation here depends
;; on the difference, so inventing a sentinel would add a value the
;; library would then have to keep out of the caller's reach.
(want "a payload of #f reads back as #f" (ability-payload (make-ability 'x 0 1 #f)) #f)
;; A fifth argument is a caller that thinks there are two payload slots,
;; or that damage and range are separate parameters; accepting and
;; dropping it would answer that mistake with silence.
(want "a fifth argument is refused" (refused? 'make-ability (lambda () (make-ability 'x 0 1 'p 'q))) #t)

;; ---- the type check must have moved with the shape ----
;; The record grew a slot.  ability? tests the length, so a check left
;; at the old width would refuse every ability this library makes --
;; and one widened without being tested would accept a vector that is
;; merely the right size.
(want "an ability this library made is one" (ability? (make-ability 'a 0 1)) #t)
(want "one made with a payload is too" (ability? (make-ability 'a 0 1 'p)) #t)
(want "a bare vector of the same width is not" (ability? (vector 1 2 3 4 5 6 7)) #f)

(if (null? fails) #t fails)

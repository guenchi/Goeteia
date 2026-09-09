;; expect: #t
;; (gam abilities): whether an action may be taken again yet.
;;
;; This library shipped, was written up in docs/api.md, and until now no
;; test imported it -- the api-index check was green throughout, because
;; it asks whether an exported name has an entry, not whether the name
;; does the right thing.  ⚠️ A complete index reads like coverage and is
;; not coverage.
;;
;; Every cell names the plausible-but-wrong implementation it excludes.
;; The two worth reading first are USE-REFUSED and EXACTNESS: both are
;; wrong in ways that keep working for a long time.
(import (rnrs) (gam abilities))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; ---- what it is ----
(check "MAKE: a fresh ability is one, and carries what it was given"
       (let ((a (make-ability 'blink 3 2.0)))
         (and (ability? a)
              (eq? 'blink (ability-id a))
              (= 3 (ability-cost a))
              (= 2.0 (ability-cooldown a)))))
(check "MAKE: and it is ready immediately -- nothing has been used yet"
       (ability-ready? (make-ability 'blink 3 2.0)))
;; The predicate has to look at BOTH the tag and the length: with only
;; the tag, any vector beginning with that symbol passes and the
;; accessors read past the end; with only the length, every six-element
;; vector in the program is an ability.  ⭐ Each half is checked by the
;; case the other half would let through.
;;
;; ⓘ And the honest third line: a vector with the right tag AND the
;; right length IS an ability.  The representation is a plain vector and
;; the library says so; forging one is the caller's business, not a hole
;; to be plugged.  ⚠️ This cell was first written claiming otherwise and
;; went red -- the claim was mine, not the library's.
(check "MAKE: the predicate checks the tag"
       (not (ability? (vector 'not-an-ability 'x 1 2 0 0))))
(check "MAKE: and the length"
       (and (not (ability? (vector 'gam-ability 'x 1 2 0)))
            (not (ability? (vector 'gam-ability 'x 1 2 0 0 0)))))
(check "MAKE: neither alone -- both together are what it is"
       (ability? (vector 'gam-ability 'x 1 2 0 0)))

;; ---- USE-REFUSED ----
;; ⭐ The cell this file exists for.  A use that is refused must leave
;; the cooldown counting down from where it was.  An implementation that
;; sets the cooldown whether or not the use succeeded passes every cell
;; about readiness -- the ability is not ready either way -- and turns a
;; player mashing a key into an ability that never comes back.  ⛔ It is
;; invisible to anyone who only tests the successful path.
(check "USE-REFUSED: a refused use does not restart the cooldown"
       (let ((a (make-ability 'blink 0 10.0)))
         (ability-use! a)                  ; now 10 left
         (ability-tick! a 6.0)             ; 4 left
         (let ((before (ability-remaining a)))
           (and (not (ability-use! a))     ; refused
                (= before (ability-remaining a))))))
(check "USE-REFUSED: and repeated refusals still let it come back on time"
       (let ((a (make-ability 'blink 0 10.0)))
         (ability-use! a)
         (ability-tick! a 6.0)
         (ability-use! a) (ability-use! a) (ability-use! a)
         (ability-tick! a 4.0)
         (ability-ready? a)))
(check "USE: a successful use answers true and takes it out of readiness"
       (let ((a (make-ability 'blink 0 10.0)))
         (and (ability-use! a)
              (not (ability-ready? a))
              (= 10.0 (ability-remaining a)))))

;; ---- the clamp, and the readiness test that depends on it ----
;; ability-ready? asks whether remaining is at zero, not whether it is
;; at or below zero -- which is only right because tick! clamps.  The
;; two are one decision written in two places, so a cell that pins only
;; one of them leaves the pair free to drift apart.
(check "TICK-CLAMP: ticking far past the end leaves exactly zero, not a negative"
       (let ((a (make-ability 'blink 0 2.0)))
         (ability-use! a)
         (ability-tick! a 100.0)
         (and (= 0.0 (ability-remaining a)) (ability-ready? a))))
(check "TICK-CLAMP: and the boundary tick, exactly the cooldown, is enough"
       (let ((a (make-ability 'blink 0 2.0)))
         (ability-use! a)
         (ability-tick! a 2.0)
         (ability-ready? a)))
(check "TICK-CLAMP: one instant short of it is not"
       (let ((a (make-ability 'blink 0 2.0)))
         (ability-use! a)
         (ability-tick! a 1.999)
         (not (ability-ready? a))))

;; ---- EXACTNESS ----
;; ⭐ The zero an ability reports is its cooldown's own zero.  An
;; implementation with a literal 0 in it is right about readiness and
;; wrong about the value: a game keeping its clock in flonums gets an
;; exact 0 back from one accessor and flonums from every other, and the
;; mixed arithmetic that follows is a bug nobody looks for at the place
;; it is caused.  ⛔ `=` cannot see this; `exact?` can.
(check "EXACTNESS: a flonum cooldown reports a flonum remaining, at zero too"
       (let ((a (make-ability 'blink 0 2.0)))
         (ability-use! a)
         (ability-tick! a 5.0)
         (and (= 0 (ability-remaining a))
              (not (exact? (ability-remaining a))))))
(check "EXACTNESS: an exact cooldown stays exact, at zero too"
       (let ((a (make-ability 'blink 0 2)))
         (and (exact? (ability-remaining a))
              (begin (ability-use! a)
                     (ability-tick! a 5)
                     (and (= 0 (ability-remaining a))
                          (exact? (ability-remaining a)))))))
(check "EXACTNESS: a fresh ability's remaining already has the right exactness"
       (and (not (exact? (ability-remaining (make-ability 'b 0 2.0))))
            (exact? (ability-remaining (make-ability 'b 0 2)))))

;; ---- what it refuses, and what it must NOT refuse ----
;; A cooldown of zero is refused; a cost of zero is not.  ⭐ The
;; asymmetry is the decision, so both halves need a cell: with only the
;; refusal, an edit that tightened cost the same way would pass.
(check "REFUSE: a cooldown of zero or less is refused"
       (and (refuses? (lambda () (make-ability 'x 1 0)))
            (refuses? (lambda () (make-ability 'x 1 0.0)))
            (refuses? (lambda () (make-ability 'x 1 -1.0)))))
(check "REFUSE: but a cost of zero is fine -- free and rate-limited is ordinary"
       (ability? (make-ability 'x 0 1.0)))
(check "REFUSE: a negative cost is refused"
       (refuses? (lambda () (make-ability 'x -1 1.0))))
(check "REFUSE: time that runs backwards is refused"
       (refuses? (lambda () (ability-tick! (make-ability 'x 0 1.0) -0.5))))
(check "REFUSE: but a tick of zero is fine -- a frame in which no time passed"
       (let ((a (make-ability 'x 0 4.0)))
         (ability-use! a)
         (ability-tick! a 0.0)
         (= 4.0 (ability-remaining a))))
(check "REFUSE: every accessor refuses something that is not an ability, by name"
       (and (refuses? (lambda () (ability-id 7)))
            (refuses? (lambda () (ability-cost 7)))
            (refuses? (lambda () (ability-cooldown 7)))
            (refuses? (lambda () (ability-remaining 7)))
            (refuses? (lambda () (ability-ready? 7)))
            (refuses? (lambda () (ability-tick! 7 1.0)))
            (refuses? (lambda () (ability-use! 7)))))

;; ---- the boundary the library's comment claims ----
;; It carries the cost and does not spend it.  ⭐ Pinning this is what
;; keeps the next person from "helpfully" making use! subtract from
;; something: the moment it does, an ability can only ever be paid for
;; out of one kind of thing, and two-resource or free abilities stop
;; fitting.  The cost is a number that survives use unchanged.
(check "BOUNDARY: using an ability does not spend its cost"
       (let ((a (make-ability 'blink 3 1.0)))
         (ability-use! a)
         (= 3 (ability-cost a))))
(check "BOUNDARY: nor does the cost change with the cooldown"
       (let ((a (make-ability 'blink 3 1.0)))
         (ability-use! a)
         (ability-tick! a 0.5)
         (and (= 3 (ability-cost a)) (= 1.0 (ability-cooldown a)))))
(display (= failed 0))

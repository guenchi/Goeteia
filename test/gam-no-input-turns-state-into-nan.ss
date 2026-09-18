;; expect: #t
;; THE INVARIANT: no input from outside can make a (gam ...) library's
;; observable state NaN.
;;
;; WHY AN INVARIANT AND NOT A LIST OF SITES.  The sites are what a sweep
;; finds; the invariant is what the sweep was FOR.  A cell with one row
;; per guarded argument is complete against the sites that existed when
;; it was written, and says nothing when an eighth is added -- and a
;; family with one member unguarded is the arrangement that makes the
;; next reader assume the sweep was done.  This walks each library's
;; setters and reads every getter back, so a setter added later falls
;; inside its reach without anyone remembering to extend a list.
;;
;; THE PATTERN DOES NOT IDENTIFY THE DEFECT, which is the part that
;; makes a textual sweep unsafe.  Three sites outside (gam ...) --
;; web/css.ss and collide.ss:252 -- are written the same way and are not
;; the same defect, because each has (integer? x) ahead of it in the
;; conjunction and (integer? +nan.0) is #f.  The defect is the shape
;; WITH NOTHING AHEAD OF IT THAT EXCLUDES NaN, which is a property of
;; the surrounding conjunction rather than of the comparison.  Only a
;; behavioural check can tell those apart.
;;
;; TWO ROUTES IN, and the second is why the first sweep was not enough.
;; The guards written (not (< x 0)) admit NaN because NaN is a real that
;; is not less than zero.  The guards written (real? x) with no ordering
;; constraint -- because the value may legitimately be negative --
;; admit it by a shorter road: NaN never has to pass an ordering test at
;; all.  An exclusion that is correct about its own line can still sit
;; downstream of an open door: stats.ss's spend guard compares two
;; quantities that ought to be valid, and is right to, while stat-set!
;; upstream lets NaN into one of them.
;;
;; MEASURED, and the direction is what makes it worth an invariant: a
;; NaN pool does not make spending fail, it makes spending SUCCEED.
;; stats-spend! guards with (not (< value amount)), which against NaN is
;; (not #f), so the spend is allowed -- and $clamp leaves the pool at
;; NaN, so it is allowed again, and again.  A pool that refuses to pay
;; gets reported; one that pays without limit and never goes down does
;; not.
(import (rnrs) (gam stats) (gam fields) (gam modifiers) (gam abilities)
        (gam window) (gam timeline) (gam effects) (gam recovery))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
;; NaN is the one real that is not equal to itself.
(define (nan? x) (and (real? x) (not (= x x))))
(define (try thunk) (guard (e (#t 'refused)) (thunk) 'accepted))
;; Feed NaN to one setter, then read every getter of that library back.
;; The library may refuse or may absorb it; what it may not do is answer
;; NaN from any reader afterwards.
;; EACH ROW GETS A FRESH OBJECT.  Written first as one object reused
;; down the list, and that was wrong in a way that reads like a result:
;; the first setter that got NaN through left it in the state, so every
;; later row reported NaN too and named the WRONG setter.  A row must
;; fail for what it did, not for what the row above it did.
(define (no-nan-after label make setter readers)
  (let ((o (make)))
    (try (lambda () (setter o)))
    (for-each
     (lambda (r)
       (let ((v (guard (e (#t 'raised)) (r o))))
         (when (nan? v) (set! fails (cons (list label 'reader-answered v) fails)))))
     readers)))

;; ---- the predicate itself, first: a cell that cannot see NaN reports
;; ---- nothing, and every row below would then pass in silence.
(want "nan? sees NaN" (nan? +nan.0) #t)
(want "nan? does not see zero" (nan? 0.0) #f)
(want "nan? does not see infinity" (nan? +inf.0) #f)
(want "nan? does not see a fixnum" (nan? 7) #f)

;; ---- stats
(define (fresh-stats) (make-stats '((hp 100 5))))
(define stats-readers
  (list (lambda (s) (stat s 'hp)) (lambda (s) (stat-max s 'hp))
        (lambda (s) (stats-level s)) (lambda (s) (stats-xp s))))
(for-each
 (lambda (row) (no-nan-after (car row) fresh-stats (cdr row) stats-readers))
 (list (cons 'stat-set! (lambda (s) (stat-set! s 'hp +nan.0)))
       (cons 'stat-add! (lambda (s) (stat-add! s 'hp +nan.0)))
       (cons 'stats-damage! (lambda (s) (stats-damage! s 'hp +nan.0)))
       (cons 'stats-heal! (lambda (s) (stats-heal! s 'hp +nan.0)))
       (cons 'stats-regenerate! (lambda (s) (stats-regenerate! s +nan.0)))
       (cons 'stats-spend! (lambda (s) (stats-spend! s 'hp +nan.0)))
       (cons 'stats-gain-xp! (lambda (s) (stats-gain-xp! s +nan.0)))))
;; AND THE CONSEQUENCE, because a pool left at NaN is not merely an odd
;; reading: it is a guard that passes.  Spending must not succeed
;; without the pool going down.
(let ((s (fresh-stats)))
  (try (lambda () (stat-set! s 'hp +nan.0)))
  (let ((before (stat s 'hp)))
    (stats-spend! s 'hp 1)
    (want "spending moves the pool or refuses"
          (or (not (equal? (stat s 'hp) before)) (nan? before)) #t)))

;; ---- fields: the constructor and the one reader that takes a point
(for-each
 (lambda (row)
   (want (list 'make-field 'refuses (car row))
         (try (lambda () (apply make-field (cdr row)))) 'refused))
 (list (list 'x      'circle +nan.0 0.0 5.0 0.0 0.0 2.0 1.0 0.5)
       (list 'z      'circle 0.0 +nan.0 5.0 0.0 0.0 2.0 1.0 0.5)
       (list 'yaw    'circle 0.0 0.0 5.0 0.0 +nan.0 2.0 1.0 0.5)
       (list 'rate   'circle 0.0 0.0 5.0 0.0 0.0 2.0 +nan.0 0.5)))
(define (fresh-field) (make-field 'circle 0.0 0.0 5.0 0.0 0.0 2.0 1.0 0.5))
(no-nan-after 'field-step! fresh-field
              (lambda (f) (field-step! f +nan.0 (lambda (fd owed) 'x)))
              (list (lambda (f) (field-x f)) (lambda (f) (field-z f))
                    (lambda (f) (field-yaw f)) (lambda (f) (field-rate f))
                    (lambda (f) (field-life f)) (lambda (f) (field-radius f))))
(want "field-contains? refuses a NaN x"
      (try (lambda () (field-contains? (fresh-field) +nan.0 0.0))) 'refused)
;; BOTH COORDINATES GET A ROW.  The guard names x and z separately, so a
;; single row leaves half of it with nothing behind it -- and the half
;; without a row is the one a later edit can drop in silence.
(want "field-contains? refuses a NaN z"
      (try (lambda () (field-contains? (fresh-field) 0.0 +nan.0))) 'refused)
;; CONTROL: refusing every position would satisfy both rows above.
(want "an ordinary point inside still answers yes"
      (field-contains? (fresh-field) 0.0 0.0) #t)
(want "an ordinary point outside still answers no"
      (field-contains? (fresh-field) 100.0 0.0) #f)

;; ---- modifiers
(define mod-readers (list (lambda (m) (modifier-ref m 'atk))))
(no-nan-after 'modifier-set! make-modifiers
              (lambda (m) (modifier-set! m 'buff 'atk +nan.0 2.0 #f #t)) mod-readers)
(no-nan-after 'modifier-tick!
              (lambda () (let ((m (make-modifiers)))
                           (modifier-set! m 'ok 'atk 10 2.0 #f #t) m))
              (lambda (m) (modifier-tick! m +nan.0)) mod-readers)

;; ---- abilities
(define (fresh-ability) (make-ability 'x 0 10.0))
(define ability-readers
  (list (lambda (a) (ability-remaining a)) (lambda (a) (ability-cooldown a))
        (lambda (a) (ability-cost a))))
(no-nan-after 'ability-tick! fresh-ability (lambda (a) (ability-tick! a +nan.0)) ability-readers)
(no-nan-after 'ability-lock! fresh-ability (lambda (a) (ability-lock! a +nan.0)) ability-readers)
(want "make-ability refuses a NaN cost" (try (lambda () (make-ability 'y +nan.0 1.0))) 'refused)
(want "make-ability refuses a NaN cooldown" (try (lambda () (make-ability 'y 0 +nan.0))) 'refused)

;; ---- window: live? and done? are meant to be exclusive, and a NaN
;; ---- time makes both true, so the invariant is stated as that pair.
(define (fresh-window) (make-window 1.0 0.2 0.8))
(no-nan-after 'window-step! fresh-window (lambda (w) (window-step! w +nan.0))
              (list (lambda (w) (window-time w)) (lambda (w) (window-duration w))
                    (lambda (w) (window-from w)) (lambda (w) (window-to w))))
(let ((w (fresh-window)))
  (try (lambda () (window-step! w +nan.0)))
  (want "live? and done? are not both true"
        (and (window-live? w) (window-done? w)) #f)
  (want "make-window refuses a NaN duration" (try (lambda () (make-window +nan.0 0.2 0.8))) 'refused)
  (want "make-window refuses a NaN from" (try (lambda () (make-window 1.0 +nan.0 0.8))) 'refused)
  (want "make-window refuses a NaN to" (try (lambda () (make-window 1.0 0.2 +nan.0))) 'refused))

;; ---- timeline: a dropped entry is invisible, so the reading is
;; ---- whether a scheduled action still happens.
;; timeline-tick! ANSWERS what has come due; it does not call it.  The
;; first version of this control asserted a side effect -- schedule a
;; lambda that increments a counter, tick past it, expect the counter at
;; one -- and that row was red on a pristine master and stayed red after
;; the repair, because the payload is handed back rather than invoked
;; and the counter never moves whatever the library does about NaN.
;;
;; A RED NEEDS ITS SOURCE VERIFIED EXACTLY AS A GREEN DOES.  That row
;; did not point at the wrong defect; it pointed at one that does not
;; exist, and the obvious next move on seeing it would have been to hunt
;; through a correct repair for an error that was never there.
(let ((tl (make-timeline)) (payload (lambda () 'ran)))
  (want "timeline-schedule! refuses a NaN delay"
        (try (lambda () (timeline-schedule! tl +nan.0 payload))) 'refused)
  (want "timeline-tick! refuses NaN" (try (lambda () (timeline-tick! tl +nan.0))) 'refused)
  (timeline-schedule! tl 1.0 payload)
  (want "an ordinary schedule is answered when it comes due"
        (timeline-tick! tl 2.0) (list payload))
  (want "and the timeline empties" (timeline-empty? tl) #t)
  (want "timeline-time is not NaN" (nan? (timeline-time tl)) #f))

;; ---- effects
(let ((e (make-effects)))
  (want "effect-set! refuses a NaN duration"
        (try (lambda () (effect-set! e 'burn +nan.0))) 'refused)
  (effect-set! e 'burn 3.0)
  (want "effects-tick! refuses NaN" (try (lambda () (effects-tick! e +nan.0))) 'refused)
  (want "the effect is still there" (effect-active? e 'burn) #t)
  (want "and its remaining time is not NaN" (nan? (effect-ref e 'burn)) #f))

;; ---- recovery
(let ((r (make-recovery)))
  (want "recovery-loss! refuses NaN" (try (lambda () (recovery-loss! r +nan.0))) 'refused)
  (want "recovery-pending is not NaN" (nan? (recovery-pending r)) #f))

(display (if (null? fails) #t fails))

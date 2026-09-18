;; expect: #t
;; EXPECTED FAIL against the (gam ...) libraries.  Twenty-one argument
;; checks are written (not (< x 0)).  NaN is a real and is not less than
;; zero, so every one of them admits it, and what happens next differs
;; by library -- which is why this is one cell over the family rather
;; than a defect filed against one of them.
;;
;; MEASURED, and the spread is the point.  Two of the family were
;; already repaired to (<= 0 x), which NaN fails; the rest were not, and
;; they sit in the same files as the repairs.
;;
;;   abilities  ability-tick!      remaining := NaN, and ready? then
;;                                 answers #t FOREVER -- the cooldown is
;;                                 not jammed, it is gone, and the
;;                                 ability fires without limit.  No
;;                                 later tick of any size repairs it.
;;   stats      damage!/heal!/
;;              regenerate!        the pool's value becomes NaN, so every
;;                                 later comparison against it is false.
;;   window     window-step!       time := NaN, and then live? AND done?
;;                                 are BOTH true.  They are meant to be
;;                                 exclusive; a caller branching on one
;;                                 and falling through to the other
;;                                 reaches a state it has no case for.
;;   timeline   schedule!          the entry is silently dropped: a later
;;                                 tick of 100 fires nothing and the
;;                                 timeline reports itself empty.
;;
;; effects, fields and modifiers also admit it, and there the damage is
;; self-limiting -- the entry expires at once -- so they are not in the
;; rows below.  They are named here so the next reader knows the sweep
;; considered them rather than missed them.
;;
;; THE DIRECTION IS WHY THIS IS WRITTEN DOWN.  A cooldown that jams gets
;; reported; one that is removed does not.  A timeline that fires twice
;; gets reported; one that silently drops the entry does not.  The
;; failures this family produces are the quiet kind.
(import (rnrs) (gam abilities) (gam stats) (gam timeline) (gam window))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (refused? who thunk)
  (guard (e (#t (eq? (condition-who e) who))) (thunk) #f))

(want "ability-tick! refuses NaN"
      (refused? 'ability-tick! (lambda () (ability-tick! (make-ability 'x 0 10.0) +nan.0))) #t)
(want "stats-damage! refuses NaN"
      (refused? 'stats-damage! (lambda () (stats-damage! (make-stats '((hp 100 0))) 'hp +nan.0))) #t)
(want "stats-heal! refuses NaN"
      (refused? 'stats-heal! (lambda () (stats-heal! (make-stats '((hp 100 0))) 'hp +nan.0))) #t)
(want "stats-regenerate! refuses NaN"
      (refused? 'stats-regenerate! (lambda () (stats-regenerate! (make-stats '((hp 100 5))) +nan.0))) #t)
(want "timeline-schedule! refuses a NaN delay"
      (refused? 'timeline-schedule! (lambda () (timeline-schedule! (make-timeline) +nan.0 (lambda () 'x)))) #t)
(want "timeline-tick! refuses NaN"
      (refused? 'timeline-tick! (lambda () (timeline-tick! (make-timeline) +nan.0))) #t)
(want "window-step! refuses NaN"
      (refused? 'window-step! (lambda () (window-step! (make-window 1.0 0.2 0.8) +nan.0))) #t)

;; THE CONSEQUENCE ROWS, so a repair that stops storing NaN while still
;; accepting it cannot pass by being quiet.
(let ((a (make-ability 'x 0 10.0)))
  (ability-use! a)
  (guard (e (#t #t)) (ability-tick! a +nan.0))
  (want "a refused tick leaves the cooldown owed" (ability-remaining a) 10.0)
  (want "and the ability still not ready" (ability-ready? a) #f))
(let ((w (make-window 1.0 0.2 0.8)))
  (guard (e (#t #t)) (window-step! w +nan.0))
  (want "a refused step leaves the time at zero" (window-time w) 0.0)
  ;; live? and done? are meant to be exclusive.  Under NaN both answer #t.
  (want "and live? and done? are not both true"
        (and (window-live? w) (window-done? w)) #f))
(let ((tl (make-timeline)) (fired 0))
  (guard (e (#t #t)) (timeline-schedule! tl +nan.0 (lambda () (set! fired (+ fired 1)))))
  (timeline-tick! tl 100.0)
  (want "a refused schedule leaves the timeline empty" (timeline-empty? tl) #t)
  (want "and fires nothing" fired 0))

;; CONTROLS: the two already repaired, and ordinary arguments still work.
;; Without these a repair that refused everything would pass every row.
(want "ability-lock! already refuses NaN"
      (refused? 'ability-lock! (lambda () (ability-lock! (make-ability 'x 0 10.0) +nan.0))) #t)
(let ((a (make-ability 'x 0 10.0)))
  (ability-use! a) (ability-tick! a 4.0)
  (want "an ordinary tick still counts down" (ability-remaining a) 6.0))
(let ((s (make-stats '((hp 100 0)))))
  (stats-damage! s 'hp 30)
  (want "ordinary damage still lands" (stat s 'hp) 70))
(let ((w (make-window 1.0 0.2 0.8)))
  (window-step! w 0.5)
  (want "an ordinary step still advances" (window-time w) 0.5)
  (want "and live? and done? stay exclusive"
        (and (window-live? w) (window-done? w)) #f))

(if (null? fails) #t fails)

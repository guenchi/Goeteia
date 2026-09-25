;; expect: #t
;; Every (gam ...) entry point that takes a number into its state refuses
;; a non-finite one, and names it.
;;
;; test/defect-infinity-reaches-fields-and-modifiers.ss covers fields,
;; modifiers and the two stats setters.  When the infinity fix landed,
;; each of its 34 guards was reverted one at a time and the whole gam
;; suite run against it, and 20 of the reversions turned nothing red: the
;; repair was verified by hand there and watched by nothing.  This cell is
;; those 20, less the two below that were ruled the other way.
;;
;; THE RULE, and the two places it stops.  A value that ENTERS STATE --
;; a cost, a duration, an elapsed time, an amount -- is refused when it is
;; not finite, as NaN already was.  A value a CALLBACK answers during a
;; query is not stored, and +inf.0 there has a safe meaning the library
;; already gives it: a level curve answering +inf.0 means "no further
;; level" (the comparison is never satisfied, the loop stops), and an item
;; weighing +inf.0 makes the total +inf.0, heavier than any capacity.
;; Those two keep their earlier checks, which refuse NaN and the
;; out-of-range values.  (Ruled 2026-09-23.)
(import (rnrs) (gam abilities) (gam effects) (gam inventory) (gam recovery)
        (gam stats) (gam timeline) (gam window))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t (condition-irritants e))) (thunk) 'accepted))
(define (nan? x) (and (real? x) (not (= x x))))
(define (names? v got)
  (and (list? got)
       (let any ((l got))
         (and (pair? l)
              (or (if (nan? v) (nan? (car l)) (and (real? (car l)) (= (car l) v)))
                  (any (cdr l)))))
       #t))
(define (label v) (cond ((nan? v) "NaN") ((> v 0) "+inf") (else "-inf")))
(define BAD (list +inf.0 -inf.0 +nan.0))
;; expt is not bound here, so the powers are built by hand.
(define (two^ n) (let loop ((i 0) (x 1)) (if (= i n) x (loop (+ i 1) (* x 2)))))
(define BIG (two^ 1024))
(define TINY (/ 1 (two^ 1100)))

;; (name, a procedure of the value that calls the entry point on fresh state)
(define SITES
  (list
   (cons "make-ability cost" (lambda (v) (make-ability 'fire v 2.0)))
   (cons "make-ability cooldown" (lambda (v) (make-ability 'fire 10 v)))
   (cons "ability-tick! dt" (lambda (v) (ability-tick! (make-ability 'fire 10 2.0) v)))
   (cons "ability-lock! seconds" (lambda (v) (ability-lock! (make-ability 'fire 10 2.0) v)))
   (cons "effect-set! duration" (lambda (v) (effect-set! (make-effects) 'burn v)))
   (cons "effects-tick! dt" (lambda (v) (effects-tick! (make-effects) v)))
   (cons "recovery-loss! amount" (lambda (v) (recovery-loss! (make-recovery) v)))
   (cons "make-stats max" (lambda (v) (make-stats (list (list 'hp v 5)))))
   (cons "make-stats regen" (lambda (v) (make-stats (list (list 'hp 100 v)))))
   (cons "stats-spend! amount" (lambda (v) (stats-spend! (make-stats '((hp 100 5))) 'hp v)))
   (cons "stats-damage! amount" (lambda (v) (stats-damage! (make-stats '((hp 100 5))) 'hp v)))
   (cons "stats-heal! amount" (lambda (v) (stats-heal! (make-stats '((hp 100 5))) 'hp v)))
   (cons "stats-regenerate! dt" (lambda (v) (stats-regenerate! (make-stats '((hp 100 5))) v)))
   (cons "stats-gain-xp! amount" (lambda (v) (stats-gain-xp! (make-stats '((hp 100 5))) v)))
   (cons "timeline-schedule! delay" (lambda (v) (timeline-schedule! (make-timeline) v 'go)))
   (cons "timeline-tick! dt" (lambda (v) (timeline-tick! (make-timeline) v)))
   (cons "make-window duration" (lambda (v) (make-window v 0.25 0.75)))
   (cons "window-step! dt" (lambda (v) (window-step! (make-window 1.0 0.25 0.75) v)))))

(for-each
 (lambda (site)
   (for-each (lambda (v)
               (want (string-append (car site) " refuses " (label v) ", naming it")
                     (names? v (try (lambda () ((cdr site) v)))) #t))
             BAD)
;; FINITE AS A FLONUM.  An exact 2^1024 is finite and converts to +inf.0,
   ;; and every one of these sites computes in flonums, so it is refused
   ;; there too.  Only one library had such a row, and the conversion was
   ;; removed from the other seven without any row turning red.
   (want (string-append (car site) " refuses an exact 2^1024, naming it")
         (names? BIG (try (lambda () ((cdr site) BIG)))) #t)
   ;; TWIN: a huge finite value is accepted.  A guard that tested "large"
   ;; rather than "infinite" passes every refusal above and fails this.
   (want (string-append (car site) " accepts 1e300")
         (try (lambda () ((cdr site) 1e300))) 'accepted))
 SITES)

;; STRICTLY POSITIVE AS A FLONUM.  An exact 2^-1100 is a positive real and
;; converts to 0.0, which as a duration gave window-span (+nan.0 . +nan.0).
;; The strictly positive bounds look at the converted value; a half would
;; pass either way and is the twin.
(for-each (lambda (site)
            (want (string-append (car site) " refuses an exact 2^-1100, naming it")
                  (names? TINY (try (lambda () ((cdr site) TINY)))) #t)
            (want (string-append (car site) " accepts an exact 1/2")
                  (try (lambda () ((cdr site) 1/2))) 'accepted))
          (list (cons "make-ability cooldown" (lambda (v) (make-ability 'fire 10 v)))
                (cons "effect-set! duration" (lambda (v) (effect-set! (make-effects) 'burn v)))
                (cons "make-window duration" (lambda (v) (make-window v 0.25 0.75)))))

;; A refused amount leaves the pool where it was: refusing after moving
;; it would pass every row above.
(for-each (lambda (p)
            (let ((s (make-stats '((hp 100 5)))))
              (stats-damage! s 'hp 40)
              (try (lambda () ((cdr p) s +inf.0)))
              (want (string-append "a refused " (car p) " leaves the pool at 60") (stat s 'hp) 60)))
          (list (cons "spend" (lambda (s v) (stats-spend! s 'hp v)))
                (cons "damage" (lambda (s v) (stats-damage! s 'hp v)))
                (cons "heal" (lambda (s v) (stats-heal! s 'hp v)))))

;; ---- the two callback answers, ruled the other way
(let ((s (make-stats '((hp 100 5)) (lambda (level) (if (< level 3) 10 +inf.0)))))
  (want "a curve may answer +inf.0 for no further level" (try (lambda () (stats-gain-xp! s 1000))) 'accepted)
  (want "and the level stops there" (stats-level s) 3))
;; Every call above that might raise is inside try, so a refusal is a
;; failed row and not a trap: a trap ends the program before the verdict
;; is printed, and an empty verdict reads like an empty list of failures.
(let ((s (make-stats '((hp 100 5)) (lambda (level) +nan.0))))
  (want "a curve answering NaN is still refused, naming it"
        (names? +nan.0 (try (lambda () (stats-gain-xp! s 5)))) #t))
(let ((b (make-inventory)))
  (inventory-add! b 'anvil 1)
  (want "an item may weigh +inf.0"
        (let ((r (try (lambda () (inventory-weight b (lambda (k) +inf.0))))))
          (if (eq? r 'accepted) (inventory-weight b (lambda (k) +inf.0)) r))
        +inf.0)
  (want "an item weighing NaN is still refused, naming it"
        (names? +nan.0 (try (lambda () (inventory-weight b (lambda (k) +nan.0))))) #t))

(display (if (null? fails) #t (reverse fails)))

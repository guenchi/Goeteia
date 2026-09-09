;; expect: #t
;; (gam stats): named pools, and a level curve the caller owns.
;;
;; The pools are named rather than indexed because an index is an
;; implicit contract between a caller and a library: getting one wrong
;; is a silently wrong value, and there is nothing to catch it.  The
;; level curve and the level-up bonus are the caller's, so that no
;; particular game's numbers live in here.
;;
;; What is deliberately absent is an invulnerability timer.  A timed
;; state belongs to (gam effects); keeping one here would make
;; stats-damage! quietly depend on a clock that has nothing to do with
;; it, and a caller reading "damage" would not know to look.
(import (rnrs) (gam stats))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (fresh) (make-stats '((hp 100 0) (mana 50 8) (stamina 30 24))))

(check "a fresh stats value is one" (stats? (fresh)))
(check "pools start full" (let ((s (fresh))) (and (= (stat s 'hp) 100) (= (stat s 'mana) 50))))
(check "the maximum is readable" (= (stat-max (fresh) 'stamina) 30))

;; ---- clamping, at both ends ----
(check "set clamps at the maximum" (let ((s (fresh))) (stat-set! s 'hp 999) (= (stat s 'hp) 100)))
(check "set clamps at zero" (let ((s (fresh))) (stat-set! s 'hp -5) (= (stat s 'hp) 0)))
(check "add clamps at the maximum" (let ((s (fresh))) (stat-add! s 'mana 999) (= (stat s 'mana) 50)))

;; ---- spend is all or nothing ----
(check "an affordable spend succeeds and deducts"
       (let ((s (fresh))) (and (stats-spend! s 'mana 20) (= (stat s 'mana) 30))))
(check "an unaffordable spend fails and deducts NOTHING"
       (let ((s (fresh)))
         (and (not (stats-spend! s 'mana 80)) (= (stat s 'mana) 50))))
(check "spending exactly what is left succeeds"
       (let ((s (fresh))) (and (stats-spend! s 'mana 50) (= (stat s 'mana) 0))))

;; ---- damage answers what it actually removed ----
(check "damage past zero removes only what was there, and says so"
       (let ((s (fresh)))
         (and (= (stats-damage! s 'hp 250) 100) (= (stat s 'hp) 0))))
(check "damage to an empty pool removes nothing"
       (let ((s (fresh))) (stats-damage! s 'hp 100) (= (stats-damage! s 'hp 10) 0)))
(check "healing past the maximum heals only the gap, and says so"
       (let ((s (fresh))) (stats-damage! s 'hp 30) (= (stats-heal! s 'hp 100) 30)))

;; ---- damage does not depend on any clock ----
;; the absent invulnerability timer, asserted the only way absence can
;; be: the same blow lands the same whether or not time has passed
(check "damage is the same before and after time passes"
       (let ((a (fresh)) (b (fresh)))
         (stats-regenerate! b 5.0)
         (= (stats-damage! a 'hp 10) (stats-damage! b 'hp 10))))

;; ---- regeneration is per pool, at its own rate ----
(check "each pool regenerates at its own rate and clamps"
       (let ((s (fresh)))
         (stats-damage! s 'mana 40) (stats-damage! s 'stamina 30)
         (stats-regenerate! s 1.0)
         (and (= (stat s 'mana) 18) (= (stat s 'stamina) 24))))
(check "a pool whose rate is zero does not regenerate"
       (let ((s (fresh))) (stats-damage! s 'hp 50) (stats-regenerate! s 10.0)
            (= (stat s 'hp) 50)))
(check "regeneration cannot exceed the maximum"
       (let ((s (fresh))) (stats-regenerate! s 100.0) (= (stat s 'mana) 50)))

;; ---- unknown names are refused, never answered ----
(check "reading an unknown pool is refused" (refuses? (lambda () (stat (fresh) 'nope))))
(check "writing an unknown pool is refused" (refuses? (lambda () (stat-set! (fresh) 'nope 1))))
(check "spending an unknown pool is refused" (refuses? (lambda () (stats-spend! (fresh) 'nope 1))))
(check "a duplicate pool name is refused"
       (refuses? (lambda () (make-stats '((hp 10 0) (hp 20 0))))))
(check "a negative damage is refused" (refuses? (lambda () (stats-damage! (fresh) 'hp -1))))

;; ---- levels: the curve is the caller's, and so is the bonus ----
(check "with no curve, xp accumulates and no level is gained"
       (let ((s (fresh)))
         (and (= (stats-gain-xp! s 500) 0) (= (stats-xp s) 500) (= (stats-level s) 1))))
(check "with a curve, xp becomes levels and the remainder is kept"
       (let ((s (make-stats '((hp 100 0)) (lambda (level) (* 80 level)))))
         (and (= (stats-gain-xp! s 300) 2)   ; 80 then 160 -> 240, 60 left
              (= (stats-level s) 3)
              (= (stats-xp s) 60))))
(check "the level hook is called once per level, with the new level"
       (let* ((seen '())
              (s (make-stats '((hp 100 0))
                             (lambda (level) (* 80 level))
                             (lambda (st level) (set! seen (cons level seen))))))
         (stats-gain-xp! s 300)
         (equal? (reverse seen) '(2 3))))
(check "a curve that answers zero is refused rather than looping forever"
       (refuses? (lambda ()
                   (stats-gain-xp! (make-stats '((hp 1 0)) (lambda (l) 0)) 1))))
(check "negative xp is refused" (refuses? (lambda () (stats-gain-xp! (fresh) -1))))
(check "gaining zero xp is allowed" (= (stats-gain-xp! (fresh) 0) 0))

;; ---- refill ----
(check "refill fills every pool"
       (let ((s (fresh)))
         (stats-damage! s 'hp 90) (stats-damage! s 'mana 40) (stats-refill! s)
         (and (= (stat s 'hp) 100) (= (stat s 'mana) 50))))
(display (= failed 0))

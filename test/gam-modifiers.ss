;; expect: #t
;; What this cell is the only evidence for: (gam modifiers) keeps one
;; claim per source and attribute, sums the ungrouped ones, takes only
;; the largest MAGNITUDE from each exclusive group, and strips by
;; dispellability rather than by group.
;;
;; The last of those is the one a reader assumes wrongly, and the wrong
;; assumption is not visibly wrong: dispelling the strongest member of
;; a group leaves the next largest applying, so the attribute moves
;; part of the way back instead of all the way, which reads as a
;; balance decision rather than as a rule.
(import (rnrs) (gam modifiers))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; An attribute nothing has claimed is zero, not an error: a caller
;; reaches that state by doing nothing at all.
(want 'an-unclaimed-attribute-is-zero
      (modifier-ref (make-modifiers) 'armour) 0)

;; One claim per source and attribute.  A second set from the same
;; source replaces rather than stacks, which is what makes a source
;; that reapplies every frame safe.
(let ((m (make-modifiers)))
  (modifier-set! m 'blessing 'armour 5)
  (modifier-set! m 'blessing 'armour 7)
  (want 'the-same-source-replaces (modifier-ref m 'armour) 7)
  (want 'and-leaves-one-row (length (modifier-entries m)) 1))

;; The same source may hold claims on different attributes at once.
(let ((m (make-modifiers)))
  (modifier-set! m 'blessing 'armour 5)
  (modifier-set! m 'blessing 'speed 2)
  (want 'one-source-two-attributes
        (list (modifier-ref m 'armour) (modifier-ref m 'speed)) '(5 2)))

;; Ungrouped claims from different sources add up.
(let ((m (make-modifiers)))
  (modifier-set! m 'blessing 'armour 5)
  (modifier-set! m 'shield 'armour 3)
  (modifier-set! m 'curse 'armour -2)
  (want 'ungrouped-claims-sum (modifier-ref m 'armour) 6))

;; A group contributes its largest magnitude only, and MAGNITUDE is the
;; word: a penalty of nine beats a bonus of four, and the answer is the
;; penalty rather than their sum or the larger number.
(let ((m (make-modifiers)))
  (modifier-set! m 'rite 'armour 4 #f 'ward)
  (modifier-set! m 'hex 'armour -9 #f 'ward)
  (want 'a-group-yields-its-largest-magnitude (modifier-ref m 'armour) -9))

;; Groups are judged separately and then summed, and an ungrouped claim
;; joins that sum rather than competing with a group.
(let ((m (make-modifiers)))
  (modifier-set! m 'rite 'armour 4 #f 'ward)
  (modifier-set! m 'hex 'armour -9 #f 'ward)
  (modifier-set! m 'stone 'armour 6 #f 'earth)
  (modifier-set! m 'stone2 'armour 2 #f 'earth)
  (modifier-set! m 'plain 'armour 1)
  (want 'each-group-once-plus-the-ungrouped (modifier-ref m 'armour) -2))

;; Dispelling removes by dispellability, not by group.  Stripping the
;; group's winner leaves the next largest applying -- the attribute
;; moves part of the way back, not all of it.
(let ((m (make-modifiers)))
  (modifier-set! m 'hex 'armour -9 #f 'ward #t)
  (modifier-set! m 'rite 'armour -4 #f 'ward #f)
  (want 'the-strongest-holds-the-group (modifier-ref m 'armour) -9)
  (modifier-dispel! m)
  (want 'dispel-leaves-the-next-largest (modifier-ref m 'armour) -4)
  (want 'and-only-the-dispellable-row-went (length (modifier-entries m)) 1))

;; Dispelling is not clearing: what was not marked stays, whatever it
;; is, and clearing takes everything.
(let ((m (make-modifiers)))
  (modifier-set! m 'blessing 'armour 5 #f #f #f)
  (modifier-dispel! m)
  (want 'an-undispellable-claim-survives (modifier-ref m 'armour) 5)
  (modifier-clear! m)
  (want 'clearing-takes-everything (modifier-ref m 'armour) 0))

;; Removing a source takes all of its claims, across attributes, and
;; nobody else's.
(let ((m (make-modifiers)))
  (modifier-set! m 'blessing 'armour 5)
  (modifier-set! m 'blessing 'speed 2)
  (modifier-set! m 'shield 'armour 3)
  (modifier-remove-source! m 'blessing)
  (want 'the-source-is-gone-from-every-attribute
        (list (modifier-ref m 'armour) (modifier-ref m 'speed)) '(3 0)))

;; A claim with no duration is left alone by the clock; a timed one
;; counts down and is dropped at zero, because a modifier with no time
;; left is not one that still applies for an instant.
(let ((m (make-modifiers)))
  (modifier-set! m 'forever 'armour 5)
  (modifier-set! m 'brief 'armour 3 2.0)
  (modifier-tick! m 1.0)
  (want 'a-timed-claim-still-applies-while-it-lasts (modifier-ref m 'armour) 8)
  (want 'and-its-remaining-came-down
        (let find ((l (modifier-entries m)))
          (cond ((not (pair? l)) 'missing)
                ((eq? 'brief (modifier-entry-source (car l)))
                 (modifier-entry-remaining (car l)))
                (else (find (cdr l)))))
        1.0)
  (modifier-tick! m 1.0)
  (want 'reaching-exactly-zero-drops-it (modifier-ref m 'armour) 5)
  (want 'the-undated-claim-was-not-touched
        (modifier-entry-remaining (car (modifier-entries m))) #f))

;; The scale mapping multiplies an attribute by one plus another
;; attribute's own total, so a scale of zero leaves the base alone
;; rather than erasing it.
(let ((m (make-modifiers) ))
  (want 'a-scale-of-nothing-is-the-identity (modifier-ref m 'armour) 0))
(let ((m (make-modifiers (lambda (a) (and (eq? a 'armour) 'armour-percent)))))
  (modifier-set! m 'plate 'armour 10)
  (want 'no-percentage-yet-is-the-base (modifier-ref m 'armour) 10)
  (modifier-set! m 'polish 'armour-percent 1/2)
  (want 'the-scale-multiplies-the-base (modifier-ref m 'armour) 15)
  (want 'and-the-scaling-attribute-reads-plain
        (modifier-ref m 'armour-percent) 1/2))

;; Entries are opaque and read through the accessors, which is why they
;; exist; newest first is the documented order.
(let ((m (make-modifiers)))
  (modifier-set! m 'first 'armour 1)
  (modifier-set! m 'second 'armour 2)
  (want 'entries-are-newest-first
        (map modifier-entry-source (modifier-entries m)) '(second first))
  (let ((e (car (modifier-entries m))))
    (want 'an-entry-answers-what-it-was-given
          (list (modifier-entry-attribute e) (modifier-entry-value e)
                (modifier-entry-group e) (modifier-entry-dispellable? e))
          '(armour 2 #f #f))))

;; Refusals.
(want 'a-string-source-refused
      (raises? (lambda () (modifier-set! (make-modifiers) "s" 'armour 1))) #t)
(want 'a-non-real-value-refused
      (raises? (lambda () (modifier-set! (make-modifiers) 's 'armour 'big))) #t)
(want 'a-zero-duration-refused
      (raises? (lambda () (modifier-set! (make-modifiers) 's 'armour 1 0))) #t)
(want 'a-negative-duration-refused
      (raises? (lambda () (modifier-set! (make-modifiers) 's 'armour 1 -1.0))) #t)
(want 'a-non-symbol-group-refused
      (raises? (lambda () (modifier-set! (make-modifiers) 's 'armour 1 #f 7))) #t)
(want 'a-non-boolean-dispellable-refused
      (raises? (lambda () (modifier-set! (make-modifiers) 's 'armour 1 #f 'g 'yes))) #t)
(want 'a-negative-elapsed-refused
      (raises? (lambda () (modifier-tick! (make-modifiers) -1.0))) #t)
(want 'a-non-procedure-scale-mapping-refused
      (raises? (lambda () (make-modifiers 'not-a-procedure))) #t)

(display (if (null? fails) #t (reverse fails)))

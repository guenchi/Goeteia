;; expect: #t
;; THE INVARIANT: no sequence of inputs a (gam ...) library accepts can
;; leave a quantity it holds as a flonum-domain value non-finite, or
;; make a value it computes NaN; and a call it refuses changes nothing.
;;
;; This is the companion of gam-no-input-turns-state-into-nan.ss, one
;; step later: that cell feeds NaN and infinities at the door; this one
;; feeds values that pass the door, twice, and reads what the sum did.
;; The inputs are 1e308 (a flonum that is finite and, added to itself,
;; is not) and the exact 2^1023 (finite as a flonum, and not when
;; doubled).
;;
;; THIS IS AN ENUMERATION, NOT A DISCOVERY.  Every entry walked and
;; every reading taken is named below; an entry added to a library
;; later is outside this cell until a row is added for it.  The rows
;; were written from the export lists of the nine libraries with
;; numeric state on 2026-09-25.  Deliberately absent: (gam once),
;; (gam quest), (gam party), (gam state), (gam save), whose state holds
;; counts, keys and symbols and no flonum-domain quantity.
;;
;; EVERY FIXTURE STARTS POPULATED, so that the entries that remove,
;; tick down or claim have something to act on: a queued payload, live
;; modifier rows, a running effect, items in the bag, a cooling
;; ability, an open recovery claim.
;;
;; WHAT EACH READING IS HELD TO.  A stored quantity -- a pool, a clock,
;; a total, a remaining time -- must be finite as a flonum.  A computed
;; answer -- a bag's weight, a scaled attribute, a window's span -- may
;; be infinite, which is a definite answer, but must not be NaN
;; anywhere inside it.  A count -- items held, a level -- is an exact
;; integer of any size and is read only to check that a refused call
;; left it alone.  A reading that raises is recorded as such rather
;; than treated as a value; whether a read may refuse is that
;; library's own contract and is pinned elsewhere.
;;
;; WHAT THIS CELL CANNOT SEE.  Queued deadlines in a timeline and a
;; field's settlement accumulator have no reader; their sums are pinned
;; by construction in gam-sums-stay-finite-as-flonums.ss.
(import (rnrs) (gam stats) (gam timeline) (gam fields) (gam window)
        (gam inventory) (gam modifiers) (gam effects) (gam abilities)
        (gam recovery))

(define fails '())
(define (fail! . what) (set! fails (cons what fails)))

(define (two^ n) (let loop ((i 0) (x 1)) (if (= i n) x (loop (+ i 1) (* x 2)))))
(define (finite? x) (let ((y (inexact x))) (= 0 (- y y))))
(define (nan? x) (and (real? x) (not (= x x))))
;; NaN anywhere inside a value: a pair's parts, a list's items.
(define (holds-nan? x)
  (cond ((real? x) (nan? x))
        ((pair? x) (or (holds-nan? (car x)) (holds-nan? (cdr x))))
        ((vector? x) (let loop ((i 0)) (and (< i (vector-length x))
                                            (or (holds-nan? (vector-ref x i)) (loop (+ i 1))))))
        (else #f)))
(define BIG 1e308)
(define EXACT-BIG (two^ 1023))

(define (try thunk)
  (guard (e (#t (list 'raised (condition-who e))))
    (list 'returned (thunk))))

;; Two readings are the same when every number compares = and
;; everything else is equal?.  NaN is never the same as anything, so a
;; snapshot holding NaN reads as changed, which is red either way.
(define (same? a b)
  (cond ((and (real? a) (real? b)) (= a b))
        ((and (pair? a) (pair? b)) (and (same? (car a) (car b)) (same? (cdr a) (cdr b))))
        (else (equal? a b))))

;; A reading is (kind . value): 'stored must be finite, 'answer must not
;; hold NaN, 'count is only compared, and a reading that raised is
;; (raised . who).
(define (stored thunk) (let ((r (try thunk))) (if (eq? (car r) 'raised) r (cons 'stored (cadr r)))))
(define (answer thunk) (let ((r (try thunk))) (if (eq? (car r) 'raised) r (cons 'answer (cadr r)))))
(define (count thunk) (let ((r (try thunk))) (if (eq? (car r) 'raised) r (cons 'count (cadr r)))))

(define (reading-ok? lib entry r)
  (case (car r)
    ((stored) (or (finite? (cdr r)) (begin (fail! lib entry 'stored-non-finite (cdr r)) #f)))
    ((answer) (or (not (holds-nan? (cdr r))) (begin (fail! lib entry 'answer-holds-nan (cdr r)) #f)))
    (else #t)))

;; Walk one library: for each entry and each input, a fresh populated
;; object, the entry applied twice with that input; after an accepted
;; call every reading is held to its kind, after a refused call every
;; reading is unchanged.  The procedure of an entry takes the object
;; and the input, and nothing else survives between objects.
(define (walk lib make observe entries)
  (for-each
   (lambda (input)
     (for-each
      (lambda (entry)
        (let ((name (car entry)) (call (cdr entry)) (o (make)))
          (let twice ((n 0))
            (when (< n 2)
              (let* ((before (observe o))
                     (r (try (lambda () (call o input))))
                     (after (observe o)))
                (if (eq? (car r) 'raised)
                    (unless (same? before after)
                      (fail! lib name 'refused-but-changed before after))
                    (begin
                      (when (holds-nan? (cadr r))
                        (fail! lib name 'returned-nan))
                      (for-each (lambda (x) (reading-ok? lib name x)) after))))
              (twice (+ n 1))))))
      entries))
   (list BIG EXACT-BIG)))

;; ---- (gam stats) ----
;; The curve caps at +inf.0 and counts its calls, so a loop that does
;; not stop is read as the curve's error rather than as a stall.
(define (capped-curve)
  (let ((asked 0))
    (lambda (level)
      (set! asked (+ asked 1))
      (when (> asked 64) (error 'curve-asked-too-often "the level loop did not stop" asked))
      +inf.0)))
(walk 'stats
      (lambda () (let ((s (make-stats '((hp 100 0) (mana 50 8)) (capped-curve))))
                   (stats-gain-xp! s 5)
                   s))
      (lambda (s) (list (stored (lambda () (stat s 'hp))) (stored (lambda () (stat s 'mana)))
                        (stored (lambda () (stat-max s 'hp)))
                        (stored (lambda () (stats-xp s))) (count (lambda () (stats-level s)))))
      (list (cons 'stat-set! (lambda (s v) (stat-set! s 'hp v)))
            (cons 'stat-add! (lambda (s v) (stat-add! s 'hp v)))
            (cons 'stats-spend! (lambda (s v) (stats-spend! s 'hp v)))
            (cons 'stats-damage! (lambda (s v) (stats-damage! s 'hp v)))
            (cons 'stats-heal! (lambda (s v) (stats-heal! s 'hp v)))
            (cons 'stats-regenerate! (lambda (s v) (stats-regenerate! s v)))
            (cons 'stats-refill! (lambda (s v) (stats-refill! s)))
            (cons 'stats-gain-xp! (lambda (s v) (stats-gain-xp! s v)))))

;; ---- (gam timeline) ----
(walk 'timeline
      (lambda () (let ((t (make-timeline))) (timeline-schedule! t 1.0 'queued) t))
      (lambda (t) (list (stored (lambda () (timeline-time t))) (answer (lambda () (timeline-empty? t)))))
      (list (cons 'timeline-tick! (lambda (t v) (timeline-tick! t v)))
            (cons 'timeline-schedule! (lambda (t v) (timeline-schedule! t v 'p)))
            (cons 'timeline-clear! (lambda (t v) (timeline-clear! t)))))

;; ---- (gam fields) ----
;; The settlement callback's argument is a computed answer.
(define settled-amounts '())
(walk 'fields
      (lambda () (make-field 'fire 0.0 0.0 1.0 0.0 0.0 BIG 1 BIG))
      (lambda (f) (list (stored (lambda () (field-life f)))
                        (answer (lambda () (if (null? settled-amounts) 0 (car settled-amounts))))))
      (list (cons 'field-step! (lambda (f v) (field-step! f v (lambda (f owed) (set! settled-amounts (cons owed settled-amounts))))))))

;; ---- (gam window) ----
(walk 'window
      (lambda () (make-window BIG 0.25 0.75))
      (lambda (w) (list (stored (lambda () (window-time w))) (answer (lambda () (window-span w)))))
      (list (cons 'window-step! (lambda (w v) (window-step! w v)))
            (cons 'window-reset! (lambda (w v) (window-reset! w)))))

;; ---- (gam inventory) ----
;; Counts are exact and of any size; the weight is the computed answer.
(walk 'inventory
      (lambda () (let ((b (make-inventory))) (inventory-add! b 'k 5) b))
      (lambda (b) (list (count (lambda () (inventory-count b 'k)))
                        (count (lambda () (inventory-items b)))
                        (answer (lambda () (inventory-weight b (lambda (k) 1.0))))))
      (list (cons 'inventory-add! (lambda (b v) (inventory-add! b 'k (if (exact? v) v 1))))
            (cons 'inventory-take! (lambda (b v) (inventory-take! b 'k 1)))))

;; ---- (gam modifiers) ----
;; A base attribute scaled by rows that add up past the flonum range:
;; the product is the computed answer.  The source of a new row is
;; chosen from the object, so nothing carries over between fixtures.
(define (next-source m)
  (let ((n (length (modifier-entries m)))) (if (= n 2) 'c 'd)))
(walk 'modifiers
      (lambda () (let ((m (make-modifiers (lambda (a) (if (eq? a 'power) 'power-scale #f)))))
                   (modifier-set! m 'base 'power 0.0)
                   (modifier-set! m 'a 'power-scale 1.0 2.0)
                   m))
      (lambda (m) (list (answer (lambda () (modifier-ref m 'power)))
                        (answer (lambda () (modifier-ref m 'power-scale)))
                        (answer (lambda () (map (lambda (e) (cons (modifier-entry-value e) (modifier-entry-remaining e)))
                                                (modifier-entries m))))))
      (list (cons 'modifier-set! (lambda (m v) (modifier-set! m (next-source m) 'power-scale v)))
            (cons 'modifier-set!-with-duration (lambda (m v) (modifier-set! m (next-source m) 'power-scale v v)))
            (cons 'modifier-tick! (lambda (m v) (modifier-tick! m v)))
            (cons 'modifier-remove-source! (lambda (m v) (modifier-remove-source! m 'a)))
            (cons 'modifier-dispel! (lambda (m v) (modifier-dispel! m)))
            (cons 'modifier-clear! (lambda (m v) (modifier-clear! m)))))

;; ---- (gam effects) ----
(walk 'effects
      (lambda () (let ((f (make-effects))) (effect-set! f 'burn 3.0) f))
      (lambda (f) (list (stored (lambda () (or (effect-ref f 'burn) 0)))))
      (list (cons 'effect-set! (lambda (f v) (effect-set! f 'burn v)))
            (cons 'effects-tick! (lambda (f v) (effects-tick! f v)))
            (cons 'effects-clear! (lambda (f v) (effects-clear! f)))))

;; ---- (gam abilities) ----
(walk 'abilities
      (lambda () (let ((a (make-ability 'blink 1.0 BIG))) (ability-use! a) a))
      (lambda (a) (list (stored (lambda () (ability-remaining a)))))
      (list (cons 'ability-lock! (lambda (a v) (ability-lock! a v)))
            (cons 'ability-tick! (lambda (a v) (ability-tick! a v)))
            (cons 'ability-use! (lambda (a v) (ability-use! a)))))

;; ---- (gam recovery) ----
(walk 'recovery
      (lambda () (let ((r (make-recovery))) (recovery-loss! r 7.0) r))
      (lambda (r) (list (stored (lambda () (recovery-pending r)))))
      (list (cons 'recovery-loss! (lambda (r v) (recovery-loss! r v)))
            (cons 'recovery-claim! (lambda (r v) (recovery-claim! r 1)))))

(display (if (null? fails) #t (reverse fails)))

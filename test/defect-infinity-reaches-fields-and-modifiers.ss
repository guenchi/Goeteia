;; expect: #t
;; Written red against lib/gam/fields.ss and lib/gam/modifiers.ss (fb374f2),
;; widened in 2026-09 as the fix exposed more of the same, and green once
;; the fix landed.  The history is kept because each row records a way the
;; first repairs passed while the defect stayed.
;; The NaN sweep closed NaN.  It did not close the infinities, and in
;; two of the libraries they reach the state.
;;
;; THE SHARPEST ROW IS NOT A DIRTY NUMBER, IT IS AN INVERTED ANSWER.
;; field-contains? tests (not (< (* r r) (+ (* over over) (* across across)))).
;; With yaw 0, sin is exactly 0.0, and the rotation multiplies the
;; infinite coordinate by it: +inf x 0.0 is NaN.  For an infinite x that
;; NaN lands in `across`, the sum is NaN, every comparison with NaN is
;; FALSE, and `not` turns that into #t: a point infinitely far away is
;; reported as INSIDE a circle of radius five.  Traced term by term, and
;; identical under the Chez host, the self-hosted wasm and the JS target.
;; An earlier version of this comment blamed inf - inf; it was never
;; traced, and the product is what does it.
;;
;; The infinite-z row is green ONLY BY POSITION.  There the NaN lands in
;; `along`, and (max 0.0 +nan.0) is 0.0 while (max +nan.0 0.0) is NaN --
;; so the NaN is washed out because it is the second argument.  Which
;; axis goes wrong depends on whether the yaw makes sin or cos exactly
;; zero; with any other yaw neither does.

;; That is the same mechanism as the NaN cooldown and the NaN pool: a
;; comparison that answers false, sitting behind `not`, is a door that
;; is always open.  The value being wrong is the small half; the
;; predicate being wrong is the large one.
;;
;; WHY THIS IS SEPARATE FROM THE NaN BATCH.  (= x x) excludes NaN only,
;; which is what that batch ruled and what it says it did.  Excluding
;; the infinities is a different test.  The tree has one that is right,
;; fl-finite? at lib/web/frac.ss:92, (fl=? 0.0 (fl- v v)).  It also has
;; one that is named for it and is not: $finite? at lib/sim/step.ss:69
;; tests (fl<? x 1e300), which calls every double from 1e300 up to
;; 1.797e308 non-finite.  An earlier version of this comment said both
;; were the first spelling; that was never measured, and the rows below
;; that must ACCEPT 1.7e308 exist because the second spelling is already
;; in the tree to be copied.  Whether each site should test finiteness is
;; a question with a different answer per library.  stats does not need it:
;; measured, $clamp holds an infinite set to the pool's max or zero,
;; because (< max +inf.0) is true.  fields and modifiers do.
;; ---- WHAT THE ROWS ASK, after a coverage review ran mutations on the
;; first version and turned it all-green with the defect still present:
;;   * every numeric argument of every entry point, not three of them;
;;   * both signs of infinity, and NaN, at each -- a guard that tests only
;;     one sign, or only infinity, passed the first version;
;;   * a large FINITE twin for each, read back through the accessor -- a
;;     twin that only checked "not refused" passed a store that replaced
;;     1.7e308 with 1000.0;
;;   * that a refusal leaves earlier state as it was -- clearing
;;     everything and then refusing passed a read-back of an empty set.
;; field-contains? now REFUSES a non-finite query point, like its other
;; arguments, instead of answering #f: it already refused a NaN one, and
;; one entry point should not answer two non-finite numbers two ways.
(import (rnrs) (gam fields) (gam modifiers) (gam stats))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
;; A refusal counts only if it names the value: refusals in these
;; libraries carry the offending values as irritants (measured: a NaN x
;; gives (+nan.0 0.0), a negative radius gives (-1.0)).  Any condition
;; used to read as a refusal, so a failure for another reason passed.
(define (try thunk)
  (guard (e (#t (condition-irritants e)))
    (thunk) 'accepted))
;; NaN is equal to nothing, so it is looked for by (= x x) failing.
(define (names? v got)
  (and (list? got)
       (if (= v v)
           (memv v got)
           (let any ((l got)) (and (pair? l) (or (and (real? (car l)) (not (= (car l) (car l)))) (any (cdr l))))))
       #t))
(define (refuses name v thunk) (want (string-append name " refuses it, naming it") (names? v (try thunk)) #t))
(define (finite? x) (and (real? x) (= x x) (not (= x +inf.0)) (not (= x -inf.0))))
(define BAD (list +inf.0 -inf.0 +nan.0))
(define (label v) (cond ((not (= v v)) "NaN") ((> v 0) "+inf") (else "-inf")))

;; ---- make-field: kind x z radius half-length yaw duration rate period
(define (mk . over)
  ;; the ordinary field, with the arguments in `over` replaced by index
  (let ((args (vector 'circle 0.0 0.0 5.0 0.0 0.0 2.0 1.0 0.5)))
    (let loop ((o over)) (when (pair? o) (vector-set! args (car o) (cadr o)) (loop (cddr o))))
    (apply make-field (vector->list args))))
(define ARGS '((1 "x" field-x #t) (2 "z" field-z #t) (3 "radius" field-radius #f)
               (4 "half-length" field-half-length #f) (5 "yaw" field-yaw #t)
               (6 "duration" field-life #f) (7 "rate" field-rate #t)
               (8 "period" field-period #f)))
(define ACCESS (list (cons 'field-x field-x) (cons 'field-z field-z) (cons 'field-radius field-radius)
                     (cons 'field-half-length field-half-length) (cons 'field-yaw field-yaw)
                     (cons 'field-life field-life) (cons 'field-rate field-rate)
                     (cons 'field-period field-period)))
(for-each
 (lambda (a)
   (let ((i (car a)) (name (cadr a)) (get (cdr (assq (caddr a) ACCESS))) (signed (cadddr a)))
     (for-each (lambda (v)
                 ;; a negative value is refused by the non-negative
                 ;; arguments for being negative; that refusal still names
                 ;; it, which is all a refusal row asks
                 (refuses (string-append "make-field " name " " (label v)) v (lambda () (mk i v))))
               BAD)
     ;; TWIN: the largest finite value this argument allows, stored as itself.
     (let ((big (if signed -1.7e308 1.7e308)))
       (want (string-append "make-field keeps a huge finite " name)
             (let ((f (mk i big))) (get f)) big))))
 ARGS)
(want "make-field still accepts ordinary numbers" (try (lambda () (mk))) 'accepted)

;; ---- field-contains?: the query point
(define f (mk))
(for-each (lambda (v)
            (refuses (string-append "field-contains? x " (label v)) v (lambda () (field-contains? f v 0.0)))
            (refuses (string-append "field-contains? z " (label v)) v (lambda () (field-contains? f 0.0 v))))
          BAD)
;; ALL-FINITE INPUTS CAN STILL OVERFLOW INTO THE SAME INVERSION.  Refusing
;; the infinities closed the door at the arguments; the arithmetic behind
;; it can still make one.  A centre at -1.7e308 and a query at +1.7e308
;; subtract to +inf.0, which yaw 0 multiplies by 0.0 into NaN; a radius
;; of 1e200 and a query at 2e200 square to +inf.0 on both sides, and
;; (< inf inf) is false.  Under `not`, both read INSIDE.  Measured on the
;; three targets before these rows were written.  A comparison that
;; fails toward "outside" -- distance over radius, at most 1, no `not` --
;; cannot invert: it can only ever err outward.
(want "a query across the whole number line is outside"
      (field-contains? (mk 1 -1.7e308) 1.7e308 0.0) #f)
(want "a query at twice a huge radius is outside"
      (field-contains? (mk 3 1e200) 2e200 0.0) #f)
;; CONTROL for the rewrite: just inside and just outside an ordinary
;; radius must keep their answers, on the axis and off it.
(want "just inside the radius is inside" (field-contains? f 4.999 0.0) #t)
(want "just outside the radius is outside" (field-contains? f 5.001 0.0) #f)
(want "just inside, off the axis" (field-contains? f 3.0 3.999) #t)
(want "just outside, off the axis" (field-contains? f 3.0 4.001) #f)
;; THE NOMINAL RADIUS.  These two rows were written to pin that a point
;; exactly on the radius is inside, and they cannot: the rotation goes
;; through cos, (cos 0.0) is 0.9999999999939766 -- inside the accuracy
;; docs/limits.md declares -- and so (5,0) and (3,4) compute to a sum of
;; squares of 0.9999999999879532, strictly inside.  Measured: turning <=
;; into < leaves both rows green.  Any input that lands exactly on 1.0
;; today would be pinned to this cos, and would stop meaning anything the
;; day cos becomes exact.  So <= against < is left unpinned ON PURPOSE,
;; the docs say a point within about 1e-11 of the radius may be answered
;; either way, and these rows keep only what they do show: a point on the
;; nominal radius is not thrown outside.  (Ruled 2026-09-25.)
(want "a point on the nominal radius is inside, on the axis" (field-contains? f 5.0 0.0) #t)
(want "a point on the nominal radius is inside, off the axis" (field-contains? f 3.0 4.0) #t)

;; FINITE AS WHAT THE ARITHMETIC WILL USE.  An exact number can be finite
;; and still not survive the conversion the geometry does: 2^1024 becomes
;; +inf.0, and a radius of 2^-1100 becomes 0.0.  The first put a point
;; far outside a field inside it; the second put the centre outside.  The
;; boundary checks what the value will be as a flonum, and refuses there.
;; expt is not bound here (an R6RS base procedure that is missing, like
;; finite?), so the powers are built by hand.
(define (two^ n) (let loop ((i 0) (x 1)) (if (= i n) x (loop (+ i 1) (* x 2)))))
(define big (two^ 1024))
(define tiny (/ 1 (two^ 1100)))
(want "an exact half-length beyond the double range is refused"
      (names? big (try (lambda () (mk 4 big)))) #t)
(want "an exact radius that converts to 0.0 is refused"
      (names? tiny (try (lambda () (mk 3 tiny)))) #t)
;; TWIN: an ordinary exact radius is still a radius.
(want "an exact radius of 5 still works" (field-contains? (mk 3 5) 4 0) #t)
(want "an exact duration that converts to 0.0 is refused"
      (names? tiny (try (lambda () (mk 6 tiny)))) #t)
(let ((m (make-modifiers)))
  (want "an exact modifier duration that converts to 0.0 is refused"
        (names? tiny (try (lambda () (modifier-set! m 'aura 'def 2 tiny #f #t)))) #t)
  (want "an exact modifier value beyond the double range is refused"
        (names? big (try (lambda () (modifier-set! m 'ring 'atk big #f #f #t)))) #t))
;; TWIN: exact values that do survive the conversion are kept as given.
(want "an exact half-length of 1/2 is kept exact" (field-half-length (mk 4 1/2)) 1/2)

;; CONTROL: the predicate still answers ordinary positions.
(want "the centre is inside" (field-contains? f 0.0 0.0) #t)
(want "a point beyond the radius is outside" (field-contains? f 99.0 0.0) #f)
(want "a point far away but finite is outside" (field-contains? f 1.7e308 0.0) #f)

;; ---- field-step!: the elapsed time, and that a refusal changes nothing
(let* ((g (mk)) (settled 0) (settle (lambda (fld owed) (set! settled (+ settled 1)))))
  (refuses "field-step! dt +inf" +inf.0 (lambda () (field-step! g +inf.0 settle)))
  (refuses "field-step! dt NaN" +nan.0 (lambda () (field-step! g +nan.0 settle)))
  (want "a refused step leaves the life as it was" (field-life g) 2.0)
  (want "a refused step settles nothing" settled 0))
;; TWIN: a huge finite step ends the field and settles once.
(let* ((g (mk)) (settled 0))
  (field-step! g 1e300 (lambda (fld owed) (set! settled (+ settled 1))))
  (want "a huge finite step ends the field" (field-life g) 0.0)
  (want "and settles once" settled 1))

;; ---- modifiers: the value and the duration, over a claim already held
(define (held)
  (let ((m (make-modifiers)))
    (modifier-set! m 'ring 'atk 5 #f #f #t)
    (modifier-set! m 'aura 'def 2 3.0 #f #t)
    m))
(define (unchanged? m)
  (and (= (modifier-ref m 'atk) 5) (= (modifier-ref m 'def) 2)
       (= (length (modifier-entries m)) 2)))
(for-each (lambda (v)
            (let ((m (held)))
              (refuses (string-append "modifier-set! value " (label v)) v
                       (lambda () (modifier-set! m 'ring 'atk v #f #f #t)))
              (want (string-append "a refused " (label v) " value leaves the held claims") (unchanged? m) #t)))
          BAD)
(let ((m (held)))
  (refuses "modifier-set! duration +inf" +inf.0 (lambda () (modifier-set! m 'aura 'def 2 +inf.0 #f #t)))
  (refuses "modifier-set! duration NaN" +nan.0 (lambda () (modifier-set! m 'aura 'def 2 +nan.0 #f #t)))
  (want "a refused duration leaves the held claims" (unchanged? m) #t)
  (want "and nothing infinite can be read back" (finite? (modifier-ref m 'atk)) #t))
;; TWINS: #f is how a claim lasts forever, and a huge finite value or
;; duration is stored as itself.
(let ((m (make-modifiers)))
  (want "a duration of #f is still forever" (try (lambda () (modifier-set! m 'crown 'atk 1 #f #f #t))) 'accepted)
  (modifier-set! m 'blessing 'def 1e300 1e300 #f #t)
  (want "a huge finite modifier still applies" (modifier-ref m 'def) 1e300))
;; CONTROL: a negative modifier still works.
(let ((m (make-modifiers)))
  (modifier-set! m 'debuff 'atk -3 2.0 #f #t)
  (want "a debuff still applies" (modifier-ref m 'atk) -3))

;; ---- modifier-tick!: the elapsed time
(let ((m (held)))
  (refuses "modifier-tick! dt +inf" +inf.0 (lambda () (modifier-tick! m +inf.0)))
  (refuses "modifier-tick! dt NaN" +nan.0 (lambda () (modifier-tick! m +nan.0)))
  (want "a refused tick expires nothing" (unchanged? m) #t))
;; TWIN: a huge finite tick expires the timed claim and keeps the forever one.
(let ((m (held)))
  (modifier-tick! m 1e300)
  (want "a huge finite tick expires the timed claim only" (list (modifier-ref m 'atk) (modifier-ref m 'def)) '(5 0)))

;; ---- stats: refused, although the clamp would have held it.
;; An earlier version of this cell left stats out because $clamp holds an
;; infinite set to the pool's max or zero, so the state is never infinite.
;; That is true and was the wrong question: the same two entry points
;; already REFUSE NaN, and holding -inf.0 at zero empties the pool without
;; a word -- measured, the pool read 0 after one call.  (Ruled 2026-09-23.)
(for-each (lambda (v)
            (let ((s (make-stats '((hp 100 5)))))
              (refuses (string-append "stat-set! " (label v)) v (lambda () (stat-set! s 'hp v)))
              (refuses (string-append "stat-add! " (label v)) v (lambda () (stat-add! s 'hp v)))
              (want (string-append "the pool is where it was after " (label v)) (stat s 'hp) 100)))
          BAD)
(let ((s (make-stats '((hp 100 5)))))
  (stat-add! s 'hp -1e300)
  (want "a huge finite loss still clamps to zero" (stat s 'hp) 0))

(display (if (null? fails) #t (reverse fails)))

;; expect: #t
;; field-contains? decides ordinary flonum inputs with its filter, never
;; with the exact path (R23: archive/goeteia-r23-design-2026-11-12.md, 3.2;
;; the exact path costs about 4.7 ms a call on wasm, so it must stay for
;; inputs within the error bound of the boundary, overflow and huge
;; computed coefficients).
;;
;; THE INSTRUMENT.  $field-exact-calls, an internal export of (gam fields):
;; how many times field-contains? has evaluated its exact path.  It says
;; which path answered, not whether the answer is right; the answers are
;; checked against the same exact oracle as test/field-contains-is-exact.ss.
;;
;; Rows:
;;   ROUTE  points at 0, 0.3, 0.6, 1.5 and 3 times (h + r) from the centre
;;          along the axis, for five (r, h, yaw): each as the oracle says,
;;          and the count of exact-path evaluations does not move
;;   CTRL   an exact boundary point (q = t exactly) does move it -- the
;;          instrument can see the exact path
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: there is no
;; $field-exact-calls.
(import (rnrs) (gam fields))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define (ex v) (if (exact? v) v (inexact->exact v)))
(define (fin? v) (and (flonum? v) (= 0.0 (- v v))))
;; the specification: #t inside, #f outside, 'none for a yaw whose
;; computed sine or cosine is not finite
(define (oracle fx fz r h yaw x z)
  (let ((c (cos yaw)) (s (sin yaw)))
    (if (not (and (fin? c) (fin? s)))
        'none
        (let* ((dx (- (ex x) (ex fx))) (dz (- (ex z) (ex fz)))
               (ce (ex c)) (se (ex s))
               (A (+ (* dx ce) (* dz se)))
               (B (- (* dz ce) (* dx se)))
               (O (max 0 (- (abs A) (ex h)))))
          (<= (+ (* O O) (* B B)) (* (ex r) (ex r)))))))
(define (field fx fz r h yaw) (make-field 'test fx fz r h yaw 1.0 1.0))
(define (answer fx fz r h yaw x z)
  (guard (e (#t (list 'raised (and (error? e) (condition-who e)))))
    (field-contains? (field fx fz r h yaw) x z)))
;; one row: the oracle's answer is `expect', and so is the predicate's
(define (row name expect fx fz r h yaw x z)
  (let ((o (oracle fx fz r h yaw x z)))
    (want (string-append "oracle " name) o expect)
    (want name (answer fx fz r h yaw x z) (if (eq? expect 'none) #f expect))))
;; a family: every point as the oracle says
(define (family name pts)
  (let loop ((ps pts) (bad '()) (n 0))
    (if (null? ps)
        (begin (want (string-append name " rows checked") (> n 0) #t)
               (want name (reverse bad) '()))
        (let* ((p (car ps)) (o (apply oracle p)) (a (apply answer p)))
          (loop (cdr ps) (if (equal? o a) bad (cons (list p 'oracle o 'got a) bad)) (+ n 1))))))
(define (take l n) (if (= n 0) '() (cons (car l) (take (cdr l) (- n 1)))))
(define (pow2 k) (let loop ((i 0) (n 1)) (if (= i k) n (loop (+ i 1) (* n 2)))))

;; ---- ROUTE ----
(define route-points
  (let ((out '()))
    (for-each
     (lambda (cfg)
       (let ((r (car cfg)) (h (cadr cfg)) (yaw (caddr cfg)))
         (for-each
          (lambda (k)
            (set! out (cons (list 2.5 -1.0 r h yaw (+ 2.5 (* k (+ h r) (cos yaw))) (+ -1.0 (* k (+ h r) (sin yaw)))) out)))
          '(0.0 0.3 0.6 1.5 3.0))))
     '((1.0 0.0 0.0) (2.0 3.0 0.7) (0.5 1.0 2.4) (10.0 0.0 4.0) (1e-3 5e-3 5.5)))
    out))
(define before ($field-exact-calls))
(family "ROUTE separated flonum points, each as the oracle says" route-points)
(want "ROUTE none of them reached the exact path" (- ($field-exact-calls) before) 0)
(define before2 ($field-exact-calls))
(answer 0 0 (ex (cos 0.0)) 0 0.0 1 0)
(want "ROUTE control: an exact boundary point does reach it" (> ($field-exact-calls) before2) #t)

(display (if (null? fails) #t (reverse fails)))

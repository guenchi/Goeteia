;; expect: #t
;; field-contains? answers the exact containment of the stated shape
;; (R23: archive/goeteia-r23-design-2026-11-12.md, closed at r3).
;;
;; THE SHAPE (design 2).  With c = (cos yaw) and s = (sin yaw) AS
;; COMPUTED, both finite, the field holds the real points (x, z) with
;;     max(0, |A| - h)^2 + B^2 <= r^2,
;;     A = (x - fx) c + (z - fz) s,   B = (z - fz) c - (x - fx) s,
;; evaluated exactly on the stored values and the two flonums.  A yaw
;; whose computed c or s is not finite holds no point (#f, no error).
;;
;; THE DEFECT.  The predicate computed in flonums, dividing by r: an
;; overflowing difference made an inside point outside (F1), rounding
;; decided points near the boundary either way (F2), and a subnormal
;; radius made the quotients meaningless (F3).
;;
;; THE ORACLE.  `oracle' below is the inequality in exact arithmetic --
;; the specification, with no filter and no bound.  Every row first
;; asserts the oracle's own answer for its data, then that
;; field-contains? gives the same.
;;
;; Rows (base = the tree before the change):
;;   X1  overflowing differences, a half-length that absorbs them: inside
;;       (base: outside), and the outside control with h 0.9e308; mirrors
;;   X2  points within a few ulps of the boundary, along the axis, for a
;;       spread of radii, half-lengths, yaws and centres: each as the
;;       oracle says
;;   X3  subnormal radii 5e-324, 1e-320, 2.2e-308; points at 0, r/2, r,
;;       2r in several directions: each as the oracle says
;;   X4  exact inputs: centre 2^1000 exact, query 2^1000 + 6 exact, r 5:
;;       outside (the two convert to the same flonum); 2^1000 + 4:
;;       inside; an exact centre with ordinary offsets
;;   X5  centre (0,0), h 0, r 1e-125 and 1e-130, yaw 1.206311103215721e30
;;       (computed c = s = -1.29e200), queries exact k 2^-1076, k = 1..4:
;;       each as the oracle says (all outside)
;;   X6  yaw 1.070931672115544e40 (computed c = s = -inf.0): #f for (0,0)
;;       and (1,1), no error
;;   (cells r2, from the pre-review)
;;   X8  exact inputs with opposite conversion errors and a nonzero
;;       rounded difference (a bound four times too small answers it
;;       inside); each of the four coefficient-amplified error terms has
;;       its own row (x and z, at yaw 0 and at yaw pi/2)
;;   X9  exact equality q = t is inside; an exact radius and an exact
;;       half-length are used as given, not rounded
;;   X10 side-boundary controls: just inside and just outside the
;;       straight side of a capsule
;;   (ROUTE, the fast path's use, is test/field-contains-takes-the-fast-
;;   path.ss: it reads an export the tree before the change does not have,
;;   and this file must be read there)
;;   X7  cancellation in the dominant term: points far along the axis,
;;       within the half-length, whose across-distance B = dz c - dx s is
;;       two products of about L minus each other and lands near an
;;       off-grid radius -- where the rounding error comes closest to the
;;       bound.  Sixteen points found by main's search (archive
;;       goeteia-m30-2026-11-12/cells-check) that a bound 16 times too small
;;       answers wrongly; each as the oracle says
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

;; ---- X1 ----
(row "X1 inside: the half-length absorbs an overflowing difference" #t
     -1e308 0.0 1.7e308 1.7e308 0.0 1.7e308 0.0)
(row "X1 outside control: h 0.9e308" #f
     -1e308 0.0 1.7e308 0.9e308 0.0 1.7e308 0.0)
(row "X1 inside, mirrored" #t
     1e308 0.0 1.7e308 1.7e308 0.0 -1.7e308 0.0)
(row "X1 outside control, mirrored" #f
     1e308 0.0 1.7e308 0.9e308 0.0 -1.7e308 0.0)

;; ---- X2 ----
;; along z = fz: A = dx c, B = -dx s.  The boundary dx* is found in
;; flonums (the oracle decides each point), then points within 8 ulps of
;; it on either side.  Two branches: the straight SIDE, where |A| <= h
;; and |B| = r, at dx = r/|s|, when that point's |A| is within h; else the
;; round END CAP, (dx c - h)^2 + (dx s)^2 = r^2 with dx c >= h
(define (boundary-dx r h yaw)
  (let* ((c (abs (cos yaw))) (s (abs (sin yaw))))
    (if (and (> s 0.0) (<= (* (/ r s) c) h))
        (/ r s)
        (let* ((a (+ (* c c) (* s s))) (b (* -2.0 h c)) (cc (- (* h h) (* r r)))
               (disc (- (* b b) (* 4.0 a cc))))
          (/ (+ (- b) (sqrt (max disc 0.0))) (* 2.0 a))))))
(define x2-points
  (let ((out '()))
    (for-each
     (lambda (cfg)
       (let* ((fx (car cfg)) (r (cadr cfg)) (h (caddr cfg)) (yaw (cadddr cfg))
              (d (boundary-dx r h yaw)))
         (let loop ((j -8))
           (when (<= j 8)
             (set! out (cons (list fx 0.0 r h yaw (* (+ fx d) (+ 1.0 (* j 2.220446049250313e-16))) 0.0) out))
             (loop (+ j 1))))))
     '((0.0 5.0 0.0 0.0) (0.0 5.0 2.0 0.0) (12.5 1.5 2.0 0.7) (-3.0 0.25 10.0 1.3)
       (1e6 3.0 1.0 2.9) (1e-3 1e-6 0.0 0.4) (0.0 1e150 1e150 0.2) (7.0 1.0 0.0 3.14159)))
    out))
(family "X2 the boundary band" x2-points)
;; each configuration's 17 points straddle the boundary: the oracle puts
;; some inside and some outside (a band that missed the boundary would be
;; all one side)
(let loop ((ps x2-points) (k 0))
  (unless (null? ps)
    (let* ((cfg (take ps 17))
           (os (map (lambda (p) (apply oracle p)) cfg)))
      (want (string-append "X2 configuration " (number->string k) " straddles the boundary")
            (and (memq #t os) (memq #f os) #t) #t)
      (loop (list-tail ps 17) (+ k 1)))))

;; ---- X3 ----
(define x3-points
  (let ((out '()))
    (for-each
     (lambda (r)
       (for-each
        (lambda (k)
          (for-each
           (lambda (dir)
             (set! out (cons (list 0.0 0.0 r 0.0 0.3 (* k r (car dir)) (* k r (cdr dir))) out)))
           '((1.0 . 0.0) (0.0 . 1.0) (0.6 . 0.8) (-0.8 . 0.6))))
        '(0.0 0.5 1.0 2.0)))
     '(5e-324 1e-320 2.2e-308))
    out))
(family "X3 subnormal radii" x3-points)

;; ---- X4 ----
(define big (pow2 1000))
(row "X4 exact: 2^1000 + 6 against centre 2^1000, r 5: outside" #f big 0 5 0 0.0 (+ big 6) 0)
(row "X4 exact: 2^1000 + 4: inside" #t big 0 5 0 0.0 (+ big 4) 0)
(row "X4 exact centre, ordinary offset inside" #t big 0 5 0 0.0 (+ big 3) 2)
(row "X4 exact centre, ordinary offset outside" #f big 0 5 0 0.0 (+ big 3) 5)

;; ---- X5 ----
(define tiny (/ 1 (pow2 1076)))
(family "X5 huge computed coefficients, exact tiny queries"
        (let loop ((k 1) (out '()))
          (if (> k 4) out
              (loop (+ k 1)
                    (cons (list 0.0 0.0 1e-125 0.0 1.206311103215721e30 (* k tiny) 0)
                          (cons (list 0.0 0.0 1e-130 0.0 1.206311103215721e30 (* k tiny) 0) out))))))
(row "X5 the r1 counterexample: outside" #f 0.0 0.0 1e-125 0.0 1.206311103215721e30 tiny 0)

;; ---- X6 ----
(row "X6 non-finite coefficients: (0,0)" 'none 0.0 0.0 1.0 0.0 1.070931672115544e40 0.0 0.0)
(row "X6 non-finite coefficients: (1,1)" 'none 0.0 0.0 1.0 0.0 1.070931672115544e40 1.0 1.0)

;; ---- X7 ----
;; (x z h r yaw), centre (0, 0)
(define x7-points
  (map (lambda (p) (list 0.0 0.0 (list-ref p 3) (list-ref p 2) (list-ref p 4) (car p) (cadr p)))
       '(
   (316511153.1061466 -184140481.75204915 732357909.9332802 1.9344942085444927 5.756269129924476)
   (1751499536.0257983 -1051023280.6198285 4085290962.026322 1.6707882340997458 5.742713936604559)
   (7.726952677073139e12 -4.664390866108543e12 1.805129799494376e13 1.485175771638751 5.740084798075259)
   (-6.564223795925298e12 -3.351495998295856e12 1.4740632207552893e13 1.2302105780690908 3.6136604929342866)
   (-168349817.49564853 -44957233.643079646 348498573.35531664 1.4981248043477535 3.402549642138183)
   (72084462.06590237 47928969.27280999 173128342.762062 1.213893810287118 0.5867786156013608)
   (2514283353.1904078 -1.1063699123872173e10 2.269158955065174e10 1.4269087351858616 4.935848931781948)
   (8.705206736667772e11 -8.776927722971871e12 1.7639984863696746e13 1.6132278349250555 4.8112485045567155)
   (2.6485758133167675e10 4946470520.660242 5.3887399436285515e10 1.532318389043212 6.467817940749228)
   (-2.0022981678469144e11 3.3103518982599615e11 7.737603671234797e11 1.4064777605235577 2.114781412295997)
   (3.4239841728639825e11 1.8642764757731668e11 7.797228839567174e11 1.2682041302323341 6.781777388416231)
   (-1089861216.6879642 2500952355.531273 5456211196.894221 1.8314811550080776 1.9817609069868922)
   (-41603502.271143936 61701844.216960944 148835062.8178617 1.2474460862576962 2.164042073301971)
   (-6.498092269020013e11 -2.3462774141645747e12 4.869196950458491e12 1.7049069199711084 4.442207728512585)
   (-1.6932457215096645e13 -1.1952428394269979e13 4.1452076032991664e13 1.676805479452014 3.7562597701326013)
   (-82635601.04276097 23581782.28890876 171869054.98806906 1.6019334327429533 2.8636106261983514))))
(family "X7 cancellation in the dominant term" x7-points)

;; ---- X8 ----
(define U (pow2 48))
(define C3 (* 3 (pow2 99)))
(row "X8 opposite conversion errors, nonzero rounded difference: outside" #f
     (- C3 (* 31/64 U)) 0 (* 135/8 U) 0 0.0 (+ C3 (* 16 U) (* 31/64 U)) 0)
(row "X8 the z error amplified by c (yaw 0): outside" #f 0 big 5 0 0.0 0 (+ big 6))
(define half-pi 1.5707963267948966)
(row "X8 the x error amplified by s (yaw pi/2): outside" #f big 0 5 0 half-pi (+ big 6) 0)
(row "X8 the z error amplified by s (yaw pi/2): outside" #f 0 big 5 0 half-pi 0 (+ big 6))

;; ---- X9 ----
(define ce (ex (cos 0.0)))
(define delta (/ 1 (pow2 60)))
(row "X9 exact equality q = t is inside" #t 0 0 ce 0 0.0 1 0)
(row "X9 an exact radius is used as given" #f 0 0 (- ce delta) 0 0.0 1 0)
(row "X9 an exact half-length is used as given" #f 0 0 ce (- ce delta) 0.0 2 0)

;; ---- X10 ----
(define side (/ 0.25 (abs (sin 1.3))))
(row "X10 just inside the straight side" #t -3.0 0.0 0.25 10.0 1.3
     (+ -3.0 (* side (- 1.0 (/ 8.0 (inexact (pow2 52)))))) 0.0)
(row "X10 just outside the straight side" #f -3.0 0.0 0.25 10.0 1.3
     (+ -3.0 (* side (+ 1.0 (/ 8.0 (inexact (pow2 52)))))) 0.0)

(display (if (null? fails) #t (reverse fails)))

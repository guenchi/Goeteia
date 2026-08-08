;; expect: #t
;; (gfx mat) quaternion algebra: q-mul, q-conj, q-neg, q-dot,
;; q-normalize.
;;
;; The laws are the oracle, and they are chosen so that each one
;; fails for a DIFFERENT slip:
;;
;;   * The Hamilton product is judged against the rotation matrices
;;     it must agree with -- R(a*b) = R(a)R(b), through m4-from-quat
;;     and m4-mul, on a pair that does not commute.  Swapping q-mul's
;;     operands leaves associativity, the norm law and the identity
;;     element all intact; it breaks exactly this one, which is why
;;     the pair is asserted non-commuting first.
;;   * The conjugate is judged twice: q * conj q = 1 on a unit
;;     quaternion (which one dropped sign already breaks) and the
;;     anti-homomorphism conj(a*b) = conj(b) * conj(a) (which catches
;;     a sign dropped on the scalar lane, where the first law is
;;     insensitive because the product's vector part cancels anyway).
;;   * q-neg is separated from q-conj by the rotation they induce:
;;     -q is the SAME rotation as q (the double cover), conj q is the
;;     inverse one.  A test that only checked "some signs flip" would
;;     accept either for the other.
;;   * q-normalize is judged for unit norm, idempotence, exactness on
;;     an already-unit input (the divisor is exactly 1.0, so no digit
;;     may move), and the degenerate zero, which answers the identity
;;     rather than four NaNs.
;;   * q-dot must agree with the angle q-slerp travels: q-slerp is
;;     defined in terms of the dot, so acos of the dot between a and
;;     slerp(a, b, t) has to be t times the whole arc.  That ties the
;;     newly exported dot to the operation that was already exported.
(import (rnrs) (gfx mat))

(define pi 3.141592653589793)
(define deg 0.017453292519943295)       ; radians per degree

;; the reader has no exponent syntax
(define eps-9 0.000000001)
(define eps-11 0.00000000001)
(define eps-15 0.000000000000001)

(define (absf x) (if (fl<? x 0.0) (fl- 0.0 x) x))
(define (close? a b tol) (fl<? (absf (fl- a b)) tol))

(define fails '())
(define (chk name ok)
  (unless ok
    (display "  FAIL ") (display name) (newline)
    (set! fails (cons name fails)))
  ok)

;; ---- fixtures ----
;; Axis-angle, normalized on the way out: flcos 0.0 is 1 - 6e-12 in
;; this trig, and an input that far off the sphere would mask the
;; drift the norm laws below look for.
(define (qaa x y z d)                   ; unit axis (x y z), d degrees
  (let* ((h (fl* 0.5 (fl* d deg)))
         (s (flsin h)) (c (flcos h)))
    (q-normalize (vector (fl* s x) (fl* s y) (fl* s z) c))))

(define qid (vector 0.0 0.0 0.0 1.0))
(define qa (qaa 1.0 0.0 0.0 37.0))      ; about x
(define qb (qaa 0.0 1.0 0.0 64.0))      ; about y
(define qc (qaa 0.0 0.0 1.0 113.0))     ; about z
;; one off every axis at once, and deliberately NOT unit on the way
;; in: the norm law and q-normalize both need a non-unit input
(define qw (vector 0.3 -0.5 0.7 1.4))

(define (qnear? p q tol)
  (and (close? (vector-ref p 0) (vector-ref q 0) tol)
       (close? (vector-ref p 1) (vector-ref q 1) tol)
       (close? (vector-ref p 2) (vector-ref q 2) tol)
       (close? (vector-ref p 3) (vector-ref q 3) tol)))

(define (qsame? p q) (qnear? p q eps-15))   ; bit-for-bit in practice

(define (qnorm q) (flsqrt (q-dot q q)))

(define (m4near? a b tol)
  (let loop ((i 0))
    (cond ((= i 16) #t)
          ((close? (vector-ref a i) (vector-ref b i) tol) (loop (+ i 1)))
          (else #f))))

;; ---- q-dot ----
(define dot-ok
  (and
   (chk "dot is symmetric" (fl=? (q-dot qa qb) (q-dot qb qa)))
   (chk "self dot is the squared norm"
        (close? (q-dot qw qw)
                (fl+ (fl+ (fl* 0.3 0.3) (fl* -0.5 -0.5))
                     (fl+ (fl* 0.7 0.7) (fl* 1.4 1.4)))
                eps-15))
   (chk "dot with the identity is the scalar lane"
        (fl=? (q-dot qw qid) 1.4))
   ;; a dot that dropped or doubled a lane would still be symmetric;
   ;; this pins each lane's contribution separately
   (chk "every lane contributes"
        (and (fl=? (q-dot (vector 1.0 0.0 0.0 0.0) qw) 0.3)
             (fl=? (q-dot (vector 0.0 1.0 0.0 0.0) qw) -0.5)
             (fl=? (q-dot (vector 0.0 0.0 1.0 0.0) qw) 0.7)
             (fl=? (q-dot (vector 0.0 0.0 0.0 1.0) qw) 1.4)))
   (chk "a unit quaternion dots itself to one"
        (close? (q-dot qa qa) 1.0 eps-11))))

;; ---- q-normalize ----
(define normalize-ok
  (and
   (chk "normalize lands on the unit sphere"
        (close? (qnorm (q-normalize qw)) 1.0 eps-15))
   (chk "normalize is idempotent"
        (qsame? (q-normalize (q-normalize qw)) (q-normalize qw)))
   ;; the divisor is exactly 1.0 here, so nothing may move at all
   (chk "an exactly unit input comes back untouched"
        (let ((u (vector 0.0 0.0 0.0 1.0)))
          (and (fl=? (vector-ref (q-normalize u) 0) 0.0)
               (fl=? (vector-ref (q-normalize u) 1) 0.0)
               (fl=? (vector-ref (q-normalize u) 2) 0.0)
               (fl=? (vector-ref (q-normalize u) 3) 1.0))))
   (chk "normalize keeps the direction"
        ;; the normalized quaternion is a positive multiple of the
        ;; input: every lane divided by the same norm
        (let* ((n (qnorm qw)) (u (q-normalize qw)))
          (and (close? (fl* (vector-ref u 0) n) (vector-ref qw 0) eps-15)
               (close? (fl* (vector-ref u 1) n) (vector-ref qw 1) eps-15)
               (close? (fl* (vector-ref u 2) n) (vector-ref qw 2) eps-15)
               (close? (fl* (vector-ref u 3) n) (vector-ref qw 3) eps-15))))
   (chk "the zero quaternion normalizes to the identity"
        (qsame? (q-normalize (vector 0.0 0.0 0.0 0.0)) qid))))

;; ---- q-mul ----
;; the pair the composition law is judged on has to not commute, or
;; the law would hold for the operands the other way round too
(define noncommuting-ok
  (chk "the fixture pair does not commute"
       (not (qnear? (q-mul qa qb) (q-mul qb qa) eps-9))))

(define mul-ok
  (and
   (chk "the identity is neutral on both sides"
        (and (qsame? (q-mul qid qa) qa) (qsame? (q-mul qa qid) qa)))
   (chk "the product is associative"
        (qnear? (q-mul (q-mul qa qb) qc) (q-mul qa (q-mul qb qc)) eps-11))
   (chk "the norm is multiplicative"
        (close? (qnorm (q-mul qw qa)) (fl* (qnorm qw) (qnorm qa)) eps-11))
   ;; THE order test: R(a*b) must be R(a) times R(b), which is what
   ;; "post-multiply by a rotation in the joint's own frame" means
   (chk "the product composes rotations in that order"
        (m4near? (m4-from-quat (vector-ref (q-mul qa qb) 0)
                               (vector-ref (q-mul qa qb) 1)
                               (vector-ref (q-mul qa qb) 2)
                               (vector-ref (q-mul qa qb) 3))
                 (m4-mul (m4-from-quat (vector-ref qa 0) (vector-ref qa 1)
                                       (vector-ref qa 2) (vector-ref qa 3))
                         (m4-from-quat (vector-ref qb 0) (vector-ref qb 1)
                                       (vector-ref qb 2) (vector-ref qb 3)))
                 eps-9))
   ;; and the same thing said once more, three deep, so a
   ;; transposition that happened to be self-inverse on a pair still
   ;; shows
   (chk "three compose in order too"
        (m4near? (let ((q (q-mul (q-mul qa qb) qc)))
                   (m4-from-quat (vector-ref q 0) (vector-ref q 1)
                                 (vector-ref q 2) (vector-ref q 3)))
                 (m4-mul (m4-mul (m4-from-quat (vector-ref qa 0)
                                               (vector-ref qa 1)
                                               (vector-ref qa 2)
                                               (vector-ref qa 3))
                                 (m4-from-quat (vector-ref qb 0)
                                               (vector-ref qb 1)
                                               (vector-ref qb 2)
                                               (vector-ref qb 3)))
                         (m4-from-quat (vector-ref qc 0) (vector-ref qc 1)
                                       (vector-ref qc 2) (vector-ref qc 3)))
                 eps-9))
   ;; a rotation of d about an axis, squared, is 2d about it
   (chk "squaring doubles the angle"
        (qnear? (q-mul (qaa 0.0 0.0 1.0 30.0) (qaa 0.0 0.0 1.0 30.0))
                (qaa 0.0 0.0 1.0 60.0) eps-9))))

;; ---- q-conj ----
(define conj-ok
  (and
   ;; the laws first, so a sign slip is reported as the property it
   ;; broke rather than as a lane that read wrong
   (chk "conjugation is an involution" (qsame? (q-conj (q-conj qw)) qw))
   ;; on a quaternion with every lane non-zero: qa is a rotation
   ;; about x alone, and a sign dropped on the y or z lane of the
   ;; conjugate would multiply against a zero and vanish
   (chk "a unit quaternion times its conjugate is the identity"
        (let ((u (q-normalize qw)))
          (and (qnear? (q-mul u (q-conj u)) qid eps-11)
               (qnear? (q-mul (q-conj u) u) qid eps-11)
               (qnear? (q-mul qa (q-conj qa)) qid eps-11))))
   ;; on a NON-unit input the product is the squared norm in the
   ;; scalar lane, not the identity -- the documented sharp edge
   (chk "a non-unit quaternion times its conjugate is its squared norm"
        (qnear? (q-mul qw (q-conj qw))
                (vector 0.0 0.0 0.0 (q-dot qw qw)) eps-11))
   ;; the anti-homomorphism: conjugation REVERSES the product
   (chk "conjugation reverses a product"
        (qnear? (q-conj (q-mul qa qb)) (q-mul (q-conj qb) (q-conj qa))
                eps-11))
   (chk "and is not the forward homomorphism"
        (not (qnear? (q-conj (q-mul qa qb)) (q-mul (q-conj qa) (q-conj qb))
                     eps-9)))
   ;; and the lanes themselves, so a slip that somehow satisfied
   ;; every law above still has nowhere to hide
   (chk "the scalar lane survives conjugation"
        (fl=? (vector-ref (q-conj qw) 3) (vector-ref qw 3)))
   (chk "every vector lane is negated"
        (and (fl=? (vector-ref (q-conj qw) 0) -0.3)
             (fl=? (vector-ref (q-conj qw) 1) 0.5)
             (fl=? (vector-ref (q-conj qw) 2) -0.7)))
   (chk "the conjugate rotation is the inverse rotation"
        (m4near? (let ((q (q-mul qa (q-conj qb))))
                   (m4-from-quat (vector-ref q 0) (vector-ref q 1)
                                 (vector-ref q 2) (vector-ref q 3)))
                 (m4-mul (m4-from-quat (vector-ref qa 0) (vector-ref qa 1)
                                       (vector-ref qa 2) (vector-ref qa 3))
                         (m4-from-quat (vector-ref (qaa 0.0 1.0 0.0 -64.0) 0)
                                       (vector-ref (qaa 0.0 1.0 0.0 -64.0) 1)
                                       (vector-ref (qaa 0.0 1.0 0.0 -64.0) 2)
                                       (vector-ref (qaa 0.0 1.0 0.0 -64.0) 3)))
                 eps-9))))

;; ---- q-neg ----
(define neg-ok
  (and
   (chk "negation is an involution" (qsame? (q-neg (q-neg qw)) qw))
   (chk "every lane is negated, the scalar one included"
        (and (fl=? (vector-ref (q-neg qw) 0) -0.3)
             (fl=? (vector-ref (q-neg qw) 1) 0.5)
             (fl=? (vector-ref (q-neg qw) 2) -0.7)
             (fl=? (vector-ref (q-neg qw) 3) -1.4)))
   (chk "negation flips the sign of a dot"
        (close? (q-dot (q-neg qa) qb) (fl- 0.0 (q-dot qa qb)) eps-15))
   (chk "negation passes through a product"
        (qsame? (q-mul (q-neg qa) qb) (q-neg (q-mul qa qb))))
   ;; the double cover: -q and q are the same rotation, which is what
   ;; separates q-neg from q-conj
   (chk "the negated quaternion is the SAME rotation"
        (m4near? (m4-from-quat (vector-ref (q-neg qa) 0)
                               (vector-ref (q-neg qa) 1)
                               (vector-ref (q-neg qa) 2)
                               (vector-ref (q-neg qa) 3))
                 (m4-from-quat (vector-ref qa 0) (vector-ref qa 1)
                               (vector-ref qa 2) (vector-ref qa 3))
                 eps-11))
   (chk "the conjugated one is not"
        (not (m4near? (m4-from-quat (vector-ref (q-conj qa) 0)
                                    (vector-ref (q-conj qa) 1)
                                    (vector-ref (q-conj qa) 2)
                                    (vector-ref (q-conj qa) 3))
                      (m4-from-quat (vector-ref qa 0) (vector-ref qa 1)
                                    (vector-ref qa 2) (vector-ref qa 3))
                      eps-9)))))

;; ---- the dot against q-slerp ----
;; slerp travels the arc at a constant rate, and the arc is measured
;; by the dot, so acos of the dot between a and slerp(a, b, t) is t
;; times the whole angle.  This is the tie between the operation that
;; was already exported and the one that has just been.
(define slerp-dot-ok
  (let* ((a qa)
         (b qc)
         (d (q-dot a b))
         (sgn (if (fl<? d 0.0) -1.0 1.0))
         (whole (flacos (fl* sgn d))))
    (and
     (chk "the fixture arc is worth measuring" (fl<? 0.2 whole))
     (chk "the dot grows as the arc is travelled"
          (let loop ((i 1))
            (if (= i 10)
                #t
                (let* ((t (fl/ (exact->inexact i) 10.0))
                       (m (q-slerp a b t))
                       (dm (q-dot a m))
                       (part (flacos (fl* (if (fl<? dm 0.0) -1.0 1.0) dm))))
                  (if (close? part (fl* t whole) eps-9)
                      (loop (+ i 1))
                      #f)))))
     (chk "slerp at 0 is a, at 1 is b up to the double cover"
          (and (qnear? (q-slerp a b 0.0) a eps-11)
               (let ((e (q-slerp a b 1.0)))
                 (or (qnear? e b eps-9) (qnear? e (q-neg b) eps-9))))))))

(and dot-ok normalize-ok noncommuting-ok mul-ok conj-ok neg-ok
     slerp-dot-ok (null? fails))

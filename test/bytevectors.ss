;; expect: #t
(define bv (make-bytevector 3 255))
(bytevector-u8-set! bv 1 7)
(and (bytevector? bv)
     (not (bytevector? "str"))
     (not (string? bv))
     (not (symbol? bv))
     (eq? (bytevector-length bv) 3)
     (eq? (bytevector-u8-ref bv 0) 255)
     (eq? (bytevector-u8-ref bv 1) 7)
     (bytevector=? (bytevector 1 2) (bytevector 1 2))
     (not (bytevector=? (bytevector 1) (bytevector 2)))
     (string=? (utf8->string (bytevector 104 105)) "hi")
     (bytevector=? (string->utf8 "hi") (bytevector 104 105))

     ;; equal? compares bytevectors by content, like the other
     ;; aggregates.  It used to fall through to eqv?, so it answered #f
     ;; for every pair of distinct bytevector objects -- and the
     ;; failure direction was the quiet one: an assertion that two
     ;; bytevectors DIFFER was satisfied for free, by all of them.
     ;; That is why the negative rows below are split by path rather
     ;; than written as one "they differ" check.
     (equal? (bytevector 1 2 255) (bytevector 1 2 255))
     (equal? (bytevector) (bytevector))
     (not (equal? (bytevector 1 2) (bytevector 1 3)))   ; same length
     (not (equal? (bytevector 1 2) (bytevector 1 2 3))) ; different length
     (not (equal? (bytevector 1 2) (vector 1 2)))       ; different type
     ;; and inside a container, which reaches the new branch through
     ;; equal?'s own recursion rather than directly
     (equal? (list 1 (bytevector 1 2)) (list 1 (bytevector 1 2)))
     (not (equal? (list 1 (bytevector 1 2)) (list 1 (bytevector 1 3))))
     (equal? (vector (bytevector 9)) (vector (bytevector 9))))

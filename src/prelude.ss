;; schwasm prelude: the runtime library, written in schwasm's own
;; Scheme and compiled into every module.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(define (newline) (%write-byte 10))

(define (display x)
  (cond
   ((number? x) (%display-number x))
   ((char? x) (%write-byte (char->integer x)))
   ((string? x) (%display-string x 0))
   ((symbol? x) (%display-string (symbol->string x) 0))
   ((null? x) (%write-byte 40) (%write-byte 41))
   ((eq? x #t) (%write-byte 35) (%write-byte 116))
   ((eq? x #f) (%write-byte 35) (%write-byte 102))
   ((pair? x)
    (%write-byte 40)
    (display (car x))
    (%display-tail (cdr x)))
   ((procedure? x) (%display-string "#<procedure>" 0))
   (else (%display-string "#<unknown>" 0))))

(define (%display-tail x)
  (cond
   ((null? x) (%write-byte 41))
   ((pair? x)
    (%write-byte 32)
    (display (car x))
    (%display-tail (cdr x)))
   (else
    (%write-byte 32) (%write-byte 46) (%write-byte 32)
    (display x)
    (%write-byte 41))))

(define (%display-string s i)
  (when (< i (string-length s))
    (%write-byte (char->integer (string-ref s i)))
    (%display-string s (+ i 1))))

(define (%display-number n)
  (if (< n 0)
      (begin (%write-byte 45) (%display-digits (- 0 n)))
      (%display-digits n)))

(define (%display-digits n)
  (if (< n 10)
      (%write-byte (+ 48 n))
      (begin
        (%display-digits (quotient n 10))
        (%write-byte (+ 48 (remainder n 10))))))

(define (string=? a b)
  (and (= (string-length a) (string-length b))
       (%string-eq-from a b 0)))

(define (%string-eq-from a b i)
  (or (= i (string-length a))
      (and (eq? (string-ref a i) (string-ref b i))
           (%string-eq-from a b (+ i 1)))))

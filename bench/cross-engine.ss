;; the cross-engine benchmark: results land in globalThis.__bench
(import (rnrs) (web js) (gfx mat) (gfx collide))
(define (now) (js->number (js-eval "Date.now()")))
(define out "")
(define (report! name ms)
  (set! out (string-append out name ":" (number->string ms) "ms ")))

;; m4-mul, boxed vectors
(define A (m4-perspective 0.9 1.5 0.1 100.0))
(define B (m4-look-at (v3 3.0 4.0 5.0) (v3 0.0 1.0 0.0) (v3 0.0 1.0 0.0)))
(let ((t0 (now)))
  (let loop ((i 0) (m A))
    (if (< i 100000)
        (loop (+ i 1) (m4-mul A B))
        (report! "m4mul-100k" (- (now) t0)))))

;; flsin, the polynomial
(let ((t0 (now)))
  (let loop ((i 0) (acc 0.0))
    (if (< i 1000000)
        (loop (+ i 1) (fl+ acc (flsin (fl* 0.0001 (fixnum->flonum i)))))
        (begin (when (fl<? acc -1.0) (display acc))
               (report! "flsin-1m" (- (now) t0))))))

;; the character controller
(define boxes
  (list (cons (v3 -20.0 -1.0 -20.0) (v3 20.0 0.0 20.0))
        (cons (v3 3.0 0.0 -20.0) (v3 4.0 6.0 20.0))
        (cons (v3 -8.0 0.0 -2.0) (v3 -6.0 3.0 2.0))
        (cons (v3 6.0 0.0 6.0) (v3 9.0 2.0 9.0))))
(define ch (make-character (v3 0.0 3.0 0.0) 0.5))
(let ((t0 (now)))
  (let loop ((k 0))
    (if (< k 200000)
        (begin (character-move! ch 2.0 1.5 0.008333 boxes)
               (loop (+ k 1)))
        (report! "char-200k" (- (now) t0)))))

;; the frustum cull
(define planes (m4-frustum-planes
                (m4-mul (m4-perspective 0.9 1.5 0.1 100.0)
                        (m4-look-at (v3 0.0 2.0 8.0) (v3 0.0 0.0 0.0)
                                    (v3 0.0 1.0 0.0)))))
(let ((t0 (now)))
  (let loop ((k 0) (hits 0))
    (if (< k 2000000)
        (let ((x (fl- (fl* 0.00002 (fixnum->flonum k)) 20.0)))
          (loop (+ k 1)
                (if (sphere-in-frustum-xyz? planes x 0.0 -5.0 1.0)
                    (+ hits 1) hits)))
        (begin (when (= hits -1) (display hits))
               (report! "cull-2m" (- (now) t0))))))

(js-set! (js-global) "__bench" out)

;; expect: #t
;; A begin of two or more forms that is the ONLY argument of a call, or the
;; only binding of a let, is one value: its last form's.
;;
;; The JavaScript target answered with two arguments instead.  Its text pass
;; that removes a pair of parentheses sitting directly inside another
;; (jsquash) took a call's own parentheses for such a pair: f(((a),(b)))
;; became f((a),(b)), so the callee got the first form's value and, when it
;; takes a rest, the last as a second argument.  With two or more arguments
;; the call's parentheses hold a comma at the top and nothing was removed,
;; which is why only the single-argument shape was wrong.  wasm was right.
;;
;; Rows:
;;   rest    a procedure with a rest parameter sees one argument
;;   fixed   a one-parameter procedure gets the last form's value
;;   prim    list, vector, pair?, not and length-of-list as the callee (pair?
;;           and not are emitted as operators and were right)
;;   let     the only binding of a let; of a named let; a let*
;;   lambda  a lambda applied where it is written
;;   three   three forms; a begin inside a begin
;;   tail    the call in tail position of its procedure (right before, too)
;;   two     CONTROL: with a second argument both targets were right
;; Each row's form is itself the only argument of a list, so that it is in
;; expression position: in tail position the JavaScript target passes the
;; arguments as an array and was right.  A row that raises answers `raised';
;; no row does arithmetic on what it received, because a host error from a
;; wrong argument is not something a guard catches.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

(define t 0)
(define (all . xs) xs)
(define (same x) x)
(define (tail-call) (same (begin (set! t 40) 41)))

(want 'rest (guard (e (#t 'raised)) (list (all (begin (set! t 1) 7)))) (list '(7)))
(want 'rest-pure (guard (e (#t 'raised)) (list (all (begin 1 2)))) (list '(2)))
(want 'fixed (guard (e (#t 'raised)) (list (same (begin (set! t 2) 9)))) (list 9))
(want 'prim-list (guard (e (#t 'raised)) (list (list (begin (set! t 3) 5)))) (list '(5)))
(want 'prim-vector (guard (e (#t 'raised)) (list (vector (begin (set! t 4) 8)))) (list '#(8)))
(want 'prim-pair? (guard (e (#t 'raised)) (list (pair? (begin (set! t 5) '(a b))))) (list #t))
(want 'prim-not (guard (e (#t 'raised)) (list (not (begin (set! t 6) #f)))) (list #t))
(want 'prim-length (guard (e (#t 'raised)) (list (length (list (begin 1 2))))) (list 1))
(want 'let (guard (e (#t 'raised)) (list (let ((a (begin (set! t 7) 11))) a))) (list 11))
(want 'let-uses-effect (guard (e (#t 'raised)) (list (let ((a (begin (set! t 8) (+ t 1)))) (list a t)))) (list '(9 8)))
(want 'named-let (guard (e (#t 'raised)) (list (let loop ((a (begin (set! t 9) 'start))) (if (eq? a 'start) (loop 'again) a)))) (list 'again))
(want 'let* (guard (e (#t 'raised)) (list (let* ((a (begin (set! t 10) 4))) (list a)))) (list '(4)))
(want 'lambda (guard (e (#t 'raised)) (list ((lambda (a) (list a)) (begin (set! t 11) 12)))) (list '(12)))
(want 'three (guard (e (#t 'raised)) (list (all (begin (set! t 12) (set! t 13) t)))) (list '(13)))
(want 'nested (guard (e (#t 'raised)) (list (same (begin (begin (set! t 14) 1) (begin 2 3))))) (list 3))
(want 'tail (guard (e (#t 'raised)) (list (tail-call))) (list 41))
(want 'two (guard (e (#t 'raised)) (list (all (begin (set! t 15) 1) (begin (set! t 16) 2)))) (list '(1 2)))
(display (if (null? fails) #t (reverse fails)))

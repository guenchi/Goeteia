;; expect: #t
;; (sim events): a topic bus whose subscriptions are cancellable tokens.
;; Dispatch walks a snapshot, so a listener added while an emit is running
;; hears the next one and not this one, and a listener removed during an
;; emit does not run even though the snapshot still holds it.  Emitting
;; from inside a listener is allowed and bounded: past a depth limit it is
;; a named error rather than an exhausted stack.
(import (rnrs) (sim events))

(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

(define log '())
(define (note! x) (set! log (cons x log)))

(define basic-ok
  (let ((b (make-bus)))
    (bus-on! b 'hit (lambda (p) (note! (list 'a p))))
    (bus-on! b 'miss (lambda (p) (note! (list 'b p))))
    (set! log '())
    (bus-emit! b 'hit 7)
    (and (equal? log '((a 7)))
         (begin (bus-emit! b 'nobody 1) (equal? log '((a 7)))))))

(define off-ok
  (let* ((b (make-bus)) (t (bus-on! b 'x (lambda (p) (note! 'x)))))
    (set! log '())
    (bus-off! t)
    (bus-emit! b 'x 1)
    (and (null? log) (begin (bus-off! t) #t))))       ; removing twice is quiet

;; ---- a listener added during an emit waits for the next one ----
(define snapshot-ok
  (let ((b (make-bus)))
    (bus-on! b 'tick (lambda (p)
                       (note! 'first)
                       (bus-on! b 'tick (lambda (q) (note! 'late)))))
    (set! log '())
    (bus-emit! b 'tick 1)
    (and (equal? (reverse log) '(first))
         (begin (set! log '())
                (bus-emit! b 'tick 2)
                (equal? (reverse log) '(first late))))))

;; ---- a listener removed during an emit does not run ----
(define removal-ok
  (let* ((b (make-bus)) (second #f))
    (bus-on! b 'tick (lambda (p) (note! 'one) (bus-off! second)))
    (set! second (bus-on! b 'tick (lambda (p) (note! 'two))))
    (set! log '())
    (bus-emit! b 'tick 1)
    (equal? (reverse log) '(one))))

;; ---- emitting inside a listener runs to completion, and cannot run away ----
(define nested-ok
  (let ((b (make-bus)) (b2 (make-bus)))
    (bus-on! b 'outer (lambda (p) (note! 'outer-in) (bus-emit! b 'inner p) (note! 'outer-out)))
    (bus-on! b 'inner (lambda (p) (note! 'inner)))
    (set! log '())
    (bus-emit! b 'outer 1)
    (and (equal? (reverse log) '(outer-in inner outer-out))
         (begin (bus-on! b2 'loop (lambda (p) (bus-emit! b2 'loop p)))
                (refused? 'bus-emit! (lambda () (bus-emit! b2 'loop 1)))))))

(define clear-ok
  (let ((b (make-bus)))
    (bus-on! b 'x (lambda (p) (note! 'x)))
    (bus-clear! b)
    (set! log '())
    (bus-emit! b 'x 1)
    (null? log)))

(display (and (report "basic" basic-ok) (report "off" off-ok)
              (report "snapshot" snapshot-ok) (report "removal" removal-ok)
              (report "nested" nested-ok) (report "clear" clear-ok)))
(newline)

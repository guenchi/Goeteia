;; expect: #t
;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; The eight defects an independent review found in (lng machine)
;; after the first round of fixes, one cell each.  Three of them --
;; A, B and C -- were the same shape: a silent "the first one wins"
;; rule, in the bindings alist, in the spec clauses and in the option
;; list.  A library whose whole claim is "where you write a line does
;; not matter" cannot have three of those.
;;
;; Kept as a probe rather than folded into test/lng-machine.ss so the
;; findings stay legible as findings; the suite's own cells cover the
;; same ground in the shape the suite wants.
(import (rnrs) (lng machine))

(define S '((states (a b)) (initial a) (transitions ((a go b)))))
(define G '((states (a b)) (initial a) (transitions ((a go b g)))))
(define (yes) (lambda (ctx) #t))
(define (no) (lambda (ctx) #f))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

;; A. one name bound twice: which lambda runs decided where the pair sat
(define a-ok
  (and (refused? 'make-machine
                 (lambda () (make-machine G (list (cons 'g (yes)) (cons 'g (no))))))
       (refused? 'make-machine
                 (lambda () (make-machine G (list (cons 'g (no)) (cons 'g (yes))))))))

;; B. a clause given twice: the first occurrence used to win, silently
(define b-ok
  (and (refused? 'make-machine
                 (lambda () (make-machine '((states (a b)) (initial a) (initial b)
                                            (transitions ((a go b) (b go a)))) '())))
       ;; the worst one: which line came first decided how hard the
       ;; spec was checked
       (refused? 'make-machine
                 (lambda () (make-machine '((states (a b c)) (initial a) (transitions ((a go b))))
                                          '() #f '((strict #f) (strict #t)))))
       (refused? 'make-machine
                 (lambda () (make-machine S '() #f '((strict)))))))

;; C. a bindings entry that is not a pair: assq trapped in the host,
;;    outside any guard the caller could write -- and only when no
;;    earlier entry happened to match first
(define c-ok
  (and (refused? 'make-machine (lambda () (make-machine G (list 'garbage))))
       (refused? 'make-machine
                 (lambda () (make-machine G (list (cons 'g (yes)) 'garbage))))
       (refused? 'make-machine (lambda () (make-machine G (list (cons 'g 42)))))))

;; D. a state that is not a symbol: accepted, and then the deep copy
;;    gave the label in `states' and the one in `initial' separate
;;    identities, so the machine could not read its own round trip
(define d-ok
  (refused? 'make-machine
            (lambda () (make-machine (list (list 'states (list (list 'label)))
                                           (list 'initial (list 'label))
                                           '(transitions ()))
                                     '()))))

;; E. only ctx was checked for being a datum, so a procedure could sit
;;    in the spec -- and machine->datum handed it back inside what it
;;    called a datum
(define e-ok
  (and (refused? 'make-machine
                 (lambda () (make-machine (cons (list 'metadata (lambda () #t)) S) '())))
       (refused? 'make-machine
                 (lambda () (make-machine S '() '() (list (list 'strict (lambda () #t))))))))

;; F. the deep copy stopped at the mutable leaves: a string in the
;;    spec was still shared with whatever the accessor handed out
(define f-ok
  (let* ((text (string-copy "before"))
         (m (make-machine (cons (list 'note text) S) '()))
         (exported (machine-spec m)))
    (string-set! (cadr (assq 'note exported)) 0 #\a)
    (string-set! text 0 #\z)
    (string=? (cadr (assq 'note (machine-spec m))) "before")))

;; G. a bytevector is a datum; the whitelist had forgotten it
(define g-ok
  (machine? (make-machine S '() (make-bytevector 2))))

;; H. a cyclic input used to walk forever.  Both halves matter: the
;;    rejection has to happen, AND the irritant must not carry the
;;    structure -- printing it is the same walk that hung.
(define h-ok
  (let ((x (list 'a)))
    (set-cdr! x x)
    (and (refused? 'make-machine (lambda () (make-machine S '() x)))
         (refused? 'make-machine (lambda () (make-machine (cons (list 'note x) S) '())))
         (guard (e (#t (let loop ((l (condition-irritants e)))
                         (cond
                          ((null? l) #t)
                          ((pair? (car l)) #f)     ; nothing structural came out
                          (else (loop (cdr l)))))))
           (make-machine S '() x)
           #f))))

(let ((all (list (report "A dup binding" a-ok) (report "B dup clause" b-ok)
                 (report "C binding shape" c-ok) (report "D state symbol" d-ok)
                 (report "E spec datum" e-ok) (report "F mutable leaf" f-ok)
                 (report "G bytevector" g-ok) (report "H cycle" h-ok))))
  (let loop ((l all)) (or (null? l) (and (car l) (loop (cdr l))))))

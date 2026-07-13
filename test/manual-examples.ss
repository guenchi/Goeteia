;; expect: #t
;; Executable check of every concrete example in the developer manual
;; (manual.md, kept on the website branch). If the manual claims an
;; output, it is verified here; keep this in sync with the manual so
;; its examples cannot rot. Runs through both compiler stages.
(import (web reactive) (web sx) (web js) (web dom) (web react))

(define (kid el i) (js-index (js-get el "children") i))
(js-eval "globalThis.document = { createElement: t => ({ tag:t, children:[], attrs:{}, listeners:{}, appendChild(c){const j=this.children.indexOf(c);if(j>=0)this.children.splice(j,1);this.children.push(c);return c}, replaceChild(n,o){const i=this.children.indexOf(o);if(i>=0)this.children[i]=n;return o}, insertBefore(n,r){const j=this.children.indexOf(n);if(j>=0)this.children.splice(j,1);const i=this.children.indexOf(r);this.children.splice(i<0?this.children.length:i,0,n);return n}, removeChild(c){const i=this.children.indexOf(c);if(i>=0)this.children.splice(i,1);return c}, setAttribute(k,v){this.attrs[k]=v}, removeAttribute(k){delete this.attrs[k]}, addEventListener(t,f){this.listeners[t]=f}, fire(t){this.listeners[t]({})} }), createTextNode: s => ({text:s}) }")

;;; --- toolchain / program structure / numeric tower ---
(define logic-ok
  (and
   (string=? (number->string (let f ((n 20)) (if (zero? n) 1 (* n (f (- n 1))))))
             "2432902008176640000")
   (string=? (number->string (+ 536870911 1)) "536870912")   ; fixnum overflow
   (string=? (number->string (/ 1 3)) "1/3")
   (string=? (number->string (* 2 (/ 1 3))) "2/3")
   (string=? (number->string (+ (/ 1 2) 0.5)) "1.0")
   ;; inexactness is contagious across the parts, as under Chez
   (string=? (number->string (sqrt -1)) "0.0+1.0i")
   (string=? (number->string (make-rectangular 1 2)) "1+2i")))

;;; --- ports, write, hashtables, gensym, errors, continuations ---
(define runtime-ok
  (and
   (string=? (let ((o (open-output-string))) (display "hello" o) (get-output-string o))
             "hello")
   (= (read (open-input-string "5")) 5)
   (string=? (with-output-to-string (lambda () (write (list 1 2 3)))) "(1 2 3)")
   ;; hashtables: eq and equal? forms, absent -> default
   (let ((ht (make-eq-hashtable)))
     (hashtable-set! ht 'name "Alice")
     (and (string=? (hashtable-ref ht 'name #f) "Alice")
          (eq? (hashtable-ref ht 'missing #f) #f)))
   (let ((eqht (make-hashtable equal-hash equal?)))
     (hashtable-set! eqht (list 1 2) "pair")
     (string=? (hashtable-ref eqht (list 1 2) #f) "pair"))
   ;; gensym: required prefix, fresh each call
   (let ((a (gensym "x")) (b (gensym "x")))
     (and (not (eq? a b))
          (char=? (string-ref (symbol->string a) 0) #\x)))
   ;; guard / error / condition-message
   (string=? (guard (e ((error? e) (condition-message e)))
               (error 'sqrt "negative argument" -1))
             "negative argument")
   ;; escape continuation
   (= (call/cc (lambda (escape)
                 (for-each (lambda (x) (when (zero? (remainder x 7)) (escape x)))
                           '(1 2 3 7 14 21))
                 0))
      7)
   ;; dynamic-wind order
   (string=? (with-output-to-string
               (lambda () (dynamic-wind (lambda () (display "enter"))
                                        (lambda () (display "body"))
                                        (lambda () (display "exit")))))
             "enterbodyexit")))

;;; --- reactivity ---
(define count (signal 0))
(define doubled (signal 0))
(effect (lambda () (signal-set! doubled (* (signal-ref count) 2))))
(signal-set! count 5)
(define batch-a (signal 0))
(define batch-b (signal 0))
(define batch-runs 0)
(effect (lambda () (signal-ref batch-a) (signal-ref batch-b)
                (set! batch-runs (+ batch-runs 1))))
(batch (lambda () (signal-set! batch-a 1) (signal-set! batch-b 2)))
(define reactive-ok
  (and (= (signal-ref doubled) 10)      ; effect recomputed
       (= batch-runs 2)))               ; initial + one coalesced rerun

;;; --- sx template + keyed list ---
(define n (signal 0))
(define view
  (sx (div (@ (id "counter") (class "app"))
        (span ,(signal-ref n))
        (button (@ (on-click ,(lambda _ (signal-update! n (lambda (v) (+ v 1)))))) "+"))))
(js-method (kid view 1) "fire" "click")
(define todos (signal (list (cons 1 "a") (cons 2 "b"))))
(define lst (sx-list (lambda () (signal-ref todos))
                     (lambda (todo)
                       (sx (li (@ (id ,(number->string (car todo)))) (span ,(cdr todo)))))
                     car))
(define node1 (kid lst 0))
(signal-set! todos (list (cons 2 "b") (cons 1 "a")))
(define sx-ok
  (and (string=? (js->string (js-get (kid (kid view 0) 0) "text")) "1")  ; child hole updated
       (js-eq? (kid lst 1) node1)))     ; keyed node survived the reorder

;;; --- react interop ---
(react-component "Counter"
  (lambda (container props)
    (let ((start (let ((v (props-ref props "start"))) (if v (js->number v) 0))))
      (define c (signal start))
      (sx-mount container (sx (div (span ,(signal-ref c))))))))
(define host (js-method (js-get (js-global) "document") "createElement" "div"))
(js-call (js-get (js-get (js-global) "__goeteia") "Counter")
         (js-undefined) host (js-eval "({start:7})"))
(define react-ok
  (string=? (js->string (js-get (kid (kid (kid host 0) 0) 0) "text")) "7"))

(and logic-ok runtime-ok reactive-ok sx-ok react-ok)

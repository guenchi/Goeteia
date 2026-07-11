;; expect: #t
;; TodoMVC as the acceptance test for the web stack: signals hold the
;; model, sx renders it, a keyed sx-list reconciles the visible rows,
;; and the whole thing runs headless against a mock DOM.
(import (web reactive) (web sx) (web js) (web dom))

(js-eval "globalThis.document = { createElement: t => ({ tag: t, children: [], attrs: {}, listeners: {}, appendChild(c){ const j = this.children.indexOf(c); if (j >= 0) this.children.splice(j, 1); this.children.push(c); return c }, replaceChild(n,o){ const i = this.children.indexOf(o); if (i >= 0) this.children[i] = n; return o }, insertBefore(n,r){ const j = this.children.indexOf(n); if (j >= 0) this.children.splice(j, 1); const i = this.children.indexOf(r); this.children.splice(i < 0 ? this.children.length : i, 0, n); return n }, removeChild(c){ const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); return c }, setAttribute(k,v){ this.attrs[k] = v }, removeAttribute(k){ delete this.attrs[k] }, addEventListener(t,f){ this.listeners[t] = f }, set textContent(s){ this.children.length = 0 }, fire(t,ev){ this.listeners[t](ev === undefined ? {} : ev) } }), createTextNode: s => ({ text: s }) }")

(define (kid el i) (js-index (js-get el "children") i))
(define (kid-count el) (js->number (js-get (js-get el "children") "length")))
(define (kid-text el i) (js->string (js-get (kid el i) "text")))
(define (attr el name) (js->string (js-get (js-get el "attrs") name)))
(define (click el) (js-method el "fire" "click"))

;;; the app

(define-record-type (todo make-todo todo?)
  (fields (immutable id todo-id)
          (immutable text todo-text)
          (immutable done todo-done)))  ; done is a signal

(define todos (signal '()))
(define flt (signal 'all))
(define next-id 0)

(define input (create-element "input"))

(define (add-todo!)
  (let ((text (js->string (js-get input "value"))))
    (unless (string=? text "")
      (set! next-id (+ next-id 1))
      (signal-update! todos
        (lambda (ts)
          (append ts (list (make-todo next-id text (signal #f)))))))))

(define (visible? t)
  (case (signal-ref flt)
    ((all) #t)
    ((active) (not (signal-ref (todo-done t))))
    (else (signal-ref (todo-done t)))))

(define (active-count)
  (length (filter (lambda (t) (not (signal-ref (todo-done t))))
                  (signal-ref todos))))

(define (render-todo t)
  (sx (li (@ (class ,(if (signal-ref (todo-done t)) "done" "")))
        (button (@ (class "toggle")
                   (on-click ,(lambda _
                                (signal-update! (todo-done t)
                                                (lambda (d) (not d))))))
          "o")
        (span ,(todo-text t))
        (button (@ (class "del")
                   (on-click ,(lambda _
                                (signal-update! todos
                                  (lambda (ts)
                                    (filter (lambda (x) (not (eq? x t)))
                                            ts))))))
          "x"))))

(define app
  (sx (div
        ,input
        (button (@ (id "add") (on-click ,(lambda _ (add-todo!)))) "add")
        ,(sx-list (lambda () (filter visible? (signal-ref todos)))
                  render-todo
                  todo-id)
        (span (@ (id "count")) ,(active-count)))))

(define add-btn (kid app 1))
(define rows (kid app 2))
(define counter (kid app 3))
(define (row i) (kid rows i))
(define (row-text i) (kid-text (kid (row i) 1) 0))
(define (count-text) (kid-text counter 0))

;;; the session

(define (add! s)
  (js-set! input "value" s)
  (click add-btn))
(add! "a") (add! "b") (add! "c")
(add! "")                               ; empty input is ignored
(define added-ok
  (and (= (kid-count rows) 3)
       (string=? (row-text 0) "a") (string=? (row-text 2) "c")
       (string=? (count-text) "3")))

;; toggle b: count drops, row gets the done class
(click (kid (row 1) 0))
(define toggled-ok
  (and (string=? (count-text) "2")
       (string=? (attr (row 1) "class") "done")
       (string=? (attr (row 0) "class") "")))

;; filters re-use surviving rows
(signal-set! flt 'active)
(define active-ok
  (and (= (kid-count rows) 2)
       (string=? (row-text 0) "a") (string=? (row-text 1) "c")))
(signal-set! flt 'done)
(define done-ok
  (and (= (kid-count rows) 1) (string=? (row-text 0) "b")))
(signal-set! flt 'all)
(define all-ok (= (kid-count rows) 3))

;; delete b, then toggle a
(click (kid (row 1) 2))
(define deleted-ok
  (and (= (kid-count rows) 2)
       (string=? (row-text 0) "a") (string=? (row-text 1) "c")
       (string=? (count-text) "2")))
(click (kid (row 0) 0))
(define final-ok
  (and (string=? (count-text) "1")
       (string=? (attr (row 0) "class") "done")))

(and added-ok toggled-ok active-ok done-ok all-ok deleted-ok final-ok)

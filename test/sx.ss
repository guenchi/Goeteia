;; expect: #t
;; sx templates against a mock DOM: static structure built once,
;; holes update in place, listeners drive signals.
(import (web reactive) (web sx) (web js))

(js-eval "globalThis.document = { createElement: t => ({ tag: t, children: [], attrs: {}, listeners: {}, appendChild(c){ this.children.push(c); return c }, replaceChild(n,o){ const i = this.children.indexOf(o); if (i >= 0) this.children[i] = n; return o }, setAttribute(k,v){ this.attrs[k] = v }, removeAttribute(k){ delete this.attrs[k] }, addEventListener(t,f){ this.listeners[t] = f }, set textContent(s){ this.children.length = 0 }, fire(t,ev){ this.listeners[t](ev === undefined ? {} : ev) } }), createTextNode: s => ({ text: s }) }")

(define (kid el i) (js-index (js-get el "children") i))
(define (kid-count el) (js->number (js-get (js-get el "children") "length")))
(define (kid-text el i) (js->string (js-get (kid el i) "text")))
(define (attr el name) (js->string (js-get (js-get el "attrs") name)))
(define (tag el) (js->string (js-get el "tag")))

(define n (signal 0))
(define clicks 0)
(define view
  (sx (div (@ (class "counter") (data-x ,(* 2 (signal-ref n))))
        (h1 "Count")
        (span ,(signal-ref n))
        (button (@ (on-click ,(lambda (ev)
                                (set! clicks (+ clicks 1))
                                (signal-update! n (lambda (v) (+ v 1))))))
          "+"))))

(define static-ok
  (and (string=? (tag view) "div")
       (string=? (attr view "class") "counter")
       (string=? (tag (kid view 0)) "h1")
       (string=? (kid-text (kid view 0) 0) "Count")
       (string=? (kid-text (kid view 1) 0) "0")
       (string=? (attr view "data-x") "0")))

;; a click reaches the listener, updates the signal, and only the
;; holes change
(js-method (kid view 2) "fire" "click")
(define click-ok
  (and (= clicks 1)
       (string=? (kid-text (kid view 1) 0) "1")
       (string=? (attr view "data-x") "2")))

(signal-set! n 5)
(define set-ok
  (and (string=? (kid-text (kid view 1) 0) "5")
       (string=? (attr view "data-x") "10")))

;; sx-list: children track the signal
(define items (signal '("a" "b")))
(define lst (sx-list (lambda () (signal-ref items))
                     (lambda (it) (sx (li ,it)))))
(define list-ok-1
  (and (= (kid-count lst) 2)
       (string=? (kid-text (kid lst 0) 0) "a")
       (string=? (kid-text (kid lst 1) 0) "b")))
(signal-set! items '("x" "y" "z"))
(define list-ok-2
  (and (= (kid-count lst) 3)
       (string=? (kid-text (kid lst 0) 0) "x")
       (string=? (kid-text (kid lst 2) 0) "z")))

(and static-ok click-ok set-ok list-ok-1 list-ok-2)

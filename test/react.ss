;; expect: #t
;; (web react) registration, playing the JS host from Scheme: call
;; the registered factory through the bridge, read the mounted DOM,
;; then call the returned dispose function.
(import (web reactive) (web sx) (web js) (web react))

(js-eval "globalThis.document = { createElement: t => ({ tag: t, children: [], attrs: {}, listeners: {}, appendChild(c){ this.children.push(c); return c }, replaceChild(n,o){ const i = this.children.indexOf(o); if (i >= 0) this.children[i] = n; return o }, setAttribute(k,v){ this.attrs[k] = v }, removeAttribute(k){ delete this.attrs[k] }, addEventListener(t,f){ this.listeners[t] = f }, set textContent(s){ this.children.length = 0 }, fire(t,ev){ this.listeners[t](ev === undefined ? {} : ev) } }), createTextNode: s => ({ text: s }) }")

(define (kid el i) (js-index (js-get el "children") i))
(define (kid-count el) (js->number (js-get (js-get el "children") "length")))
(define (kid-text el i) (js->string (js-get (kid el i) "text")))

(react-component "Counter"
  (lambda (container props)
    (let* ((start (let ((v (props-ref props "start")))
                    (if v (js->number v) 0)))
           (n (signal start)))
      (sx-mount container
        (sx (div
              (span ,(signal-ref n))
              (button (@ (on-click ,(lambda _
                                      (signal-update! n
                                        (lambda (v) (+ v 1))))))
                "+")))))))

;; the JS host side: __goeteia.Counter(host, {start: 5})
(define factory (js-get (js-get (js-global) "__goeteia") "Counter"))
(define host (js-method (js-get (js-global) "document")
                        "createElement" "div"))
(define dispose (js-call factory (js-undefined)
                         host (js-eval "({start: 5})")))

(define root (kid host 0))
(define mounted-ok
  (and (= (kid-count host) 1)
       (string=? (kid-text (kid root 0) 0) "5")))

;; a click on the embedded widget updates its hole
(js-method (kid root 1) "fire" "click")
(define click-ok (string=? (kid-text (kid root 0) 0) "6"))

;; missing props read as #f
(define props-ok
  (and (not (props-ref (js-eval "({})") "x"))
       (js-ref? (props-ref (js-eval "({x: 1})") "x"))))

;; dispose (default: clear the host)
(js-call dispose (js-undefined))
(define dispose-ok (= (kid-count host) 0))

(and mounted-ok click-ok props-ok dispose-ok)

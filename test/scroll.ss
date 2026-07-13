;; expect: #t
;; (web scroll) against a mock DOM: only the visible window mounts,
;; items sit at prefix-sum offsets, appends stick to the bottom, and
;; a wrong estimate corrects itself from one offsetHeight read.
(import (rnrs) (web js) (web dom) (web typeset) (web scroll))

(js-eval "globalThis.__ls = {}; globalThis.document = { createElement(tag){ if (tag === 'canvas') return { getContext(k){ return { font:'', measureText(s){ return { width: 10 } } } } }; return { style:{}, children:[], textContent:'', scrollTop:0, appendChild(c){ this.children.push(c) }, removeChild(c){ this.children = this.children.filter(x => x !== c) }, addEventListener(k,f){ globalThis.__ls[k] = f }, get offsetHeight(){ const t = this.textContent; return t && t[0] === 'X' ? 48 : 24 } } } }")

(define body (js-eval "globalThis.document.createElement('div')"))
(define vs (make-vscroll body 400 600 "15px m" 24))
(define outer (vscroll-element vs))
(define inner (js-index (js-get outer "children") 0))

(define (kids-count)
  (js->number (js-get (js-get inner "children") "length")))
(define (item-div txt)
  (let* ((kids (js-get inner "children"))
         (n (js->number (js-get kids "length"))))
    (let loop ((i 0))
      (and (< i n)
           (let ((d (js-index kids i)))
             (if (string=? (js->string (js-get d "textContent")) txt)
                 d
                 (loop (+ i 1))))))))
(define (style-of el prop) (js->string (js-get (js-get el "style") prop)))
(define (spacer-height) (style-of inner "height"))
(define (fire-scroll!)
  (js-call (js-get (js-get (js-global) "__ls") "scroll")
           (js-undefined) (js-eval "({})")))

;; 100 one-line items; appends stick the view to the bottom
(let fill ((i 0))
  (when (< i 100)
    (vscroll-append! vs (string-append "item " (number->string i)))
    (fill (+ i 1))))
(define fill-ok
  (and (= (vscroll-count vs) 100)
       (string=? (spacer-height) "2400px")
       (= (js->number (js-get outer "scrollTop")) 2400)
       (item-div "item 99")
       (not (item-div "item 0"))
       (<= (kids-count) 8)))            ; only the window is mounted

;; scroll to the top: the window follows, offsets position the items
(js-set! outer "scrollTop" 0)
(fire-scroll!)
(define top-ok
  (and (item-div "item 0")
       (not (item-div "item 99"))
       (string=? (style-of (item-div "item 0") "top") "0px")
       (string=? (style-of (item-div "item 1") "top") "24px")
       (<= (kids-count) 30)))

;; an under-estimated item corrects itself after mounting
(js-set! outer "scrollTop" 2400)
(fire-scroll!)
(vscroll-append! vs "Xdrift")            ; estimate 24, actual 48
(define drift-ok
  (and (= (vscroll-count vs) 101)
       (string=? (spacer-height) "2448px")
       (= (js->number (js-get outer "scrollTop")) 2448)
       (string=? (style-of (item-div "Xdrift") "top") "2400px")))

;; an over-estimated item corrects the other way: 60 unbroken chars
;; wrap to two estimated lines, the mock renders them as one
(vscroll-append! vs (make-string 60 #\y))
(define shrink-ok
  (and (string=? (spacer-height) "2472px")
       (= (js->number (js-get outer "scrollTop")) 2472)))

(and fill-ok top-ok drift-ok shrink-ok)

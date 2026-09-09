;; expect: #t
;; RED ON PURPOSE: a keyed sx-list's per-item effects are never
;; released when the LIST is disposed.
;;
;; $sx-list-keyed puts each item's effects under their own `root`, and
;; the comment beside it says why: "they survive list reruns and die
;; when the key vanishes".  Both halves are true and there is a third
;; case neither covers -- the list itself being disposed.  A root is a
;; detached owner, so it is not a child of the effect that made it, and
;; the only call to an item's disposer is in the branch that runs when
;; a key disappears from the data.
;;
;; ⇒ Dispose the owner of the whole list and every item's effects stay
;; subscribed.  They keep running on every later signal write, holding
;; their closures, their nodes and whatever those reference, for as
;; long as the signal lives.
;;
;; ⚠️ Nothing goes wrong at the moment of the leak.  The symptom is
;; work being done on behalf of a screen nobody is looking at, and it
;; grows once per mount.
;;
;; ⭐ The controls are the two cases the comment DOES describe, because
;; they are what a fix must not spend: an item whose key survives a
;; rerun must keep its effect, and an item whose key vanishes must lose
;; it.  A fix that disposed item roots on every rerun would satisfy the
;; red and destroy the point of keying.
(import (rnrs) (web reactive) (web sx) (web js))

(js-eval "globalThis.document = { createElement: t => ({ tag: t, children: [], attrs: {}, listeners: {}, appendChild(c){ const j = this.children.indexOf(c); if (j >= 0) this.children.splice(j, 1); this.children.push(c); return c }, replaceChild(n,o){ const i = this.children.indexOf(o); if (i >= 0) this.children[i] = n; return o }, insertBefore(n,r){ const j = this.children.indexOf(n); if (j >= 0) this.children.splice(j, 1); const i = this.children.indexOf(r); this.children.splice(i < 0 ? this.children.length : i, 0, n); return n }, removeChild(c){ const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); return c }, setAttribute(k,v){ this.attrs[k] = v }, removeAttribute(k){ delete this.attrs[k] }, addEventListener(t,f){ this.listeners[t] = f }, set textContent(s){ this.children.length = 0 }, fire(t,ev){ this.listeners[t](ev === undefined ? {} : ev) } }), createTextNode: s => ({ text: s }) }")

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; a signal every item watches, and a counter of how many item effects ran
(define tick (signal 0))
(define runs 0)
(define items (signal (list 'a 'b)))

(define outer
  (root (lambda ()
          (sx-list (lambda () (signal-ref items))
                   (lambda (it)
                     (effect (lambda () (signal-ref tick) (set! runs (+ runs 1))))
                     (create-element "span"))
                   (lambda (it) it)))))

;; two items, each ran once
(want 'w02-setup runs 2)

;; ---- control: a surviving key keeps its effect across a rerun ----
(signal-set! items (list 'a 'b 'c))
(let ((before runs))
  (signal-set! tick 1)
  (want 'w02-CONTROL-survivors-still-live (- runs before) 3))

;; ---- control: a vanished key loses its effect ----
(signal-set! items (list 'a))
(let ((before runs))
  (signal-set! tick 2)
  (want 'w02-CONTROL-vanished-key-released (- runs before) 1))

;; ---- red: disposing the list releases what is left ----
((cdr outer))
(let ((before runs))
  (signal-set! tick 3)
  (want 'w02-disposed-list-runs-nothing (- runs before) 0))

(if (null? fails) (display #t) (begin (display fails) (newline)))

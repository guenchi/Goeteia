;; expect: #t
;; A press that is released somewhere else must not stay pressed.
;;
;; pointerup fires on the element under the pointer at release time and
;; bubbles from there to the window.  With the listener on the canvas
;; alone, a press that starts on the canvas, drags off it, and is
;; released over any other element never reaches us: the canvas is not
;; an ancestor of the release target, so nothing bubbles through it and
;; pointer-down? stays true with the button physically up.  It stays
;; true until the next release that happens to land back on the canvas,
;; which is the shape of a latch, not of a miss.
;;
;; The rig fires the release on the window, which is where such an event
;; arrives after bubbling.  What it does NOT establish is that a browser
;; routes it there -- that follows from the event model, and is recorded
;; in the design as needing one hand check in a real browser (drag out,
;; release outside, read back).  What it does establish is whether this
;; library is listening at the place the event passes through.
(import (rnrs) (web js) (gfx fx))
(js-eval "globalThis.__L = {};
const mk = () => { const o = { L:{},
  addEventListener(t,f){ (this.L[t] = this.L[t] || []).push(f) } }; return o };
globalThis.__a = mk();
const add = (t,f) => { (globalThis.__L[t] = globalThis.__L[t] || []).push(f) };
globalThis.addEventListener = add;
globalThis.document = { addEventListener: add, pointerLockElement: null };
globalThis.__fire = (o,t,e) => (o.L[t] || []).forEach(f => f(e));
globalThis.__fireg = (t,e) => (globalThis.__L[t] || []).forEach(f => f(e));")
(define A (js-get (js-global) "__a"))
(define (fire! o t e) (js-call (js-get (js-global) "__fire") (js-undefined) o t e))
(define (fireg! t e) (js-call (js-get (js-global) "__fireg") (js-undefined) t e))
(define (ev s) (js-eval s))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(fx-init-input! A)

;; the ordinary path still works: press and release both on the element
(fire! A "pointerdown" (ev "({})"))
(check "a press on the element registers" (eq? #t (pointer-down?)))
(fire! A "pointerup" (ev "({})"))
(check "a release on the element clears it" (not (pointer-down?)))

;; the shape this cell exists for: released anywhere else
(fire! A "pointerdown" (ev "({})"))
(check "pressed again" (eq? #t (pointer-down?)))
(fireg! "pointerup" (ev "({})"))
(check "a release that lands outside the element still clears the press"
       (not (pointer-down?)))

;; a cancelled pointer is a release too -- the button is not down after
;; the browser takes the pointer away, and nothing else will tell us.
(fire! A "pointerdown" (ev "({})"))
(check "pressed a third time" (eq? #t (pointer-down?)))
(fireg! "pointercancel" (ev "({})"))
(check "a cancelled pointer clears the press" (not (pointer-down?)))

;; the window listeners must be installed once, not once per attach --
;; the duplicate-registration defect this library already carries a
;; WeakSet to prevent would otherwise come back through this door.
(fx-init-input! A)
(check "attaching again does not add a second window release listener"
       (= 1 (js->number (js-eval "(globalThis.__L['pointerup']||[]).length"))))
(display (= failed 0))

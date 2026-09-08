;; expect: #t
;; Retargeting: after attaching to a second element, the FIRST one's
;; events must no longer write the shared state.
(import (rnrs) (web js) (gfx fx))
(js-eval "globalThis.__L = {};
const mk = () => { const o = { L:{}, reqs:0,
  addEventListener(t,f){ (this.L[t] = this.L[t] || []).push(f) },
  requestPointerLock(){ this.reqs++ } }; return o };
globalThis.__a = mk(); globalThis.__b = mk();
const add = (t,f) => { (globalThis.__L[t] = globalThis.__L[t] || []).push(f) };
globalThis.addEventListener = add;
globalThis.document = { addEventListener: add, pointerLockElement: null };
globalThis.__fire = (o,t,e) => (o.L[t] || []).forEach(f => f(e));
globalThis.__fireg = (t,e) => (globalThis.__L[t] || []).forEach(f => f(e));
globalThis.__n = (o,t) => (o.L[t] || []).length;
globalThis.__ng = (t) => (globalThis.__L[t] || []).length;
globalThis.__reqs = (o) => o.reqs;")
(define A (js-get (js-global) "__a"))
(define B (js-get (js-global) "__b"))
(define (fire! o t e) (js-call (js-get (js-global) "__fire") (js-undefined) o t e))
(define (fireg! t e) (js-call (js-get (js-global) "__fireg") (js-undefined) t e))
(define (n o t) (js->number (js-call (js-get (js-global) "__n") (js-undefined) o t)))
(define (ng t) (js->number (js-call (js-get (js-global) "__ng") (js-undefined) t)))
(define (reqs o) (js->number (js-call (js-get (js-global) "__reqs") (js-undefined) o)))
(define (ev s) (js-eval s))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(fx-init-input! A)
(fire! A "pointermove" (ev "({offsetX: 5, offsetY: 6})"))
(check "A drives the pointer while it is the target"
       (and (fl=? (pointer-x) 5.0) (fl=? (pointer-y) 6.0)))
;; retarget
(fx-init-input! B)
(check "B got its own handlers" (= 1 (n B "pointermove")))
(check "A's handler was not removed, only silenced" (= 1 (n A "pointermove")))
(fire! A "pointermove" (ev "({offsetX: 99, offsetY: 99})"))
(check "the old element no longer writes the pointer"
       (and (fl=? (pointer-x) 5.0) (fl=? (pointer-y) 6.0)))
(fire! B "pointermove" (ev "({offsetX: 7, offsetY: 8})"))
(check "the new element does" (and (fl=? (pointer-x) 7.0) (fl=? (pointer-y) 8.0)))
(fire! A "pointerdown" (ev "({})"))
(check "the old element no longer sets pointer-down?" (not (pointer-down?)))
(fire! B "pointerdown" (ev "({})"))
(check "the new element does" (eq? #t (pointer-down?)))
;; keys keep working across a retarget, and only one window handler exists
(check "window key handlers registered exactly once" (= 1 (ng "keydown")))
(fireg! "keydown" (ev "({key: 'q'})"))
(check "keys still work after retargeting" (key-down? "q"))

;; ---- pointer lock retargets too ----
(pointer-lock! A)
(pointer-lock! B)
(check "one mousemove handler on the document" (= 1 (ng "mousemove")))
(fire! A "click" (ev "({})"))
(check "a click on the old element does not capture" (= 0 (reqs A)))
(fire! B "click" (ev "({})"))
(check "a click on the new element does" (= 1 (reqs B)))
(display (= failed 0))
(newline)

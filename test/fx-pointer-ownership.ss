;; expect: #t
;; One pointer's release must not answer for another's.
;;
;; pointer-down? is backed by a single boolean that any pointerdown
;; sets and any pointerup clears, with no record of which pointer it
;; belongs to.  With two fingers on a touch screen -- or a pen and a
;; mouse -- the second one's release clears the flag while the first is
;; still pressed, and the shader-side code reads "nothing is held".
;;
;; This predates the window-level release added in 01249e4; the element
;; handler was already ownerless.  What 01249e4 changed is the reach:
;; releases from anywhere in the document now arrive too, so a pointer
;; that was never ours can clear our flag.
;;
;; The same absence of ownership makes one physical release arrive
;; twice -- once on the element, once again as it bubbles to the window
;; -- which a boolean absorbs and a count would not.  The last cell
;; pins that a release is recognised once per pointer, so that the
;; snapshot batch does not inherit a double count.
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
(define (ev id) (js-eval (string-append "({pointerId: " (number->string id) "})")))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(fx-init-input! A)

;; two pointers down, one up: something is still held
(fire! A "pointerdown" (ev 1))
(fire! A "pointerdown" (ev 2))
(check "two pointers down reads as down" (eq? #t (pointer-down?)))
(fire! A "pointerup" (ev 2))
(check "releasing the second pointer leaves the first one held"
       (eq? #t (pointer-down?)))
(fire! A "pointerup" (ev 1))
(check "releasing the last one clears it" (not (pointer-down?)))

;; a pointer that was never pressed here must not clear anything
(fire! A "pointerdown" (ev 7))
(fireg! "pointerup" (ev 99))
(check "a release from a pointer we never saw pressed does not clear ours"
       (eq? #t (pointer-down?)))
(fireg! "pointerup" (ev 7))
(check "our own pointer's release, arriving on the window, does clear it"
       (not (pointer-down?)))

;; one physical release, delivered twice: once on the element and again
;; as it bubbles to the window.  A boolean absorbs the repeat; the
;; ownership record must consume it, so that a count cannot see two.
(fire! A "pointerdown" (ev 3))
(fire! A "pointerup" (ev 3))
(fireg! "pointerup" (ev 3))
(check "the same release arriving twice is still one release, and leaves us up"
       (not (pointer-down?)))
(fire! A "pointerdown" (ev 3))
(check "and the pointer can be pressed again afterwards"
       (eq? #t (pointer-down?)))

;; cancellation ends ownership too: nothing further will arrive for it
(fire! A "pointerdown" (ev 4))
(fireg! "pointercancel" (ev 3))
(check "cancelling one pointer leaves the other held" (eq? #t (pointer-down?)))
(fireg! "pointercancel" (ev 4))
(check "cancelling the last one clears it" (not (pointer-down?)))
(display (= failed 0))

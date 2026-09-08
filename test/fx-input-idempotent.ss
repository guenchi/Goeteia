;; expect: #t
;; Attaching the input layer twice must not make one event count twice.
;;
;; fx-init-input! and pointer-lock! call addEventListener unconditionally,
;; so a second call leaves two live handlers on every event.  For the
;; polled surface that is invisible -- writing #t twice is still #t --
;; and it stayed invisible for exactly that reason.  It is not invisible
;; for anything that ACCUMULATES: pointer-motion! sums movementX, so a
;; game that locks the pointer again on a new level reports every mouse
;; movement at twice its size, and nothing anywhere reports an error.
;;
;; Re-initialising is a normal thing to do here -- test/fx-vao-cache.ss
;; ends by re-initialising a context on purpose -- so the second attach
;; is not a misuse to be documented away.
(import (rnrs) (web js) (gfx fx))

(js-eval "globalThis.__L = {};
const add = (t, f) => { (globalThis.__L[t] = globalThis.__L[t] || []).push(f) };
globalThis.document = { addEventListener: add, pointerLockElement: null };
globalThis.addEventListener = add;
globalThis.__el = { addEventListener: add, requestPointerLock(){} };
globalThis.__fire = (t, o) => (globalThis.__L[t] || []).forEach(f => f(o));
globalThis.__count = t => (globalThis.__L[t] || []).length;")

(define el (js-get (js-global) "__el"))
(define (listeners t)
  (js->number (js-call (js-get (js-global) "__count") (js-undefined) t)))
(define (fire! t o)
  (js-call (js-get (js-global) "__fire") (js-undefined) t o))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

;; ---- the keyboard surface ----
(fx-init-input! el)
(define after-one (listeners "keydown"))
(fx-init-input! el)
(check "a second attach does not add a second keydown handler"
       (= (listeners "keydown") after-one))
(check "the first attach did register one" (> after-one 0))

;; the polled surface still works after two attaches -- the repair must
;; not be "stop attaching", which would break the second initialisation
(fire! "keydown" (js-eval "({key: 'w', code: 'KeyW'})"))
(check "a key still reads as down after re-initialising" (key-down? "w"))
(fire! "keyup" (js-eval "({key: 'w', code: 'KeyW'})"))
(check "and up again" (not (key-down? "w")))

;; ---- the accumulating surface, where doubling is visible ----
(pointer-lock! el)
(define moves-after-one (listeners "mousemove"))
(pointer-lock! el)
(check "a second lock does not add a second mousemove handler"
       (= (listeners "mousemove") moves-after-one))

(js-eval "globalThis.document.pointerLockElement = globalThis.__el")
(fire! "pointerlockchange" (js-eval "({})"))
(fire! "mousemove" (js-eval "({movementX: 10, movementY: 4})"))
(let ((d (pointer-motion!)))
  (check "one movement of ten is reported as ten, not twenty"
         (and (< (abs (- (car d) 10.0)) 0.001)
              (< (abs (- (cdr d) 4.0)) 0.001))))

;; consuming twice must not resurrect the motion
(let ((d (pointer-motion!)))
  (check "the motion is consumed" (and (= (car d) 0.0) (= (cdr d) 0.0))))

(display (= failed 0))
(newline)

;; expect: #t
;; RED ON PURPOSE: an argument that fails to convert leaves the
;; arguments before it on the shared staging stack, and the NEXT call
;; through the FFI receives them.
;;
;;   (js-call f this 11 <unconvertible>)  raises, 11 stays pushed
;;   (js-call f this 22)                  the callee sees TWO arguments
;;
;; ⚠️ The damage lands on a call that did nothing wrong, in a caller
;; that may have handled the first failure correctly.  A JS function
;; reading arguments.length, or one with optional parameters, silently
;; takes a different branch.
;;
;; ⭐ THE SHAPE: the hazard is understood elsewhere in this same file.
;; js-set! converts before staging the property name, and its comment
;; says why -- "a string value passes through the same name buffer and
;; would swallow a name already staged".  ⇒ Somebody worked this out
;; and fixed one path.  js-call, js-method and js-new push as they go.
;; One hazard, four entrances, a guard on one.
;;
;; ⭐ Failure on the FIRST argument leaves nothing behind, and that
;; cell is green on purpose: it says the residue is the arguments
;; ALREADY pushed, not the failure itself, which is what tells a
;; reader where to look.
;;
;; The controls are ordinary calls through each entry point and the
;; js-set! path that is already right, since a fix has to leave both
;; alone.
(import (rnrs) (web js))

(js-eval "globalThis.na = function(){ return arguments.length }")
(js-eval "globalThis.Box = function(){ this.n = arguments.length }")
(js-eval "globalThis.holder = { na: function(){ return arguments.length } }")

(define na (js-get (js-global) "na"))
(define Box (js-get (js-global) "Box"))
(define holder (js-get (js-global) "holder"))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (tried thunk) (guard (e (#t 'caught)) (thunk)))

;; '() has no conversion; if that ever changes this file needs a new
;; unconvertible value, and the cell below is what would say so
(want 'w01-SETUP-unconvertible (tried (lambda () (js-call na (js-global) '()))) 'caught)

;; ---- controls: the clean shapes ----
(want 'w01-CONTROL-call (js->number (js-call na (js-global) 22)) 1)
(want 'w01-CONTROL-method (js->number (js-method holder "na" 1 2)) 2)
(want 'w01-CONTROL-new (js->number (js-get (js-new Box 1 2 3) "n")) 3)

;; ---- green on purpose: a failure on the first argument leaves nothing ----
(tried (lambda () (js-call na (js-global) '() 11)))
(want 'w01-first-arg-leaves-nothing (js->number (js-call na (js-global) 22)) 1)

;; ---- red: a failure after the first leaves what came before ----
(tried (lambda () (js-call na (js-global) 11 '())))
(want 'w01-call-residue (js->number (js-call na (js-global) 22)) 1)

(tried (lambda () (js-call na (js-global) 11 12 '())))
(want 'w01-call-residue-two (js->number (js-call na (js-global) 22)) 1)

(tried (lambda () (js-method holder "na" 11 '())))
(want 'w01-method-residue (js->number (js-method holder "na" 22)) 1)

(tried (lambda () (js-new Box 11 '())))
(want 'w01-new-residue (js->number (js-get (js-new Box 22) "n")) 1)

;; ---- control: the path that already converts first must stay right ----
(define obj (js-eval "({})"))
(tried (lambda () (js-set! obj "k" '())))
(js-set! obj "k" 5)
(want 'w01-CONTROL-set-name-not-swallowed (js->number (js-get obj "k")) 5)

(if (null? fails) (display #t) (begin (display fails) (newline)))

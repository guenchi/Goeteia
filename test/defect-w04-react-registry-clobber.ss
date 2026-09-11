;; expect: #t
;; REGRESSION GUARD (written as a red witness at e8b3f10; green since).
;; The defect as it then was: installing a component replaces the whole
;; global registry, so a module loaded later destroys the entries of
;; every module loaded before it.
;;
;; $ensure-registry makes a fresh {} and assigns globalThis.__goeteia
;; without ever looking at what is already there.  $registry is
;; module-local, so each independently loaded module starts at #f and
;; each one clobbers the global on its first registration.
;;
;; -> Load a module registering ReviewOne and then one registering
;; ReviewTwo, and only ReviewTwo exists.
;;
;; Nothing fails at load time.  The host asks for a component that
;; was registered, by a module that did register it, and gets
;; undefined.
;;
;; The other module is simulated by installing a registry from JS
;; before the first registration here, and that is faithful rather than
;; convenient: this module's only knowledge of an earlier one is
;; whatever it left on globalThis, and a JS-installed object is
;; indistinguishable from a Scheme-installed one at that boundary.
;; -> The cell cannot tell the difference, and neither can the code
;; under test, which is the whole reason the defect exists.
;;
;; The controls are what a fix must not spend: two components
;; registered from THIS module must both be reachable, and the
;; registry has to stay at globalThis.__goeteia, which is the name the
;; React side looks it up by.
(import (rnrs) (web react) (web js))

(js-eval "globalThis.document = { createElement: t => ({tag:t, children:[], appendChild(c){this.children.push(c)}, setAttribute(){}, addEventListener(){}}), createTextNode: s => ({text:s}) }")

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (kind path) (js->string (js-eval (string-append "typeof " path))))

;; the registry another module already installed
(js-eval "globalThis.__goeteia = { ReviewOne: function(){ return 1 } }")
(want 'w04-SETUP-other-module-present (kind "globalThis.__goeteia.ReviewOne") "function")

(react-component "ReviewTwo" (lambda (c p) (lambda () 'bye)))

;; ---- red ----
(want 'w04-earlier-module-survives (kind "globalThis.__goeteia.ReviewOne") "function")

;; ---- controls ----
(want 'w04-CONTROL-own-registration (kind "globalThis.__goeteia.ReviewTwo") "function")
(react-component "ReviewThree" (lambda (c p) (lambda () 'bye)))
(want 'w04-CONTROL-second-own (kind "globalThis.__goeteia.ReviewTwo") "function")
(want 'w04-CONTROL-third-own (kind "globalThis.__goeteia.ReviewThree") "function")
(want 'w04-CONTROL-registry-name (kind "globalThis.__goeteia") "object")

(if (null? fails) (display #t) (begin (display fails) (newline)))

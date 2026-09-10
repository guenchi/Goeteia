;; expect: #t
;; The registry has to be installed under the name the React side looks
;; it up by, and this is the only cell that reaches the branch which
;; installs it.
;;
;; WHY IT IS A FILE OF ITS OWN.  Its sibling,
;; defect-w04-react-registry-clobber.ss, begins by putting a registry
;; on the global so it can check that an earlier module's entries
;; survive.  That means the adopt branch runs there and the install
;; branch never does -- and its "the registry is at globalThis.__goeteia"
;; cell is then asking about the object the SETUP left, not about
;; anything this library did.  -> A fix that installed under a different
;; name would keep every cell in that file green while the React side,
;; which looks the registry up by that name, found nothing.
;;
;; The two orders cannot share a process.  The module caches its
;; registry on first use, so once the sibling's setup has been adopted,
;; deleting the global and registering again writes into the orphaned
;; object and the global stays undefined.  Measured, when this cell was
;; first written into that file:
;;
;;     Cannot read properties of undefined (reading 'Solo')
;;
;; -> The install branch is reachable only from a module that has not
;; registered anything yet, which is a fresh process.
;;
;; That caching is itself worth knowing and is asserted below: a
;; second registration lands beside the first rather than replacing the
;; registry, which is what makes two components from one module both
;; reachable.
(import (rnrs) (web react) (web js))

(js-eval "globalThis.document = { createElement: t => ({tag:t, children:[], appendChild(c){this.children.push(c)}, setAttribute(){}, addEventListener(){}}), createTextNode: s => ({text:s}) }")
(js-eval "delete globalThis.__goeteia")

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (kind path) (js->string (js-eval (string-append "typeof " path))))

(want 'SETUP-nothing-installed-yet (kind "globalThis.__goeteia") "undefined")

(react-component "Solo" (lambda (c p) (lambda () 'x)))
(want 'installs-under-the-documented-name (kind "globalThis.__goeteia.Solo") "function")

(react-component "Duet" (lambda (c p) (lambda () 'x)))
(want 'second-registration-joins-the-first (kind "globalThis.__goeteia.Solo") "function")
(want 'second-registration-is-present (kind "globalThis.__goeteia.Duet") "function")

(if (null? fails) (display #t) (begin (display fails) (newline)))

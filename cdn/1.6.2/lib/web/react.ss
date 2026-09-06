;; Embedding Goeteia components into a React (or any JS) host.
;;
;; (react-component "Counter"
;;   (lambda (container props)
;;     (sx-mount container (sx ...))
;;     (lambda () ...cleanup...)))
;;
;; registers globalThis.__goeteia.Counter as a plain JS function
;; (host-element, props-object) -> dispose-function.  The callback
;; bridge does all the lifting: the Scheme closure becomes a callable
;; JS function, its arguments arrive as js-refs, and the returned
;; dispose thunk converts to a JS function on the way out.  The React
;; side wraps this in one useEffect -- see rt/react.mjs.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web react)
  (export react-component props-ref)
  (import (rnrs) (web js) (web dom))

  (define $registry #f)
  (define ($ensure-registry)
    (unless $registry
      (set! $registry (js-eval "({})"))
      (js-set! (js-global) "__goeteia" $registry))
    $registry)

  (define (react-component name mount)
    (js-set! ($ensure-registry) name
             (lambda (container props)
               (let ((dispose (mount container props)))
                 (if (procedure? dispose)
                     dispose
                     (lambda () (remove-all-children! container)))))))

  ;; a prop as a js-ref, or #f when absent
  (define (props-ref props name)
    (let ((v (js-get props name)))
      (if (js-eq? v (js-undefined)) #f v))))

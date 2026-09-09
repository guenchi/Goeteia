;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

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
(library (web react)
  (export react-component props-ref)
  (import (rnrs) (web js) (web dom))

  ;; The registry is shared ground: every independently loaded module
  ;; registers into the same globalThis.__goeteia, and $registry is
  ;; module-local, so each module arrives with it at #f.  Creating a
  ;; fresh object here and assigning it therefore threw away everything
  ;; an earlier module had registered -- and nothing failed at load
  ;; time: the host asked for a component that WAS registered, by a
  ;; module that DID register it, and got undefined.
  ;;
  ;; So adopt what is there.  The whole decision is one JS expression
  ;; on purpose: reading the global, judging it and installing a
  ;; replacement are one step, and splitting them would leave a window
  ;; in which two modules both see nothing and both install.  A value
  ;; that is present but not an object is replaced, which is what
  ;; happened to it before and is the only thing left to do with it.
  (define $registry #f)
  (define ($ensure-registry)
    (unless $registry
      (set! $registry
            (js-eval
             (string-append
              "(globalThis.__goeteia && typeof globalThis.__goeteia === 'object')"
              " ? globalThis.__goeteia : (globalThis.__goeteia = {})"))))
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

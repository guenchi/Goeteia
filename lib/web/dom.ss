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

;; DOM sugar over (web js).
(library (web dom)
  (export window document body
          get-element-by-id need-element-by-id
          query-selector create-element make-text
          append-child! replace-child! insert-before! remove-child!
          remove-all-children!
          set-inner-html! inner-text set-text!
          set-attribute! set-style!
          computed-style computed-px
          add-event-listener! console-log alert)
  (import (rnrs) (web js))

  (define (window) (js-global))
  (define (document) (js-get (js-global) "document"))
  (define (body) (js-get (document) "body"))
  (define (get-element-by-id id)
    (js-method (document) "getElementById" id))
  ;; The same lookup, insisting.  get-element-by-id answers a falsy
  ;; handle when nothing has the id, which is the right answer where
  ;; absence is expected and the wrong one where it is not: the handle
  ;; travels on into whatever was going to be written, and the failure
  ;; arrives from the host as a complaint about a PROPERTY -- setting
  ;; textContent of null -- naming neither the id that was missing nor
  ;; the lookup that failed to find it.  This one refuses at the lookup
  ;; and names the id.
  ;;
  ;; Both spellings are kept, and the weaker one keeps the plainer name
  ;; on purpose: it is the older export, and renaming it would break
  ;; every caller for whom a missing element is an ordinary answer.
  (define (need-element-by-id id)
    (let ((el (get-element-by-id id)))
      (if (js-truthy? el)
          el
          (error 'need-element-by-id "no element on the page has this id" id))))

  (define (query-selector sel)
    (js-method (document) "querySelector" sel))
  (define (create-element tag)
    (js-method (document) "createElement" tag))
  (define (make-text s)
    (js-method (document) "createTextNode" s))
  (define (append-child! parent child)
    (js-method parent "appendChild" child))
  (define (replace-child! parent new old)
    (js-method parent "replaceChild" new old))
  (define (insert-before! parent new ref)
    (js-method parent "insertBefore" new ref))
  (define (remove-child! parent child)
    (js-method parent "removeChild" child))
  (define (remove-all-children! el)
    (js-set! el "textContent" ""))
  (define (set-inner-html! el s) (js-set! el "innerHTML" s))
  (define (inner-text el) (js->string (js-get el "innerText")))
  (define (set-text! el s) (js-set! el "textContent" s))
  (define (set-attribute! el name v)
    (js-method el "setAttribute" name v))
  (define (set-style! el prop v)
    (js-set! (js-get el "style") prop v))
  ;; a resolved style value: (computed-style el "fontFamily")
  (define (computed-style el name)
    (js->string (js-get (js-method (window) "getComputedStyle" el) name)))
  ;; the same, parsed as pixels: "28.5px" -> 28.5; anything parseFloat
  ;; rejects ("normal", "auto") takes the fallback
  (define (computed-px el name fallback)
    (let* ((v (js->number (js-call (js-get (window) "parseFloat")
                                   (js-undefined)
                                   (computed-style el name))))
           (f (if (flonum? v) v (exact->inexact v))))
      (if (fl=? f f) f fallback)))     ; NaN -> the fallback
  (define (add-event-listener! el event handler)
    (js-method el "addEventListener" event handler))
  (define (console-log x)
    (js-method (js-get (js-global) "console") "log"
               (if (string? x) x (with-output-to-string (lambda () (write x))))))
  (define (alert s)
    (js-method (js-global) "alert" s)))

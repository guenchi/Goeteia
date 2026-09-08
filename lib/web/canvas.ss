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

;; The browser metrics provider for (web typeset): advance widths from
;; an offscreen canvas 2d context.
;;
;;   (prepare text (canvas-measurer "16px system-ui"))
;;
;; One measureText bridge call per distinct code point -- prepare
;; caches, so a 10k-char message costs as many calls as it has
;; distinct characters.  The font string is any CSS font shorthand;
;; match it to the CSS of the element the estimate stands in for.
;;
(library (web canvas)
  (export canvas-measurer)
  (import (rnrs) (web js))

  (define (canvas-measurer font)
    (let* ((doc (js-get (js-global) "document"))
           (cv (js-method doc "createElement" "canvas"))
           (ctx (js-method cv "getContext" "2d")))
      (js-set! ctx "font" font)
      (lambda (s)
        ;; measureText can hand back an exact integer; typeset's
        ;; arithmetic is flonum, so coerce at the boundary
        (let ((w (js->number
                  (js-get (js-method ctx "measureText" s) "width"))))
          (if (flonum? w) w (exact->inexact w)))))))

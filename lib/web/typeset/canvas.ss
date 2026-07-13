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
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web typeset canvas)
  (export canvas-measurer)
  (import (rnrs) (web js))

  (define (canvas-measurer font)
    (let* ((doc (js-get (js-global) "document"))
           (cv (js-method doc "createElement" "canvas"))
           (ctx (js-method cv "getContext" "2d")))
      (js-set! ctx "font" font)
      (lambda (s)
        (js->number (js-get (js-method ctx "measureText" s) "width"))))))

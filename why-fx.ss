;; The Why page's typeset effect: every heading's glyphs dodge the
;; cursor.  The machinery lives in (web glyphs) -- plain headings are
;; re-set by (web typeset), marked-up ones exploded by DOM Range with
;; layout untouched -- so this program only picks the elements and
;; starts the loop.  Compiled ahead of time by build.sh; why-fx.js
;; loads the wasm through rt/web.mjs.
(import (rnrs) (web js) (web dom) (web glyphs))

(define (plain? el)                     ; markup goes the Range way
  (= 0 (js->number (js-get el "childElementCount"))))

;; a reader who asked for still text gets still text
(unless (js-truthy? (js-get (js-method (js-global) "matchMedia"
                                       "(prefers-reduced-motion: reduce)")
                            "matches"))
  (let* ((els (js-method (document) "querySelectorAll"
                         "h1, h2, .era, .lede, .note-sub, .sub"))
         (n (js->number (js-get els "length"))))
    (let loop ((i 0) (groups '()))
      (if (< i n)
          (let ((el (js-index els i)))
            (loop (+ i 1)
                  (cons (if (plain? el) (glyphs! el) (glyphs-mixed! el))
                        groups)))
          (glyphs-dodge! groups)))))

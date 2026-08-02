;; expect: #t
;; (goeteia-embed mode body...): the mount point compiles its body as
;; an independent program and becomes one HTML string constant in the
;; host.  Modes: js (inline module, runs directly), wasm (loads the
;; module, data: URI by default), auto (both plus the loader pick).
(define (has? hay needle)
  (let ((n (string-length hay)) (m (string-length needle)))
    (let scan ((i 0))
      (cond ((> (+ i m) n) #f)
            ((let cmp ((j 0))
               (cond ((= j m) #t)
                     ((char=? (string-ref hay (+ i j)) (string-ref needle j))
                      (cmp (+ j 1)))
                     (else #f)))
             #t)
            (else (scan (+ i 1)))))))

;; js: the module text inline, invoked directly
(define js-section
  (goeteia-embed js
    (display (* 6 7))))
(define js-ok
  (and (has? js-section "<script type=\"module\">")
       (has? js-section "main();")
       (not (has? js-section "goeteia/js"))))

;; wasm: embedded as a data: URI unless wasm-url redirects
(define wasm-section
  (goeteia-embed wasm
    (display 1)))
(define wasm-ok
  (and (has? wasm-section "loadGoeteia('data:application/wasm;base64,")
       (has? wasm-section "./rt/web.mjs")))

(define wasm-url-section
  (goeteia-embed (wasm (wasm-url "app.wasm") (rt "../rt/web.mjs"))
    (display 1)))
(define wasm-url-ok
  (and (has? wasm-url-section "loadGoeteia('app.wasm')")
       (has? wasm-url-section "../rt/web.mjs")))

;; auto: the inline fallback plus the wasm reference, loader-picked;
;; the body may import libraries in its own scope
(define auto-section
  (goeteia-embed auto
    (import (web js))
    (display (if (js-truthy? (js-eval "1")) 1 0))))
(define auto-ok
  (and (has? auto-section "<script type=\"goeteia/js\">")
       (has? auto-section "loadGoeteiaAuto('data:application/wasm;base64,")
       (> (string-length auto-section) 50000)))

(and js-ok wasm-ok wasm-url-ok auto-ok)

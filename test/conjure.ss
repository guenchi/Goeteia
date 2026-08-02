;; expect: #t
;; (conjure mode body...): the mount point compiles its body as an
;; independent program and becomes one HTML string constant in the
;; host.  Modes: js (inline module, runs directly), wasm and auto
;; carry the runtime glue inline -- the page depends on nothing
;; beside itself -- and every auto section's fallback tag gets a
;; unique id so several coexist on one page.
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

;; js: the module text inline, invoked directly, no glue needed
(define js-section
  (conjure js
    (display (* 6 7))))
(define js-ok
  (and (has? js-section "<script type=\"module\">")
       (has? js-section "main();")
       (not (has? js-section "goeteia/js"))
       (not (has? js-section "makeJsBridge"))))

;; wasm: glue inline, module embedded as a data: URI by default
(define wasm-section
  (conjure wasm
    (display 1)))
(define wasm-ok
  (and (has? wasm-section "function makeJsBridge")
       (has? wasm-section "loadGoeteia('data:application/wasm;base64,")
       (not (has? wasm-section "import { loadGoeteia }"))))

(define wasm-url-section
  (conjure (wasm (wasm-url "app.wasm"))
    (display 1)))
(define wasm-url-ok (has? wasm-url-section "loadGoeteia('app.wasm')"))

;; auto: fallback tag with a unique id, glue inline, loader picks;
;; the body may import libraries in its own scope
(define auto-section
  (conjure auto
    (import (web js))
    (display (if (js-truthy? (js-eval "1")) 1 0))))
(define auto-ok
  (and (has? auto-section "<script type=\"goeteia/js\" id=\"goeteia-conjure-0\">")
       (has? auto-section "function makeJsBridge")
       (has? auto-section "loadGoeteiaAuto('data:application/wasm;base64,")
       (has? auto-section "'#goeteia-conjure-0'")
       (> (string-length auto-section) 50000)))

;; a second auto section gets the next id
(define auto2 (conjure auto (display 2)))
(define id2-ok (has? auto2 "id=\"goeteia-conjure-1\""))

;; the define- family wraps the modes into named definitions
(define-js mj (display 1))
(define-wasm mwi (display 2))
(define-wasm-js mai (display 3))
(define-wasm (mw "/tmp/goeteia-conjure-test.wasm") (display 4))
(define macro-sections-ok
  (and (has? mj "main();")
       (has? mwi "loadGoeteia('data:application/wasm;base64,")
       (has? mai "loadGoeteiaAuto('data:application/wasm;base64,")
       (has? mw "loadGoeteia('/tmp/goeteia-conjure-test.wasm')")))
;; define-wasm wrote its module next to the generator's output
(define wrote-ok
  (let ()
    (string-for-each (lambda (c) (%path-byte (char->integer c)))
                     "/tmp/goeteia-conjure-test.wasm")
    (let ((fd (%open-read)))
      (and (>= fd 0)
           (let ((b0 (%fread fd)))
             (%fclose fd)
             (= b0 0))))))            ; wasm magic starts 0x00

(and js-ok wasm-ok wasm-url-ok auto-ok id2-ok macro-sections-ok wrote-ok)

;; expect: #t
;; (conjure mode body...): the mount point compiles its body as an
;; independent program and becomes one HTML string constant in the
;; host.  Modes: js (inline module, runs directly), wasm and auto
;; carry the runtime glue inline -- the page depends on nothing
;; beside itself -- and every auto section's fallback tag gets a
;; unique id so several coexist on one page.
(import (mountlib))

(define (section-id s)                   ; the id in the fallback tag
  (let* ((n (string-length s))
         (start (let scan ((i 0))
                  (cond ((> (+ i 4) n) #f)
                        ((and (char=? (string-ref s i) #\i)
                              (char=? (string-ref s (+ i 1)) #\d)
                              (char=? (string-ref s (+ i 2)) #\=)
                              (char=? (string-ref s (+ i 3)) #\"))
                         (+ i 4))
                        (else (scan (+ i 1)))))))
    (and start
         (let scan ((j start))
           (if (or (= j n) (char=? (string-ref s j) #\"))
               (substring s start j)
               (scan (+ j 1)))))))

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
(define auto-id (section-id auto-section))
(define auto-ok
  (and auto-id
       (has? auto-section (string-append "<script type=\"goeteia/js\" id=\""
                                         auto-id "\">"))
       (has? auto-section "function makeJsBridge")
       (has? auto-section "loadGoeteiaAuto('data:application/wasm;base64,")
       ;; the loader looks up this section's own fallback
       (has? auto-section (string-append "'#" auto-id "'"))
       (> (string-length auto-section) 50000)))

;; a mount point inside a library resolves its imports too
(define lib-ok
  (and (has? lib-section "<script type=\"goeteia/js\"")
       (has? lib-section "loadGoeteiaAuto('data:application/wasm;base64,")))

;; a second auto section gets the next id
(define auto2 (conjure auto (display 2)))
(define id2-ok
  (let ((id2 (section-id auto2)))
    (and id2 (not (string=? id2 auto-id))   ; sections never share an id
         (has? auto2 (string-append "'#" id2 "'")))))

;; the define- family wraps the modes into named definitions; their
;; bodies are import scopes of their own too, so one imports (both
;; drivers must resolve it, not just the one that knows `conjure`)
(define-js mj (display 1))
(define-wasm mwi (display 2))
(define-wasm-js mai (import (web js)) (display (if (js-truthy? (js-eval "1")) 3 0)))
(define-wasm (mw "/tmp/goeteia-conjure-test.wasm") (display 4))
(define-js (mjf "/tmp/goeteia-conjure-test.js") (display 5))
(define macro-sections-ok
  (and (has? mj "main();")
       (has? mwi "loadGoeteia('data:application/wasm;base64,")
       (has? mai "loadGoeteiaAuto('data:application/wasm;base64,")
       (has? mw "loadGoeteia('/tmp/goeteia-conjure-test.wasm')")
       (has? mjf "src=\"/tmp/goeteia-conjure-test.js\"")))
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

;; define-js's URL form wrote a self-running module file
(define wrote-js-ok
  (let ()
    (string-for-each (lambda (c) (%path-byte (char->integer c)))
                     "/tmp/goeteia-conjure-test.js")
    (let ((fd (%open-read)))
      (and (>= fd 0)
           (let ((b0 (%fread fd)))
             (%fclose fd)
             (= b0 34))))))           ; module text opens "use strict"

(and js-ok wasm-ok wasm-url-ok auto-ok id2-ok macro-sections-ok wrote-ok
     wrote-js-ok lib-ok)

;; expect: #t
;; (web embed): base64 vectors, data-uri shape, mount-section
;; assembly and its script-terminator guard.
(import (rnrs) (web embed))

(define (s= a b) (string=? a b))

;; RFC 4648 test vectors
(define b64-ok
  (and (s= (base64-encode (make-bytevector 0 0)) "")
       (s= (base64-encode (string->utf8 "f")) "Zg==")
       (s= (base64-encode (string->utf8 "fo")) "Zm8=")
       (s= (base64-encode (string->utf8 "foo")) "Zm9v")
       (s= (base64-encode (string->utf8 "foob")) "Zm9vYg==")
       (s= (base64-encode (string->utf8 "fooba")) "Zm9vYmE=")
       (s= (base64-encode (string->utf8 "foobar")) "Zm9vYmFy")))

(define uri-ok
  (s= (wasm->data-uri (string->utf8 "foo"))
      "data:application/wasm;base64,Zm9v"))

;; assembly: fallback text inline, module script referencing the url
(define frag (mount-html "const X=1;" "app.wasm" "./rt/web.mjs"))
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
(define frag-ok
  (and (has? frag "<script type=\"goeteia/js\">")
       (has? frag "const X=1;")
       (has? frag "loadGoeteiaAuto('app.wasm')")
       (has? frag "./rt/web.mjs")))

;; a bytevector wasm-ref embeds as a data: URI
(define embed-ok
  (has? (mount-html "const X=1;" (string->utf8 "foo") "./rt/web.mjs")
        "loadGoeteiaAuto('data:application/wasm;base64,Zm9v')"))

;; foreign fallback text that could close the tag is rejected loudly
(define guard-ok
  (guard (e (#t #t))
    (mount-html "x</script><script>evil()" "app.wasm" "./rt/web.mjs")
    #f))
(define guard-case-ok
  (guard (e (#t #t))
    (mount-html "x</SCRIPT>" "app.wasm" "./rt/web.mjs")
    #f))

(and b64-ok uri-ok frag-ok embed-ok guard-ok guard-case-ok)

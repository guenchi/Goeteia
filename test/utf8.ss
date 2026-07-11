;; expect: #t
;; UTF-8 survives: string literals compile to UTF-8 bytes, and the JS
;; bridge encodes/decodes UTF-8 at the boundary (not Latin-1).
(import (web js))

(define g "Γοητεία")            ; Greek, 2 bytes/char
(define mix "em— ·→ dash")       ; assorted multi-byte typography

(and
 ;; Scheme -> JS -> Scheme round-trips the exact bytes
 (string=? (js->string (string->js g)) g)
 (string=? (js->string (string->js mix)) mix)
 ;; a JS-side Greek literal decodes to the same Scheme bytes
 (string=? (js->string (js-eval "'Γοητεία'")) g)
 ;; JS counts 7 code points where the Scheme byte-string is longer
 (= (js->number (js-get (string->js g) "length")) 7)
 (> (string-length g) 7))

;; expect: #t
;; (web css): render rule lists to CSS strings. No floats; unit forms
;; take one integer (whole) or two (whole . fraction-in-hundredths).
(import (web css))

(define (t got want) (string=? got want))

(and
 ;; whole values are natural (no x100 inflation)
 (t (css->string '((x (a (em 1))))) "x{a:1em;}")
 (t (css->string '((x (a (px 13))))) "x{a:13px;}")
 (t (css->string '((x (a (pct 50))))) "x{a:50%;}")
 (t (css->string '((x (a (vh 100))))) "x{a:100vh;}")
 (t (css->string '((x (a (deg 120))))) "x{a:120deg;}")
 ;; fractions are hundredths: padded to two digits, trailing zeros dropped
 (t (css->string '((x (a (em 0 92))))) "x{a:0.92em;}")
 (t (css->string '((x (a (em 3 40))))) "x{a:3.4em;}")   ; 40 -> .4
 (t (css->string '((x (a (em 3 4))))) "x{a:3.04em;}")   ; 4 -> .04 (leading zero!)
 (t (css->string '((x (a (em 1 15))))) "x{a:1.15em;}")
 (t (css->string '((x (a (px 13 50))))) "x{a:13.5px;}")
 (t (css->string '((x (a (rem 0 30))))) "x{a:0.3rem;}")
 (t (css->string '((x (a (em 0 625))))) "x{a:0.625em;}") ; more digits = precision
 ;; bare integers and a unitless decimal (line-height); alpha likewise
 (t (css->string '((body (margin 0) (line-height (dec 1 60))))) "body{margin:0;line-height:1.6;}")
 (t (css->string '((x (a (dec 0 6))))) "x{a:0.06;}")     ; leading-zero fraction
 ;; variables, string selectors, custom properties
 (t (css->string '((:root (--bg "#f2f4fa") (--lapis "#1550c4"))))
    ":root{--bg:#f2f4fa;--lapis:#1550c4;}")
 (t (css->string '((".nav a" (color (var dim)) (font-size (em 0 92)))))
    ".nav a{color:var(--dim);font-size:0.92em;}")
 ;; compound value + multi-value declaration
 (t (css->string '((.box (border (px 1) solid (var line)) (padding (em 1 10) (em 1 20)))))
    ".box{border:1px solid var(--line);padding:1.1em 1.2em;}")
 ;; calc and rgba (rgb parts bare integers; alpha a unitless decimal)
 (t (css->string '((.x (width (calc (pct 100) - (em 2))) (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6))))))
    ".x{width:calc(100% - 2em);box-shadow:0 1px 3px rgba(16,20,42,0.06);}")
 ;; @media nesting
 (t (css->string '((@media "(max-width: 42em)"
                     (".nav-links" (gap (em 1)) (font-size (em 0 88))))))
    "@media (max-width: 42em){.nav-links{gap:1em;font-size:0.88em;}}")
 ;; composition: a stylesheet is just a list -- append shared + page
 (let ((base '((body (margin 0)))) (page '((h1 (font-size (em 3))))))
   (t (css->string (append base page)) "body{margin:0;}h1{font-size:3em;}")))

;; expect: #t
;; (web css): render rule lists to CSS strings. Exact integers only,
;; no floats. em/rem take x100; other units take natural integers.
(import (web css))

(define (t got want) (string=? got want))

(and
 ;; em/rem: argument x100 -> exact decimal, no f64 noise
 (t (css->string '((x (a (em 92))))) "x{a:0.92em;}")     ; 0.92em
 (t (css->string '((x (a (em 340))))) "x{a:3.4em;}")     ; 3.4em, not 3.3999
 (t (css->string '((x (a (em 10))))) "x{a:0.1em;}")      ; 0.1em
 (t (css->string '((x (a (em 100))))) "x{a:1em;}")       ; whole
 (t (css->string '((x (a (em 5))))) "x{a:0.05em;}")      ; 0.05em
 (t (css->string '((x (a (rem 150))))) "x{a:1.5rem;}")
 ;; px joins the x100 group (fraction-prone length unit)
 (t (css->string '((x (a (px 1300))))) "x{a:13px;}")
 (t (css->string '((x (a (px 1350))))) "x{a:13.5px;}")
 (t (css->string '((x (a (px 100))))) "x{a:1px;}")
 ;; whole-number units stay natural
 (t (css->string '((x (a (pct 50))))) "x{a:50%;}")
 (t (css->string '((x (a (vh 100))))) "x{a:100vh;}")
 (t (css->string '((x (a (deg 45))))) "x{a:45deg;}")
 ;; bare integers and strings
 (t (css->string '((body (margin 0) (line-height "1.6")))) "body{margin:0;line-height:1.6;}")
 ;; variables, string selectors, custom properties
 (t (css->string '((:root (--bg "#f2f4fa") (--lapis "#1550c4"))))
    ":root{--bg:#f2f4fa;--lapis:#1550c4;}")
 (t (css->string '((".nav a" (color (var dim)) (font-size (em 92)))))
    ".nav a{color:var(--dim);font-size:0.92em;}")
 ;; compound value + multi-value declaration
 (t (css->string '((.box (border (px 100) solid (var line)) (padding (em 110) (em 120)))))
    ".box{border:1px solid var(--line);padding:1.1em 1.2em;}")
 ;; calc and rgba
 (t (css->string '((.x (width (calc (pct 100) - (em 200))) (box-shadow 0 (px 100) (px 300) (rgba 16 20 42 6)))))
    ".x{width:calc(100% - 2em);box-shadow:0 1px 3px rgba(16,20,42,6);}")
 ;; @media nesting
 (t (css->string '((@media "(max-width: 42em)"
                     (".nav-links" (gap (em 100)) (font-size (em 88))))))
    "@media (max-width: 42em){.nav-links{gap:1em;font-size:0.88em;}}")
 ;; composition: a stylesheet is just a list -- append shared + page
 (let ((base '((body (margin 0)))) (page '((h1 (font-size (em 300))))))
   (t (css->string (append base page)) "body{margin:0;}h1{font-size:3em;}")))

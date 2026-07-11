;; expect: #t
;; (web css): render rule lists to CSS strings. Pure, fully verifiable.
(import (web css))

(define (t got want) (string=? got want))

(and
 ;; clean numbers: f64 noise removed, integers bare
 (t (num->css 1.6) "1.6")
 (t (num->css 0.92) "0.92")          ; not "0.920000000000"
 (t (num->css 3.4) "3.4")            ; not "3.399999999999"
 (t (num->css 0.032) "0.032")
 (t (num->css 13) "13")
 (t (num->css 2.0) "2")
 (t (num->css 0) "0")
 ;; a basic rule with a variable and a unit value
 (t (css->string '((body (margin 0) (background (var bg)) (line-height 1.6))))
    "body{margin:0;background:var(--bg);line-height:1.6;}")
 ;; custom properties and a string selector
 (t (css->string '((:root (--bg "#f2f4fa") (--lapis "#1550c4"))))
    ":root{--bg:#f2f4fa;--lapis:#1550c4;}")
 (t (css->string '((".nav a" (color (var dim)) (font-size (em 0.92)))))
    ".nav a{color:var(--dim);font-size:0.92em;}")
 ;; compound value (space-joined) and multi-value declaration
 (t (css->string '((.box (border (px 1) solid (var line)) (padding (em 1.1) (em 1.2)))))
    ".box{border:1px solid var(--line);padding:1.1em 1.2em;}")
 ;; calc and rgba
 (t (css->string '((.x (width (calc (pct 100) - (em 2))) (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 0.06)))))
    ".x{width:calc(100% - 2em);box-shadow:0 1px 3px rgba(16,20,42,0.06);}")
 ;; @media nesting
 (t (css->string '((@media "(max-width: 42em)"
                     (".nav-links" (gap (em 1)) (font-size (em 0.88))))))
    "@media (max-width: 42em){.nav-links{gap:1em;font-size:0.88em;}}")
 ;; composition: a stylesheet is just a list -- append shared + page
 (let ((base '((body (margin 0))))
       (page '((h1 (font-size (em 3))))))
   (t (css->string (append base page))
      "body{margin:0;}h1{font-size:3em;}")))

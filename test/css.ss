;; expect: #t
;; (web css): render rule lists to CSS strings. No floats; a unit form
;; takes one integer (whole), two (whole and fraction), or three (and a
;; minimum width for the fraction).
;;
;; SPEC CHANGE, not a defect fix.  A fraction used to mean HUNDREDTHS
;; whatever it was written as, so (em 3 4) was 3.04em.  It now renders
;; with the digits it was written with -- (em 3 4) is 3.4em -- and a
;; third operand is the minimum width, left-padded with zeros, which is
;; the model (fl W F [width]) already uses in (gfx glsl).  The point of
;; the change is that one mental model covers both.
;;
;; Which spellings move, and which do not:
;;
;;   written        old        new        migration
;;   (em 3 4)       3.04em     3.4em      write (em 3 4 2) for the old
;;   (em 3 40)      3.4em      3.4em      none -- two digits, unchanged
;;   (em 0 625)     0.625em    0.625em    none -- already past two
;;   (em 3)         3em        3em        none -- no fraction at all
;;
;; So only a ONE-DIGIT fraction changes meaning, and it changes to what
;; it reads like.  A sweep of this tree found no such call site outside
;; documentation prose: nothing that renders a page moved.
;;
;; The cells below are of two kinds and are marked:
;;   DETECTOR  fails under the old rule -- these are what the change is
;;   PIN       passes under both rules -- these hold what must not move
(import (web css))

(define (t got want) (string=? got want))
;; a form that must be refused rather than rendered.  Extra operands
;; used to be dropped in silence, so (em 1 5 2 9) rendered as though the
;; 9 had never been written -- the quietest way to be wrong.
(define (bad? v) (guard (e (#t #t)) (css->string v) #f))

(and
 ;; whole values are natural (no x100 inflation)
 (t (css->string '((x (a (em 1))))) "x{a:1em;}")
 (t (css->string '((x (a (px 13))))) "x{a:13px;}")
 (t (css->string '((x (a (pct 50))))) "x{a:50%;}")
 (t (css->string '((x (a (vh 100))))) "x{a:100vh;}")
 (t (css->string '((x (a (deg 120))))) "x{a:120deg;}")
 ;; a fraction renders with the digits it was written with; a width
 ;; left-pads with zeros; trailing zeros are always dropped
 (t (css->string '((x (a (em 0 92))))) "x{a:0.92em;}")   ; PIN
 (t (css->string '((x (a (em 3 40))))) "x{a:3.4em;}")    ; PIN  40 -> .4
 (t (css->string '((x (a (em 1 15))))) "x{a:1.15em;}")   ; PIN
 (t (css->string '((x (a (px 13 50))))) "x{a:13.5px;}")  ; PIN
 (t (css->string '((x (a (rem 0 30))))) "x{a:0.3rem;}")  ; PIN
 (t (css->string '((x (a (em 0 625))))) "x{a:0.625em;}") ; PIN
 (t (css->string '((x (a (em 3 4))))) "x{a:3.4em;}")     ; DETECTOR was 3.04
 (t (css->string '((x (a (em 0 2))))) "x{a:0.2em;}")     ; DETECTOR was 0.02
 (t (css->string '((x (a (px 13 5))))) "x{a:13.5px;}")   ; DETECTOR was 13.05
 (t (css->string '((x (a (em 3 4 2))))) "x{a:3.04em;}")  ; PIN  the migration spelling
 (t (css->string '((x (a (em 0 2 2))))) "x{a:0.02em;}")  ; PIN
 (t (css->string '((x (a (em 0 625 2))))) "x{a:0.625em;}") ; PIN width is a MINIMUM
 ;; padding comes BEFORE stripping.  Stripping first would make these
 ;; 0.005em and 1.0001em -- the order is the whole of the rule.
 (t (css->string '((x (a (em 0 50 3))))) "x{a:0.05em;}")   ; DETECTOR
 (t (css->string '((x (a (em 1 100 4))))) "x{a:1.01em;}")  ; DETECTOR
 (t (css->string '((x (a (em 0 40 2))))) "x{a:0.4em;}")    ; PIN
 (t (css->string '((x (a (em 0 40 1))))) "x{a:0.4em;}")    ; PIN
 (t (css->string '((x (a (em 0 625 4))))) "x{a:0.0625em;}"); DETECTOR
 ;; a fraction of zero has no digits left after stripping, so there is
 ;; no decimal point either -- "1.em" is not CSS
 (t (css->string '((x (a (em 1 0))))) "x{a:1em;}")         ; DETECTOR was 1.em
 (t (css->string '((x (a (em 0 0))))) "x{a:0em;}")         ; DETECTOR
 (t (css->string '((x (a (em 1 0 3))))) "x{a:1em;}")       ; DETECTOR
 ;; a long fraction keeps every digit -- except a trailing zero, which
 ;; is dropped like any other.  The value below ends in 0 and therefore
 ;; renders nineteen digits, not twenty: "keeps every digit" and "drops
 ;; trailing zeros" are the same rule seen from two sides, and a cell
 ;; asserting the first without the second would be asserting a
 ;; contradiction.
 (t (css->string '((x (a (em 0 12345678901234567891)))))
    "x{a:0.12345678901234567891em;}")                      ; PIN
 (t (css->string '((x (a (em 0 12345678901234567890)))))
    "x{a:0.1234567890123456789em;}")                       ; PIN
 ;; the sign lives in the whole part only
 (t (css->string '((x (a (em -3 4))))) "x{a:-3.4em;}")     ; DETECTOR
 (t (css->string '((x (a (em -3 4 2))))) "x{a:-3.04em;}")  ; PIN
 ;; a width of zero says the same as leaving it out
 (t (css->string '((x (a (em 3 4 0))))) "x{a:3.4em;}")     ; PIN

 ;; ---- operands are checked, not trusted -----------------------------
 (bad? '((x (a (em)))))            ; nothing to render
 (bad? '((x (a (em 1 2 3 4)))))    ; DETECTOR the 4 used to be dropped
 (bad? '((x (a (em 1 1/2)))))      ; DETECTOR a ratio is not a digit string
 (bad? '((x (a (em 1 "5")))))      ; DETECTOR
 (bad? '((x (a (em 1 5 2.0)))))    ; DETECTOR a width is exact
 (bad? '((x (a (em 1 5 -1)))))     ; DETECTOR
 (bad? '((x (a (em 0 -5)))))       ; DETECTOR would have rendered "0.-5em"

 ;; ---- every unit, so a fix to em and px alone cannot pass -----------
 (t (css->string '((x (a (px 1 4))))) "x{a:1.4px;}")
 (t (css->string '((x (a (em 1 4))))) "x{a:1.4em;}")
 (t (css->string '((x (a (rem 1 4))))) "x{a:1.4rem;}")
 (t (css->string '((x (a (pct 1 4))))) "x{a:1.4%;}")
 (t (css->string '((x (a (vh 1 4))))) "x{a:1.4vh;}")
 (t (css->string '((x (a (vw 1 4))))) "x{a:1.4vw;}")
 (t (css->string '((x (a (vmin 1 4))))) "x{a:1.4vmin;}")
 (t (css->string '((x (a (vmax 1 4))))) "x{a:1.4vmax;}")
 (t (css->string '((x (a (fr 1 4))))) "x{a:1.4fr;}")
 (t (css->string '((x (a (deg 1 4))))) "x{a:1.4deg;}")
 (t (css->string '((x (a (s 1 4))))) "x{a:1.4s;}")
 (t (css->string '((x (a (ms 1 4))))) "x{a:1.4ms;}")
 (t (css->string '((x (a (ch 1 4))))) "x{a:1.4ch;}")
 (t (css->string '((x (a (ex 1 4))))) "x{a:1.4ex;}")
 (t (css->string '((x (a (pct 1 4 2))))) "x{a:1.04%;}")
 (t (css->string '((x (a (ms 1 4 2))))) "x{a:1.04ms;}")
 ;; bare integers and a unitless decimal (line-height); alpha likewise
 (t (css->string '((body (margin 0) (line-height (dec 1 60))))) "body{margin:0;line-height:1.6;}")
 (t (css->string '((x (a (dec 0 6))))) "x{a:0.6;}")      ; DETECTOR was 0.06
 (t (css->string '((x (a (dec 0 6 2))))) "x{a:0.06;}")   ; PIN
 (t (css->string '((x (a (dec 1 0 3))))) "x{a:1;}")      ; DETECTOR no bare dot
 (t (css->string '((x (a (dec 0 0))))) "x{a:0;}")        ; DETECTOR
 ;; variables, string selectors, custom properties
 (t (css->string '((:root (--bg "#f2f4fa") (--lapis "#1550c4"))))
    ":root{--bg:#f2f4fa;--lapis:#1550c4;}")
 (t (css->string '((".nav a" (color (var dim)) (font-size (em 0 92)))))
    ".nav a{color:var(--dim);font-size:0.92em;}")
 ;; compound value + multi-value declaration
 (t (css->string '((.box (border (px 1) solid (var line)) (padding (em 1 10) (em 1 20)))))
    ".box{border:1px solid var(--line);padding:1.1em 1.2em;}")
 ;; calc and rgba (rgb parts bare integers; alpha a unitless decimal)
 (t (css->string '((.x (width (calc (pct 100) - (em 2))) (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6 2))))))
    ".x{width:calc(100% - 2em);box-shadow:0 1px 3px rgba(16,20,42,0.06);}")
 ;; @media nesting
 (t (css->string '((@media "(max-width: 42em)"
                     (".nav-links" (gap (em 1)) (font-size (em 0 88))))))
    "@media (max-width: 42em){.nav-links{gap:1em;font-size:0.88em;}}")
 ;; composition: a stylesheet is just a list -- append shared + page
 (let ((base '((body (margin 0)))) (page '((h1 (font-size (em 3))))))
   (t (css->string (append base page)) "body{margin:0;}h1{font-size:3em;}"))
 ;; a palette alist becomes the :root custom-property rule
 (t (css->string (list (palette->root '((ink "#14203a") (bg "#f2f4fa")))))
    ":root{--ink:#14203a;--bg:#f2f4fa;}"))

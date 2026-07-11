;; Express CSS in Scheme: render a rule list to a CSS string.
;;
;; The CSS analogue of (web html). A stylesheet is a list of rules;
;; a rule is (selector (prop value ...) ...). Selectors are symbols
;; (element names) or strings (anything with . # : > space).
;;
;; No floats anywhere -- the flonum printer isn't exact. Unit forms take
;; variable arity: one integer is the whole value, two integers are the
;; integer and fractional parts, so whole values stay natural (no x100
;; inflation) and fractions stay exact integers (no floats):
;;   (em 1)     -> "1em"      (em 0 92) -> "0.92em"   (em 3 4) -> "3.4em"
;;   (px 13)    -> "13px"     (px 13 5) -> "13.5px"
;;   (pct 50)   -> "50%"      (vh 100)  -> "100vh"    (deg 120) -> "120deg"
;; Non-unit values:
;;   integer           -> itself ("0", "650" for z-index / rgb parts)
;;   string            -> literal ("#fff", "solid", "1.6")
;;   symbol            -> its name (none, inherit, ...)
;;   (var ink)         -> "var(--ink)"
;;   (calc V ...)      -> "calc(V ...)"
;;   (rgba 16 20 42 "0.06") -> "rgba(16,20,42,0.06)"
;;   (A B ...)         -> "A B ..."  ; a space-joined compound value
;; @media / @keyframes / @supports nest rules.
;;
;;   (css->string
;;     `((:root (--bg "#f2f4fa"))
;;       (body (margin 0) (background (var bg)) (line-height "1.6"))
;;       (".nav a" (color (var dim)) (font-size (em 0 92)))
;;       (@media "(max-width: 42em)"
;;         (".nav" (gap (em 1))))))
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web css)
  (export css->string num->css)
  (import (rnrs))

  (define (join parts sep)
    (cond
     ((null? parts) "")
     ((null? (cdr parts)) (car parts))
     (else (string-append (car parts) sep (join (cdr parts) sep)))))

  ;; a scalar: exact integers pass through, strings pass through. No
  ;; floats -- fractions are written with the two-argument unit form.
  (define (num->css n)
    (cond
     ((string? n) n)
     ((and (integer? n) (exact? n)) (number->string n))
     (else (error 'css "use an exact integer, a two-arg unit form, or a string" n))))

  ;; a unit value: (em 1) -> "1em"; (em 0 92) -> "0.92em" (whole . frac)
  (define (unit->css args suffix)
    (string-append
     (cond
      ((null? args) (error 'css "unit form needs an argument"))
      ((null? (cdr args)) (num->css (car args)))
      (else (string-append (num->css (car args)) "." (num->css (cadr args)))))
     suffix))

  (define units
    '((px . "px") (em . "em") (rem . "rem") (pct . "%") (vh . "vh")
      (vw . "vw") (vmin . "vmin") (vmax . "vmax") (fr . "fr") (deg . "deg")
      (s . "s") (ms . "ms") (ch . "ch") (ex . "ex")))
  (define (val->css v)
    (cond
     ((string? v) v)
     ((number? v) (num->css v))
     ((symbol? v) (symbol->string v))
     ((pair? v)
      (let* ((h (car v)) (u (and (symbol? h) (assq h units))))
        (cond
         (u (unit->css (cdr v) (cdr u)))
         ((eq? h 'var) (string-append "var(--" (symbol->string (cadr v)) ")"))
         ((eq? h 'calc) (string-append "calc(" (join (map val->css (cdr v)) " ") ")"))
         ((eq? h 'rgba) (string-append "rgba(" (join (map val->css (cdr v)) ",") ")"))
         ((eq? h 'rgb) (string-append "rgb(" (join (map val->css (cdr v)) ",") ")"))
         (else (join (map val->css v) " ")))))       ; compound: 1px solid ...
     (else (error 'css "bad value" v))))

  ;; ---- selectors, declarations, rules ----
  (define (sel->css s)
    (cond ((string? s) s)
          ((symbol? s) (symbol->string s))
          (else (error 'css "bad selector" s))))
  (define (decl->css d)
    (string-append (sel->css (car d)) ":"
                   (join (map val->css (cdr d)) " ") ";"))
  (define (rule->css r)
    (let ((head (car r)))
      (cond
       ((eq? head '@media)
        (string-append "@media " (cadr r) "{"
                       (apply string-append (map rule->css (cddr r))) "}"))
       ((eq? head '@keyframes)
        (string-append "@keyframes " (val->css (cadr r)) "{"
                       (apply string-append (map rule->css (cddr r))) "}"))
       ((eq? head '@supports)
        (string-append "@supports " (cadr r) "{"
                       (apply string-append (map rule->css (cddr r))) "}"))
       (else
        (string-append (sel->css head) "{"
                       (apply string-append (map decl->css (cdr r))) "}")))))

  (define (css->string rules)
    (apply string-append (map rule->css rules))))

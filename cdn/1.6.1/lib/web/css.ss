;; Express CSS in Scheme: render a rule list to a CSS string.
;;
;; The CSS analogue of (web html). A stylesheet is a list of rules;
;; a rule is (selector (prop value ...) ...). Selectors are symbols
;; (element names) or strings (anything with . # : > space).
;;
;; No floats anywhere -- the flonum printer isn't exact. Unit forms take
;; variable arity: (unit W) is the whole value, (unit W F) adds the
;; fraction's digits as written, and (unit W F width) states a minimum
;; width so a leading zero can be recovered -- Scheme has already
;; dropped it from the literal by the time we see it. Whole values stay
;; natural (no x100 inflation), fractions stay exact integers (no
;; floats), and every value is expressible:
;;   (em 1)   -> "1em"     (em 0 92) -> "0.92em"  (em 3 40) -> "3.4em"
;;   (em 3 4) -> "3.4em"   (em 3 4 2) -> "3.04em" (px 13)   -> "13px"
;;   (pct 50) -> "50%"     (vh 100)  -> "100vh"   (deg 120) -> "120deg"
;; The digits are rendered by (web frac), shared with (gfx glsl), so
;; (em 3 4) and (fl 3 4) name the same number.
;; Non-unit values:
;;   integer           -> itself ("0", "650" for z-index / rgb parts)
;;   string            -> literal ("#fff", "solid")
;;   symbol            -> its name (none, inherit, ...)
;;   (dec 1 60)        -> "1.6"   ; a unitless decimal (line-height)
;;   (var ink)         -> "var(--ink)"
;;   (calc V ...)      -> "calc(V ...)"
;;   (rgba 16 20 42 (dec 0 6)) -> "rgba(16,20,42,0.6)"   ; alpha
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
  (export css->string num->css palette->root)
  (import (rnrs) (web frac))

  ;; a palette alist ((name value) ...) as a :root rule of custom
  ;; properties -- one binding names a colour for Scheme AND css:
  ;;   (palette->root '((ink "#14203a"))) -> (:root (--ink "#14203a"))
  (define (palette->root palette)
    (cons ':root
          (map (lambda (p)
                 (list (string->symbol
                        (string-append "--" (symbol->string (car p))))
                       (cadr p)))
               palette)))

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
     (else (error 'css "use an exact integer, a unit form, or a string" n))))

  ;; a unit value: (em 1) -> "1em"; (em 0 92) -> "0.92em" (whole and
  ;; fraction); (em 3 4) -> "3.4em"; (em 3 4 2) -> "3.04em", the third
  ;; operand being the fraction's MINIMUM width, left-padded with zeros.
  ;;
  ;; A fraction used to mean hundredths however it was written, which is
  ;; not what (fl W F [width]) means in (gfx glsl) -- and the same
  ;; author writing both had two rules to keep straight.  One rule now,
  ;; from (web frac).
  ;;
  ;; The operands are checked rather than taken on trust: extra ones
  ;; used to be dropped in silence, so (em 1 5 2 9) rendered as though
  ;; the 9 had never been written.
  (define (unit->css args suffix)
    (unless (pair? args) (error 'css "unit form needs an argument"))
    (when (and (pair? (cdr args)) (pair? (cddr args)) (pair? (cdddr args)))
      (error 'css "a unit form takes at most a whole, a fraction and a width"
             args))
    (string-append
     (if (null? (cdr args))
         (num->css (car args))
         (let ((f (cadr args)))
           (unless (and (integer? f) (exact? f) (not (< f 0)))
             (error 'css "a unit fraction is an exact non-negative integer; the sign belongs to the whole part" f))
           (let* ((width (if (pair? (cddr args)) (caddr args)
                             (string-length (number->string f))))
                  (_ (unless (and (integer? width) (exact? width)
                                  (not (< width 0)))
                       (error 'css "a unit width is an exact non-negative integer" width)))
                  (d (frac-digits f width)))
             ;; no digits left means no decimal point: "1.em" is not a
             ;; CSS value, and this used to emit exactly that for (em 1 0)
             (if (string=? d "")
                 (num->css (car args))
                 (string-append (num->css (car args)) "." d)))))
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
         ;; a unitless decimal, same whole/frac convention as units:
         ;; (dec 0 6) -> "0.6" (rgba alpha), (dec 1 6) -> "1.6" (line-height)
         ((eq? h 'dec) (unit->css (cdr v) ""))
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

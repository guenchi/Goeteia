;; Express CSS in Scheme: render a rule list to a CSS string.
;;
;; The CSS analogue of (web html). A stylesheet is a list of rules;
;; a rule is (selector (prop value ...) ...). Selectors are symbols
;; (element names) or strings (anything with . # : > space).
;;
;; No floats anywhere -- the flonum printer isn't exact, so values are
;; exact integers (or strings). em/rem/ex/ch take their argument scaled
;; by 100, so fractional lengths stay integers:
;;   (em 92)  -> "0.92em"   (em 10) -> "0.1em"   (em 100) -> "1em"
;;   (px 1300)-> "13px"     (px 1350) -> "13.5px"     (px 100) -> "1px"
;; Whole-number units take a natural integer:
;;   (pct 50) -> "50%"      (vh 100) -> "100vh"       (deg 45) -> "45deg"
;; Values:
;;   integer           -> itself ("0", "650")
;;   string            -> literal ("#fff", "solid", "1.6")
;;   symbol            -> its name (none, inherit, ...)
;;   (var ink)         -> "var(--ink)"
;;   (calc V ...)      -> "calc(V ...)"
;;   (rgba 16 20 42 6) -> "rgba(16,20,42,6)"
;;   (A B ...)         -> "A B ..."  ; a space-joined compound value
;; @media / @keyframes / @supports nest rules.
;;
;;   (css->string
;;     `((:root (--bg "#f2f4fa"))
;;       (body (margin 0) (background (var bg)) (line-height "1.6"))
;;       (".nav a" (color (var dim)) (font-size (em 92)))
;;       (@media "(max-width: 42em)"
;;         (".nav" (gap (em 100))))))
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

  ;; ---- numbers: exact only, no floats ----
  (define (strip-trailing-zeros s)
    (let loop ((i (string-length s)))
      (if (and (> i 0) (char=? (string-ref s (- i 1)) #\0))
          (loop (- i 1))
          (substring s 0 i))))
  ;; render an integer scaled by `scale` (a power of ten) as an exact
  ;; decimal: hundredths 92 scale 100 -> "0.92", 340 -> "3.4", 100 -> "1"
  (define (scaled->css n scale digits)
    (if (string? n) n
        (let* ((neg (< n 0)) (a (if neg (- n) n))
               (ip (quotient a scale)) (fp (remainder a scale)))
          (string-append
           (if neg "-" "")
           (number->string ip)
           (if (= fp 0) ""
               (string-append "." (strip-trailing-zeros (pad fp digits))))))))
  (define (pad n digits)
    (let loop ((s (number->string n)))
      (if (< (string-length s) digits) (loop (string-append "0" s)) s)))
  ;; a bare value: exact integers pass through; strings pass through.
  ;; No floats -- use unit forms (em 92) or strings ("1.6") for fractions.
  (define (num->css n)
    (cond
     ((string? n) n)
     ((and (integer? n) (exact? n)) (number->string n))
     (else (error 'css "use an exact integer, a unit form, or a string" n))))
  (define (hundredths n) (scaled->css n 100 2))

  ;; ---- values ----
  (define units
    '((px . "px") (em . "em") (rem . "rem") (pct . "%") (vh . "vh")
      (vw . "vw") (vmin . "vmin") (vmax . "vmax") (fr . "fr") (deg . "deg")
      (s . "s") (ms . "ms") (ch . "ch") (ex . "ex")))
  ;; fraction-prone length units take their argument scaled by 100 --
  ;; (em 92) -> 0.92em, (px 1300) -> 13px, (px 1350) -> 13.5px, (em 100)
  ;; -> 1em -- so fractional lengths stay integers. Whole-number units
  ;; (% vh vw deg fr s ms) take a natural integer, so 50% is (pct 50).
  (define hundredths-units '(em rem px ex ch))
  (define (val->css v)
    (cond
     ((string? v) v)
     ((number? v) (num->css v))
     ((symbol? v) (symbol->string v))
     ((pair? v)
      (let* ((h (car v)) (u (and (symbol? h) (assq h units))))
        (cond
         (u (string-append (if (memq h hundredths-units)
                               (hundredths (cadr v))
                               (num->css (cadr v)))
                           (cdr u)))
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

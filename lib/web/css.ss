;; Express CSS in Scheme: render a rule list to a CSS string.
;;
;; The CSS analogue of (web html). A stylesheet is a list of rules;
;; a rule is (selector (prop value ...) ...). Selectors are symbols
;; (element names) or strings (anything with . # : > space). Values:
;;   number            -> cleaned decimal ("1.6", "0.92" -- no f64 noise)
;;   string            -> literal ("#fff", "solid")
;;   symbol            -> its name (none, inherit, ...)
;;   (em 0.92)         -> "0.92em"   ; unit forms: px em rem pct vh vw
;;                                     vmin vmax fr deg s ms ch ex
;;   (var ink)         -> "var(--ink)"
;;   (calc V)          -> "calc(V)"
;;   (rgba 16 20 42 .5)-> "rgba(16,20,42,0.5)"
;;   (A B ...)         -> "A B ..."  ; a space-joined compound value
;; @media / @keyframes nest rules.
;;
;;   (css->string
;;     `((:root (--bg "#f2f4fa"))
;;       (body (margin 0) (background (var bg)) (line-height 1.6))
;;       (".nav a" (color (var dim)) (font-size (em 0.92)))
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

  ;; ---- numbers: strip f64 noise (round to 6 dp, drop trailing zeros) ----
  (define (strip-trailing-zeros s)
    (let loop ((i (string-length s)))
      (if (and (> i 0) (char=? (string-ref s (- i 1)) #\0))
          (loop (- i 1))
          (substring s 0 i))))
  (define (pad6 s)
    (if (< (string-length s) 6) (pad6 (string-append "0" s)) s))
  (define (flonum->css x)
    (let* ((neg (< x 0))
           (a (if neg (- x) x))
           ;; round-half-up via floor (round/ceiling aren't primitives),
           ;; valid because a is non-negative here
           (scaled (inexact->exact (floor (+ (* a 1000000) 0.5))))
           (ip (quotient scaled 1000000))
           (fp (remainder scaled 1000000)))
      (string-append
       (if neg "-" "")
       (number->string ip)
       (if (= fp 0) "" (string-append "." (strip-trailing-zeros (pad6 (number->string fp))))))))
  (define (num->css n)
    (cond
     ((string? n) n)
     ((and (integer? n) (exact? n)) (number->string n))
     ((integer? n) (number->string (inexact->exact n)))   ; 2.0 -> "2"
     (else (flonum->css n))))

  ;; ---- values ----
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
         (u (string-append (num->css (cadr v)) (cdr u)))
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

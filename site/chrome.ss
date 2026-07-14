;; Shared page chrome for the Goeteia site, in Scheme.
;; render-page assembles a full HTML document from a body; the nav,
;; footer, the "Built in pure Scheme" badge and the view-source overlay
;; are the same on every page. Rendered to a string by Goeteia.
(library (chrome)
  (export render-page read-file write-file base-styles footer-styles palette
          card feat section* soft-box inline-code
          styled styled-css)
  (import (rnrs) (web html) (web css))

  ;; ---- reusable (web css) declaration helpers ----
  ;; the pale rounded panel used for code blocks and command chips
  (define (soft-box)
    '((background "#eef1f9") (border (px 1) solid (var line)) (border-radius (px 8))))
  ;; monospace + accent colour for inline code
  (define (inline-code)
    '((font-family (var mono)) (color (var lapis))))

  ;; ---- styled: css attached at the element, compiled to classes ----
  ;; The React lesson, taken at build time: the AUTHOR writes styles
  ;; on the element (values are ordinary bindings -- change one and
  ;; every use follows); the COMPILER interns each distinct style set
  ;; to one generated class, so nine identical cards cost one rule.
  ;;
  ;;   (styled 'button 'run
  ;;     `((background ,lapis)
  ;;       (:hover (filter "brightness(1.1)"))   ; pseudo-class
  ;;       ("h3" (margin 0))                     ; descendant
  ;;       (@media 42 (padding (em 1))))         ; max-width breakpoint
  ;;     '(@ (id "run")) "Run")
  ;;
  ;; Discipline: these classes are self-contained -- runtime-dynamic
  ;; styling goes through signals/CSS variables, never through here.
  (define $styled '())                  ; ((style-set . class) ...), newest first
  (define (intern-style! name sty)
    (cond
     ((assoc sty $styled) => cdr)       ; equal? style set -> same class
     (else
      (let ((cls (string-append (symbol->string name) "-"
                                (number->string (length $styled)))))
        (set! $styled (cons (cons sty cls) $styled))
        cls))))
  (define (styled tag name sty . kids)
    (let ((cls (intern-style! name sty)))
      (if (and (pair? kids) (pair? (car kids)) (eq? (car (car kids)) '@))
          `(,tag (@ (class ,cls) ,@(cdr (car kids))) ,@(cdr kids))
          `(,tag (@ (class ,cls)) ,@kids))))

  ;; every interned rule, in registration order, ready for css->string
  (define (styled-css)
    (apply append
           (map (lambda (e) ($styled-rules (cdr e) (car e)))
                (reverse $styled))))
  (define ($styled-rules cls sty)
    (let ((base (string-append "." cls)))
      (let loop ((ds sty) (plain '()) (extra '()))
        (if (null? ds)
            (cons (cons base (reverse plain)) (reverse extra))
            (let ((d (car ds)))
              (cond
               ((string? (car d))       ; ("h3" decls...): descendant
                (loop (cdr ds) plain
                      (cons (cons (string-append base " " (car d)) (cdr d))
                            extra)))
               ((eq? (car d) '@media)   ; (@media 42 decls...): max-width em
                (loop (cdr ds) plain
                      (cons `(@media ,(string-append "(max-width: "
                                                     (number->string (cadr d))
                                                     "em)")
                              ,(cons base (cddr d)))
                            extra)))
               ((and (symbol? (car d))  ; (:hover decls...): pseudo
                     (char=? (string-ref (symbol->string (car d)) 0) #\:))
                (loop (cdr ds) plain
                      (cons (cons (string-append base (symbol->string (car d)))
                                  (cdr d))
                            extra)))
               (else (loop (cdr ds) (cons d plain) extra))))))))

  ;; ---- reusable content helpers (SXML-returning) ----
  ;; a titled box: markup and its css in ONE place; every card on a
  ;; page interns to the same generated class
  (define (card title . body)
    (styled 'div 'card
      `((background (var bg2)) (border (px 1) solid (var line))
        (border-radius (px 10)) (padding (em 1 10) (em 1 20))
        (box-shadow "0 1px 3px rgba(16,20,42,.06)")
        ("h3" (margin 0 0 (em 0 40)) (font-size (em 1))
              (color (var lapis)) (font-weight 600))
        ("p" (margin 0) (color (var dim)) (font-size (em 0 92)))
        ("code" (font-family (var mono)) (color (var lapis))
                (font-size (em 0 90))))
      `(h3 ,title) `(p ,@body)))
  (define (feat title . body)
    `(div (@ (class "feat")) (h4 ,title) (p ,@body)))
  ;; a section with a heading: (section* "What's inside" node ...)
  (define (section* id heading . body)
    `(section (@ (id ,id)) (h2 ,heading) ,@body))

  ;; ---- the shared stylesheet, as data ----
  ;; the palette is Scheme data: change a colour here and every page
  ;; that renders base-styles follows.
  (define palette
    '((bg "#f2f4fa") (bg2 "#ffffff") (ink "#14203a") (dim "#566080")
      (lapis "#1550c4") (azure "#4788ee") (green "#1e7d34") (line "#dbe2ee")
      (mono "ui-monospace, \"SF Mono\", Menlo, Consolas, monospace")))
  (define (root-rule)
    (cons ':root
          (map (lambda (p)
                 (list (string->symbol (string-append "--" (symbol->string (car p))))
                       (cadr p)))
               palette)))
  ;; reset + body + links + wrap + the sticky nav, shared by every page.
  ;; wrap-width is the page's content max-width in em.
  (define (base-styles wrap-width)
    (list
     (root-rule)
     '("*" (box-sizing border-box))
     `(body (margin 0) (background (var bg)) (color (var ink))
            (font-family "-apple-system, system-ui, \"Segoe UI\", sans-serif")
            (line-height (dec 1 65)))
     '(a (color (var lapis)) (text-decoration none))
     '("a:hover" (text-decoration underline))
     `(.wrap (max-width (em ,wrap-width)) (margin 0 auto) (padding 0 (em 1 20)))
     `(.nav (position sticky) (top 0) (z-index 20)
            (background (rgba 255 255 255 (dec 0 82)))
            (backdrop-filter "saturate(1.2) blur(10px)")
            (-webkit-backdrop-filter "saturate(1.2) blur(10px)")
            (border-bottom (px 1) solid (var line)))
     '(.nav-inner (display flex) (align-items center) (justify-content space-between)
                  (height (em 3 40)))
     '(.brand (font-family "\"Times New Roman\", Times, serif")
              (font-weight 400) (font-size (em 1 45)) (color (var lapis))
              (letter-spacing (em 0 02)))
     '(".brand:hover" (text-decoration none))
     '(.nav-links (display flex) (gap (em 1 50)) (align-items center))
     '(".nav-links a" (color (var dim)) (font-size (em 0 92)))
     '(".nav-links a:hover, .nav-links a.active"
       (color (var lapis)) (text-decoration none))
     '(".nav-links a.gh" (border (px 1) solid (var line)) (border-radius (px 6))
       (padding (em 0 30) (em 0 90)) (color (var ink)))
     '(".nav-links a.gh:hover" (border-color (var lapis)))
     '(@media "(max-width: 42em)"
        (.nav-inner (height auto) (min-height (em 3 40)) (flex-wrap wrap)
                    (row-gap (em 0 10)) (padding (em 0 35) (em 1 20)))
        (.nav-links (gap (em 1)) (font-size (em 0 88))))))
  (define (footer-styles)
    '((footer (padding (em 2 50) 0 (em 3 50)) (border-top (px 1) solid (var line))
              (text-align center) (color (var dim)) (font-size (em 0 90)))))

  ;; ---- build-time file I/O ----
  (define (read-file path)
    (call-with-input-file path
      (lambda (p)
        (let loop ((acc '()))
          (let ((c (read-char p)))
            (if (eof-object? c)
                (list->string (reverse acc))
                (loop (cons c acc))))))))
  (define (write-file path s)
    (call-with-output-file path (lambda (p) (display s p))))

  ;; ---- the top navigation, with the source badge on the right ----
  (define (nav-class active page)
    (if (eq? active page) "sec active" "sec"))
  (define (nav active)
    `(nav (@ (class "nav"))
       (div (@ (class "wrap nav-inner"))
         (a (@ (class "brand") (href "index.html")) "Goeteia")
         (div (@ (class "nav-links"))
           (a (@ (class ,(nav-class active 'why)) (href "why.html")) "Why Scheme?")
           (a (@ (class ,(nav-class active 'manual)) (href "manual.html")) "Manual")
           (a (@ (class ,(nav-class active 'agent)) (href "agent.html")) "Agents")
           (a (@ (class "gh") (href "https://github.com/guenchi/Goeteia")) "GitHub")))))

  ;; a floating page badge in the top-right corner (not a nav item)
  (define (source-badge source-file)
    `(button (@ (class "src-badge") (type "button")
               (data-src ,source-file)
               (title "View the Scheme source that builds this page"))
       "Built in pure Scheme"))

  ;; ---- the hidden view-source overlay (filled by viewsrc.js) ----
  (define (overlay)
    `(div (@ (class "src-overlay") (id "src-overlay") (hidden #t))
       (div (@ (class "src-modal"))
         (div (@ (class "src-bar"))
           (span (@ (class "src-title") (id "src-title")) "")
           (button (@ (class "src-close") (id "src-close")
                      (type "button") (aria-label "Close")) "×"))
         (pre (@ (class "src-code")) (code (@ (id "src-code")) "")))))

  ;; ---- CSS for the badge + overlay, appended to each page's styles ----
  (define badge-css
    (string-append
     ".src-badge{position:fixed;top:4.3em;right:1.2em;z-index:30;min-width:0;"
     "border:1px solid var(--line);border-radius:6px;padding:.32em .8em;"
     "background:var(--bg2);color:var(--dim);font-size:.8em;font-weight:400;cursor:pointer;"
     "font-family:inherit;box-shadow:0 1px 3px rgba(16,20,42,.08)}"
     ".src-badge:hover{border-color:var(--lapis);color:var(--lapis)}"
     "@media (max-width:36em){.src-badge{display:none}}"
     ".src-overlay{position:fixed;inset:0;z-index:50;background:rgba(16,20,42,.5);"
     "display:flex;align-items:center;justify-content:center;padding:2em}"
     ".src-overlay[hidden]{display:none}"
     ".src-modal{background:var(--bg2);border:1px solid var(--line);border-radius:12px;"
     "max-width:62em;width:100%;max-height:85vh;display:flex;flex-direction:column;"
     "overflow:hidden;box-shadow:0 10px 40px rgba(16,20,42,.3)}"
     ".src-bar{display:flex;align-items:center;justify-content:space-between;"
     "padding:.6em 1em;border-bottom:1px solid var(--line)}"
     ".src-title{font-family:var(--mono);font-size:.85em;color:var(--dim)}"
     ".src-close{border:none;background:none;min-width:0;padding:0 .2em;"
     "font-size:1.5em;font-weight:400;line-height:1;"
     "color:var(--dim);cursor:pointer}.src-close:hover{color:var(--lapis)}"
     ".src-code{margin:0;padding:1.2em;overflow:auto;font-family:var(--mono);"
     "font-size:12.5px;line-height:1.5;color:var(--ink);white-space:pre}"
     ".src-code .tok-c{color:#7a869f;font-style:italic}.src-code .tok-s{color:#1e7d34}"
     ".src-code .tok-k{color:var(--lapis);font-weight:600}.src-code .tok-n{color:#b0483f}"
     ".src-code .tok-l{color:#8a5cf5}.src-code .tok-p{color:var(--dim)}"
     ".src-code .tok-h{color:var(--azure)}"))

  ;; ---- assemble a full document ----
  ;; body is a list of SXML nodes placed inside <div class="wrap">,
  ;; before the footer. An optional trailing argument is a list of extra
  ;; <script> nodes (e.g. a page renderer), emitted at the end of <body>
  ;; before the view-source script.
  (define (render-page title desc css active source-file body . opts)
    (let ((scripts (if (pair? opts) (car opts) '())))
      (html->document
       `(html (@ (lang "en"))
          (head
           (meta (@ (charset "utf-8")))
           (meta (@ (name "viewport") (content "width=device-width, initial-scale=1")))
           (link (@ (rel "icon") (type "image/svg+xml") (href "favicon.svg")))
           (title ,title)
           (meta (@ (name "description") (content ,desc)))
           ;; css is either a raw CSS string or a (web css) rule list;
           ;; <style> is raw-text, emitted unescaped. The nav brand uses
           ;; Times New Roman (a system font), so no web-font @import.
           (style ,(string-append
                    (if (string? css) css (css->string css))
                    "\n" badge-css)))
          (body
           ,(nav active)
           ,(source-badge source-file)
           (div (@ (class "wrap"))
             ,@body
             (footer "Goeteia · MIT license · "
               (a (@ (href "https://github.com/guenchi/Goeteia")) "GitHub")))
           ,(overlay)
           ,@scripts
           (script (@ (src "viewsrc.js") (defer #t)))))))))

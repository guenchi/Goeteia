;; Shared page chrome for the Goeteia site, in Scheme.
;; render-page assembles a full HTML document from a body; the nav,
;; footer, the "Built in pure Scheme" badge and the view-source overlay
;; are the same on every page. Rendered to a string by Goeteia.
(library (chrome)
  (export render-page write-file base-styles footer-styles palette
          feat section* soft-box inline-code)
  (import (rnrs) (web html) (web css) (web component))

  ;; ---- reusable (web css) declaration helpers ----
  ;; the pale rounded panel used for code blocks and command chips
  (define (soft-box)
    '((background "#eef1f9") (border (px 1) solid (var line)) (border-radius (px 8))))
  ;; monospace + accent colour for inline code
  (define (inline-code)
    '((font-family (var mono)) (color (var lapis))))

  ;; ---- reusable content helpers (SXML-returning) ----
  ;; a small feature card: markup and its css together; the agent
  ;; page's four calls intern to one class
  (define-component (feat title . body)
    (style
      (border (px 1) solid (var line)) (border-radius (px 10))
      (padding (em 0 90) (em 1)) (background (var bg))
      ("h4" (margin 0 0 (em 0 30)) (font-size (em 0 95)) (color (var lapis)))
      ("p" (margin 0) (color (var dim)) (font-size (em 0 90))))
    (div (h4 ,title) (p ,@body)))
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
  ;; reset + body + links + wrap + the sticky nav, shared by every page.
  ;; wrap-width is the page's content max-width in em.
  (define (base-styles wrap-width)
    (list
     (palette->root palette)
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
  ;; each page renders to its .html here; the stylesheets are now
  ;; (web css) data in the page sources, so nothing reads raw files
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
  ;; the source-view syntax colours (tok-*) match the live editor's,
  ;; the same palette (hl) paints the code samples with
  (define src-tokens
    '((".src-code .tok-c" (color "#7a869f") (font-style italic))
      (".src-code .tok-s" (color "#1e7d34"))
      (".src-code .tok-k" (color (var lapis)) (font-weight 600))
      (".src-code .tok-n" (color "#b0483f"))
      (".src-code .tok-l" (color "#8a5cf5"))
      (".src-code .tok-p" (color (var dim)))
      (".src-code .tok-h" (color (var azure)))))
  (define badge-styles
    `((".src-badge"
       (position fixed) (top (em 4 30)) (right (em 1 20)) (z-index 30)
       (min-width 0) (border (px 1) solid (var line)) (border-radius (px 6))
       (padding (em 0 32) (em 0 80)) (background (var bg2)) (color (var dim))
       (font-size (em 0 80)) (font-weight 400) (cursor pointer)
       (font-family inherit) (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 8))))
      (".src-badge:hover" (border-color (var lapis)) (color (var lapis)))
      (@media "(max-width:36em)" (".src-badge" (display none)))
      (".src-overlay"
       (position fixed) (inset 0) (z-index 50) (background (rgba 16 20 42 (dec 0 50)))
       (display flex) (align-items center) (justify-content center) (padding (em 2)))
      (".src-overlay[hidden]" (display none))
      (".src-modal"
       (background (var bg2)) (border (px 1) solid (var line)) (border-radius (px 12))
       (max-width (em 62)) (width (pct 100)) (max-height (vh 85)) (display flex)
       (flex-direction column) (overflow hidden)
       (box-shadow 0 (px 10) (px 40) (rgba 16 20 42 (dec 0 30))))
      (".src-bar"
       (display flex) (align-items center) (justify-content space-between)
       (padding (em 0 60) (em 1)) (border-bottom (px 1) solid (var line)))
      (".src-title" (font-family (var mono)) (font-size (em 0 85)) (color (var dim)))
      (".src-close"
       (border none) (background none) (min-width 0) (padding 0 (em 0 20))
       (font-size (em 1 50)) (font-weight 400) (line-height 1)
       (color (var dim)) (cursor pointer))
      (".src-close:hover" (color (var lapis)))
      (".src-code"
       (margin 0) (padding (em 1 20)) (overflow auto) (font-family (var mono))
       (font-size (px 12 50)) (line-height (dec 1 50)) (color (var ink)) (white-space pre))
      ,@src-tokens))

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
                    "\n" (css->string badge-styles))))
          (body
           ,(nav active)
           ,(source-badge source-file)
           (div (@ (class "wrap"))
             ,@body
             (footer "Goeteia · MIT license · "
               (a (@ (href "https://github.com/guenchi/Goeteia")) "GitHub")
               (br)
               "Powered by " (a (@ (href "https://goeteia.dev")) "Goeteia")))
           ,(overlay)
           ,@scripts
           (script (@ (src "viewsrc.js") (defer #t)))))))))

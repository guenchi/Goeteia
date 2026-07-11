;; Shared page chrome for the Goeteia site, in Scheme.
;; render-page assembles a full HTML document from a body; the nav,
;; footer, the "Built in pure Scheme" badge and the view-source overlay
;; are the same on every page. Rendered to a string by Goeteia.
(library (chrome)
  (export render-page read-file write-file)
  (import (rnrs) (web html))

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
     ".src-badge{position:fixed;top:4.3em;right:1.2em;z-index:30;"
     "border:1px solid var(--line);border-radius:6px;padding:.32em .8em;"
     "background:var(--bg2);color:var(--dim);font-size:.8em;cursor:pointer;"
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
     ".src-close{border:none;background:none;font-size:1.5em;line-height:1;"
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
           (title ,title)
           (meta (@ (name "description") (content ,desc)))
           ;; <style> is a raw-text element -- its content is emitted
           ;; unescaped, so no (raw ...) wrapper (and a raw node here traps)
           (style ,(string-append css "\n" badge-css)))
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

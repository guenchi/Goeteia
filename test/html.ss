;; expect: #t
;; (web html): SXML -> HTML string. Pure, so fully verifiable here.
(import (web html))

(define (t got want) (string=? got want))

(and
 ;; element + attribute + text escaping
 (t (sxml->html '(div (@ (class "a")) "x < y & z"))
    "<div class=\"a\">x &lt; y &amp; z</div>")
 ;; attribute-value escaping (quotes and &)
 (t (sxml->html '(a (@ (href "?a=1&b=\"2\"")) "go"))
    "<a href=\"?a=1&amp;b=&quot;2&quot;\">go</a>")
 ;; void element: no closing tag
 (t (sxml->html '(img (@ (src "a.png") (alt "b"))))
    "<img src=\"a.png\" alt=\"b\">")
 ;; boolean attributes: #t present, #f omitted
 (t (sxml->html '(input (@ (type "checkbox") (checked #t) (disabled #f))))
    "<input type=\"checkbox\" checked>")
 ;; numbers as text, mixed children
 (t (sxml->html '(p "n = " 42)) "<p>n = 42</p>")
 ;; nested
 (t (sxml->html '(ul (li "a") (li "b")))
    "<ul><li>a</li><li>b</li></ul>")
 ;; raw-text elements are not escaped
 (t (sxml->html '(style "body > p { color: red }"))
    "<style>body > p { color: red }</style>")
 ;; raw node injects literal markup
 (t (sxml->html (list 'div (raw "<b>x</b>")))
    "<div><b>x</b></div>")
 ;; element with no attrs and no kids
 (t (sxml->html '(br)) "<br>")
 ;; html-escape standalone
 (t (html-escape "a<b>&c") "a&lt;b&gt;&amp;c")
 ;; full document
 (t (html->document '(html (@ (lang "en")) (body (h1 "Hi"))))
    "<!DOCTYPE html>\n<html lang=\"en\"><body><h1>Hi</h1></body></html>\n"))

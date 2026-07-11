;; expect: #t
;; Direct-style fetch over JSPI: js-await suspends the wasm stack on a
;; promise and resumes with its value, so HTTP reads like sequential
;; blocking code. Mock fetch resolves asynchronously (a real microtask
;; hop). Skips (still #t) without JSPI support in the engine.
(import (rnrs) (web js) (web fetch) (web rpc))

(js-eval "globalThis.__log = []; globalThis.fetch = (url, opts) => { globalThis.__log.push(url + '|' + ((opts && opts.method) || 'GET') + '|' + ((opts && opts.body) || '')); const reply = url === '/rpc' ? '(ok (sum . 42))' : 'hello ' + url; return Promise.resolve({ status: 200, ok: true, text: () => Promise.resolve(reply), headers: { get: n => n === 'X-Id' ? 'abc' : null } }) }")

(if (not (fetch-direct?))
    (begin (display "#t") (display "") )   ; no JSPI: vacuous pass
    (let* (;; a plain GET: two suspensions (fetch, then .text())
           (t1 (http-get "/hello"))
           ;; sequential calls: the second sees the first's completion
           (t2 (http-get "/second"))
           ;; response accessors
           (r (fetch "/third"))
           (status (response-status r))
           (okness (response-ok? r))
           (hdr (response-header r "X-Id"))
           (miss (response-header r "Nope"))
           ;; POST with body + content type
           (t3 (http-post "/post-here" "the body" "application/sexpr"))
           ;; direct-style rpc on top
           (reply (rpc "/rpc" '(add 40 2)))
           (log (js-get (js-global) "__log")))
      (display
       (and (string=? t1 "hello /hello")
            (string=? t2 "hello /second")
            (= status 200)
            okness
            (equal? hdr "abc")
            (not miss)
            (string=? t3 "hello /post-here")
            (equal? reply '(ok (sum . 42)))
            ;; the wire log, in order
            (= (js->number (js-get log "length")) 5)
            (string=? (js->string (js-index log 0)) "/hello|GET|")
            (string=? (js->string (js-index log 3)) "/post-here|POST|the body")
            (string=? (js->string (js-index log 4)) "/rpc|POST|(add 40 2)")))))
(if #f #f)

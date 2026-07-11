;; s-expression RPC over HTTP: the browser half.
;;
;; Both ends speak Scheme, so there is no codec: write on this side,
;; read on the other. The server half is Igropyr's (igropyr sexpr) +
;; app-rpc -- requests are (tag arg ...), replies are (ok ...) or
;; (error ...), everything stays data.
;;
;;   (rpc! "/rpc" '(get-user 42)
;;     (lambda (reply) ...)          ; (ok (user (id . 42) ...))
;;     (lambda (e) ...))             ; optional: network/parse failure
;;
;; Callback style until JSPI lands (then a direct-style rpc can wrap
;; this). Exact integers and ratios cross the wire intact; stick to
;; the wire whitelist -- lists, symbols, strings, exact integers and
;; ratios, booleans -- and dispatch on tags, never evaluate payloads.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web rpc)
  (export rpc! rpc-serialize rpc-parse)
  (import (rnrs) (web js))

  (define (rpc-serialize datum)
    (with-output-to-string (lambda () (write datum))))

  (define (rpc-parse text)
    (read (open-input-string text)))

  (define (rpc! url datum on-reply . more)
    (let ((on-error (if (pair? more) (car more) (lambda (e) (js-undefined))))
          (opts (js-eval "({method:'POST',headers:{'Content-Type':'application/sexpr'}})")))
      (js-set! opts "body" (rpc-serialize datum))
      (js-method
       (js-method
        (js-method (js-call (js-get (js-global) "fetch") (js-undefined)
                            url opts)
                   "then" (lambda (resp) (js-method resp "text")))
        "then" (lambda (text)
                 (on-reply (rpc-parse (js->string text)))
                 (js-undefined)))
       "catch" (lambda (e) (on-error e) (js-undefined))))))

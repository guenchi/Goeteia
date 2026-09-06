;; Direct-style HTTP over JSPI: fetch that reads like a blocking call.
;;
;;   (let* ((user   (rpc "/rpc" '(get-user 42)))          ; (web rpc)
;;          (page   (http-get "/manual.md"))
;;          (resp   (fetch "/api" '((method . "POST") (body . "...")))))
;;     ...)
;;
;; Each call suspends the whole wasm stack on the underlying promise
;; (js-await) and resumes with the value -- sequential code, no
;; callbacks, no coloring; the page stays responsive while suspended.
;; Needs a JSPI engine (Chrome stable; Node with
;; --experimental-wasm-jspi); without it the host's await import is
;; the identity and these return unresolved promises -- feature-detect
;; with (fetch-direct?) and fall back to (web rpc)'s callback rpc!.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web fetch)
  (export fetch fetch-direct? http-get http-post
          response-status response-ok? response-text response-header)
  (import (rnrs) (web js))

  ;; does the host have real JSPI? (the identity fallback would hand
  ;; a Promise straight back; a suspending await never can)
  (define (fetch-direct?)
    (js-truthy? (js-eval "typeof WebAssembly.Suspending === 'function'")))

  ;; opts: an alist -- ((method . "POST") (body . "...")
  ;;                    (headers . (("Content-Type" . "text/plain"))))
  (define (fetch url . more)
    (let ((o (js-eval "({})")))
      (when (pair? more)
        (for-each
         (lambda (kv)
           (if (eq? (car kv) 'headers)
               (let ((h (js-eval "({})")))
                 (for-each (lambda (p) (js-set! h (car p) (cdr p))) (cdr kv))
                 (js-set! o "headers" h))
               (js-set! o (symbol->string (car kv)) (cdr kv))))
         (car more)))
      (js-await (js-call (js-get (js-global) "fetch") (js-undefined) url o))))

  (define (response-status r) (js->number (js-get r "status")))
  (define (response-ok? r) (js-truthy? (js-get r "ok")))
  (define (response-text r) (js->string (js-await (js-method r "text"))))
  (define (response-header r name)
    (let ((v (js-method (js-get r "headers") "get" name)))
      (if (js-eq? v (js-eval "null")) #f (js->string v))))

  (define (http-get url)
    (response-text (fetch url)))

  (define (http-post url body . ctype)
    (response-text
     (fetch url (list (cons 'method "POST")
                      (cons 'body body)
                      (cons 'headers
                            (list (cons "Content-Type"
                                        (if (pair? ctype)
                                            (car ctype)
                                            "text/plain")))))))))

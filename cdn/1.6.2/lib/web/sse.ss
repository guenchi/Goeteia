;; Server-sent events carrying s-expressions: the browser half.
;;
;; The server (Igropyr's sse-send-sexpr!) frames one datum per event;
;; EventSource rejoins multi-line data, so datums with embedded
;; newlines survive. One-way pushes: notifications, progress streams.
;;
;;   (define es (sse-connect! "/events"
;;                (lambda (datum) ...)          ; one datum per event
;;                (lambda () ...)))             ; optional: on error
;;   (sse-close! es)
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web sse)
  (export sse-connect! sse-close!)
  (import (rnrs) (web js) (web rpc))

  (define (sse-connect! url on-datum . more)
    (let ((es (js-new (js-get (js-global) "EventSource") url)))
      (js-set! es "onmessage"
               (lambda (ev)
                 (on-datum (rpc-parse (js->string (js-get ev "data"))))
                 (js-undefined)))
      (when (pair? more)
        (js-set! es "onerror"
                 (lambda (ev) ((car more)) (js-undefined))))
      es))

  (define (sse-close! es) (js-method es "close")))

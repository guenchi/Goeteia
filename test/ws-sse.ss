;; expect: #t
;; (web ws) and (web sse) against mock WebSocket / EventSource: each
;; message is one datum -- serialization out, parse in, multi-line SSE
;; data rejoined losslessly. Plus rpc-get over a mock fetch.
(import (rnrs) (web js) (web ws) (web sse) (web rpc) (web fetch))

(js-eval "globalThis.__sent = []; globalThis.WebSocket = function(url){ this.url = url; this.readyState = 1; globalThis.__ws = this; this.send = t => globalThis.__sent.push(t); this.close = () => { this.readyState = 3 } }; globalThis.EventSource = function(url){ this.url = url; globalThis.__es = this; this.close = () => { this.closed = true } }")

;;; WebSocket: send serializes, receive parses
(define got '())
(define opened #f)
(define w (ws-connect! "ws://x/ws"
            (lambda (d) (set! got (cons d got)))
            (lambda () (set! opened #t))))
(ws-send! w '(add 1 2 1/2))
(ws-send! w '(note "x\ny"))
;; fire the handlers from the JS side, as the browser would
(js-eval "globalThis.__ws.onopen({})")
(js-eval "globalThis.__ws.onmessage({data: '(sum 7/2)'})")
(js-eval "globalThis.__ws.onmessage({data: '(user (id . 42))'})")
(define ws-ok
  (and (string=? (js->string (js-index (js-get (js-global) "__sent") 0))
                 "(add 1 2 1/2)")
       (string=? (js->string (js-index (js-get (js-global) "__sent") 1))
                 "(note \"x\ny\")")     ; literal newline on the wire
       opened
       (ws-open? w)
       (equal? (reverse got) '((sum 7/2) (user (id . 42))))
       (begin (ws-close! w) (not (ws-open? w)))))

;;; SSE: EventSource rejoins multi-line data with \n; the datum with
;;; an embedded newline arrives intact
(define pushed '())
(define es (sse-connect! "/events" (lambda (d) (set! pushed (cons d pushed)))))
(js-eval "globalThis.__es.onmessage({data: '(tick 1)'})")
(js-eval "globalThis.__es.onmessage({data: '(note \"a\\nb\")'.replace('\\\\n','\\n')})")
(js-eval "globalThis.__es.onmessage({data: '(done (total . 2))'})")
(define sse-ok
  (and (equal? (reverse pushed)
               (list '(tick 1)
                     (list 'note (string #\a #\newline #\b))
                     '(done (total . 2))))
       (begin (sse-close! es)
              (js-truthy? (js-get (js-get (js-global) "__es") "closed")))))

;;; rpc-get: a REST resource served as application/sexpr
(js-eval "globalThis.fetch = (url, opts) => Promise.resolve({ text: () => Promise.resolve('(user (id . 42) (roles admin))') })")
(define rest-ok
  (if (fetch-direct?)
      (equal? (rpc-get "/users/42") '(user (id . 42) (roles admin)))
      #t))                              ; vacuous without JSPI

(display (and ws-ok sse-ok rest-ok))
(if #f #f)

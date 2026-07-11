;; expect: #t
;; (web rpc) against a mock fetch: the request body is the exact wire
;; text Igropyr's parser accepts, and the reply -- symbols, dotted
;; pairs, strings, an exact ratio -- parses back to native data. The
;; assertions run inside the promise callback; the host drains
;; microtasks after main.
(import (rnrs) (web js) (web rpc))

(js-eval "globalThis.__sent = null; globalThis.fetch = (url, opts) => { globalThis.__sent = url + '|' + opts.method + '|' + opts.body; return Promise.resolve({ text: () => Promise.resolve('(ok (user (id . 42) (name . \"ada\") (score . 1/3)))') }) }")

(rpc! "/rpc" '(get-user 42 "extra" #t)
  (lambda (reply)
    (let ((sent (js->string (js-get (js-global) "__sent"))))
      (display
       (and
        ;; exactly what went on the wire
        (string=? sent "/rpc|POST|(get-user 42 \"extra\" #t)")
        ;; the reply is native data again, ratio and all
        (equal? reply '(ok (user (id . 42) (name . "ada") (score . 1/3))))
        (let ((user (cadr reply)))
          (and (eq? (car user) 'user)
               (= (cdr (assq 'id (cdr user))) 42)
               (string=? (cdr (assq 'name (cdr user))) "ada")
               (= (cdr (assq 'score (cdr user))) 1/3)))))))
  (lambda (e) (display "#f-network")))

;; the program's value: keep the output to the callback's verdict
(if #f #f)

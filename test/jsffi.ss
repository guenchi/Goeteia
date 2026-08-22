;; expect: #t
(import (web js))
(define G (js-global))
;; the conditions a deliberately failing hook was handed.  Lives out
;; here because two clauses share it: the one that installs the hook
;; and the one that checks #f really replaced it.
(define seen '())
(and ;; property chains and method calls on real host objects
     (js-ref? G)
     (= (js->number (js-method (js-get G "Math") "floor" 3.7)) 3)
     (= (js->number (js-method (js-get G "Math") "max" 3 7 5)) 7)
     ;; string round trip
     (string=? (js->string (string->js "hello")) "hello")
     (string=? (js->string (js-method (string->js "abc") "toUpperCase")) "ABC")
     ;; numbers come back exact when integral
     (fixnum? (js->number (js-method (js-get G "Math") "floor" 3.7)))
     ;; constructors
     (let ((arr (js-new (js-get G "Array") 1 2 3)))
       (= (js->number (js-get arr "length")) 3))
     ;; identity and truthiness
     (js-eq? G G)
     (js-truthy? (string->js "x"))
     (not (js-truthy? (js-undefined)))
     ;; eval as an escape hatch
     (= (js->number (js-eval "6 * 7")) 42)
     ;; the crown jewel: a Scheme closure crossing into JS and being
     ;; called back with arguments
     (let* ((arr (js-eval "[1, 2, 3]"))
            (doubled (js-method arr "map"
                                (lambda (x . _)
                                  (number->js (* 2 (js->number x)))))))
       (and (= (js->number (js-index doubled 0)) 2)
            (= (js->number (js-index doubled 1)) 4)
            (= (js->number (js-index doubled 2)) 6)))
     ;; a raise inside a callback answers undefined -- it must not
     ;; tear down the host's event loop -- but it must NOT be silent:
     ;; the default channel reports who and message on the console.
     ;; (A per-frame error once ran unreported for a whole project.)
     (begin
       (js-eval "globalThis.__cberr = [];
                 globalThis.__cbconsole = console.error;
                 console.error = (...a) =>
                   globalThis.__cberr.push(a.join(' '))")
       (let ((r (js-method (js-eval "[1]") "map"
                           (lambda _ (error 'boom "dies here" 42)))))
         (js-eval "console.error = globalThis.__cbconsole")
         (and (js-truthy? (js-eval "__cberr.length === 1"))
              (js-truthy? (js-eval "__cberr[0].includes('boom')"))
              (js-truthy? (js-eval "__cberr[0].includes('dies here')"))
              ;; the callback itself answered undefined, not a crash
              (not (js-truthy? (js-index r 0))))))
     ;; the channel is replaceable: a custom hook receives the
     ;; condition itself; #f restores the default
     (let ((got #f))
       (js-callback-error! (lambda (e) (set! got e)))
       (js-method (js-eval "[1]") "map"
                  (lambda _ (error 'hooked "custom" 9)))
       (js-callback-error! #f)
       (and (error? got)
            (eq? (condition-who got) 'hooked)
            (string=? (condition-message got) "custom")))
     ;; a non-condition raise still reports and still answers
     (begin
       (js-eval "globalThis.__cberr = [];
                 globalThis.__cbconsole = console.error;
                 console.error = (...a) =>
                   globalThis.__cberr.push(a.join(' '))")
       (js-method (js-eval "[1]") "map" (lambda _ (raise 'plain)))
       (js-eval "console.error = globalThis.__cbconsole")
       (js-truthy? (js-eval "__cberr.length === 1")))
     ;; error does not police its msg argument; a condition carrying
     ;; a non-string message must not cost the report (a formatter
     ;; raise inside the hook would be swallowed silently)
     (begin
       (js-eval "globalThis.__cberr = [];
                 globalThis.__cbconsole = console.error;
                 console.error = (...a) =>
                   globalThis.__cberr.push(a.join(' '))")
       (js-method (js-eval "[1]") "map" (lambda _ (error 'oddball 123)))
       (js-eval "console.error = globalThis.__cbconsole")
       (and (js-truthy? (js-eval "__cberr.length === 1"))
            (js-truthy? (js-eval "__cberr[0].includes('oddball')"))))
     ;; ---- a hook that fails on its own account ------------------------
     ;; The reporting channel is caller-supplied, so it can raise.  $jscb
     ;; guards it separately from the callback it is reporting on -- the
     ;; inner guard has been there since the channel was added, and this
     ;; is coverage for it rather than a fix, so it is not red before
     ;; anything.  What it must hold: a hook failing does not take the
     ;; answer with it, does not take the host with it, and does not
     ;; quietly stop being the hook.
     (begin
       (js-callback-error! (lambda (e) (set! seen (cons e seen)) (raise 'hook-died)))
       (let ((r1 (js-method (js-eval "[1]") "map"
                            (lambda _ (error 'first "one" 1))))
             (r2 (js-method (js-eval "[1]") "map"
                            (lambda _ (error 'second "two" 2)))))
         ;; IDENTITY, not falsity: a callback answering 0, "" or false
         ;; would satisfy `(not (js-truthy? ...))` just as well, and the
         ;; contract is that it answers undefined.
         (and (js-eq? (js-index r1 0) (js-undefined))
              (js-eq? (js-index r2 0) (js-undefined))
              ;; BOTH calls reached the hook -- a hook that unhooked
              ;; itself after failing once would pass a single-call test
              (= 2 (length seen))
              ;; and each got its own condition, not the hook's raise
              (eq? 'second (condition-who (car seen)))
              (eq? 'first (condition-who (cadr seen)))
              (string=? "two" (condition-message (car seen)))
              (string=? "one" (condition-message (cadr seen)))
              ;; the HOST is still there: a later callback runs and its
              ;; value comes back.  "No crash" is not observable from
              ;; inside the thing that would have crashed, so it is
              ;; witnessed by a sentinel that has to survive the trip.
              (= 4242 (js->number
                       (js-index (js-method (js-eval "[1]") "map"
                                            (lambda _ 4242))
                                 0))))))
     ;; ...and #f really REPLACES the hook, rather than leaving it in
     ;; place, installing a no-op, or chaining the old one behind the
     ;; default.  The console assertion alone cannot tell the last of
     ;; those apart -- a composite reporter that ran the old hook and
     ;; then the default would print exactly the expected line -- so the
     ;; old hook's own record is checked for silence as well.
     (let ((before (length seen)))
       (js-callback-error! #f)
       (js-eval "globalThis.__cberr = [];
                 globalThis.__cbconsole = console.error;
                 console.error = (...a) =>
                   globalThis.__cberr.push(a.join(' '))")
       (js-method (js-eval "[1]") "map" (lambda _ (error 'after-restore "back" 7)))
       (js-eval "console.error = globalThis.__cbconsole")
       (and (js-truthy? (js-eval "__cberr.length === 1"))
            (js-truthy? (js-eval "__cberr[0].includes('after-restore')"))
            (js-truthy? (js-eval "__cberr[0].includes('back')"))
            ;; the replaced hook saw nothing of it
            (= before (length seen)))))

;; The arguments a host started this program with.
;;
;; A Goeteia program had exactly one channel in from its runner --
;; standard input, which `rt/run.mjs' fills from a file named on the
;; command line.  That makes "which variant is this run" and "what is
;; the input" the same stream, so a program that wants both has to
;; carve the settings out of its own data.  This is the second
;; channel, and it is the conventional one.
;;
;;   $ node rt/run.mjs prog.wasm input.txt -- --frames 34 out/
;;   (args-list)   -> ("--frames" "34" "out/")
;;
;; The host publishes the list at `__goeteia_argv'.  That is the same
;; way a host hands a worker its canvas (`__goeteia_canvas') and the
;; module its memory (`__goeteia_mem'): the bridge resolves the
;; `__goeteia_*' names per instance, so the channel needs no new wasm
;; import, no compiler change and no rebuild -- adding it was adding
;; this file and six lines of runner.
;;
;; HOST BODY.  A host that publishes nothing gives a program zero
;; arguments: `args-count' answers 0 and `args-list' answers (), on a
;; browser page as much as under a runner invoked without `--'.  It
;; is `args-ref' out of range that raises, and it raises by name.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web args)
  (export args-count args-ref args-list)
  (import (rnrs) (web js))

  (define $args-key "__goeteia_argv")

  ;; -> the JS array, or #f where the host published none.  Read
  ;; afresh every time: a host may publish late, and nothing here is
  ;; hot enough to want the cache's staleness.
  (define ($args)
    (let ((a (js-get (js-global) $args-key)))
      (and (js-truthy? a) a)))

  (define (args-count)
    (let ((a ($args)))
      (if a (js->number (js-get a "length")) 0)))

  ;; -> the i'th argument as a string.  Out of range is an error and
  ;; not a silent #f: an argument the caller believed was there and
  ;; is not should stop the run at the point of the mistake.
  (define (args-ref i)
    (let ((n (args-count)))
      (unless (and (integer? i) (>= i 0) (< i n))
        (error 'args-ref "no argument at that index" i n))
      (js->string (js-index ($args) i))))

  (define (args-list)
    (let loop ((i (- (args-count) 1)) (acc '()))
      (if (< i 0) acc (loop (- i 1) (cons (args-ref i) acc)))))
  )

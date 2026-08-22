;; The one announcer for "this check did not run here".
;;
;; ⚠ ANY new "not exercised in this file" MUST go through here.  The
;; gate's skip audit knows exactly one prefix, and it knows it because
;; there is exactly one place that writes it.  Add a sixth wording of
;; your own and the audit will not see it -- which is not hypothetical:
;; five call sites had grown four wordings between them, none of them
;; containing the word "skip", and both sessions' audits had been
;; grepping for "skip" and reporting a confident ZERO while the gate
;; printed thirty such lines every run.  A reading that is always 0 is
;; the one that looks most like it has already been checked, and it is
;; also the cheapest to report: it needs no explanation, no list, and
;; no room in the summary.
;;
;; Keep BOTH halves when you call it.  `why` is the reason this
;; runtime cannot do it; `what` is the check, and where the check
;; lives instead if it lives somewhere.  The "-- see test/foo" half is
;; why this tree's ten skips could be cleared in one pass: each said
;; where to look, so none of them needed an investigation.
;;
;; It writes to STDERR, deliberately.  run-tests.sh compares a suite's
;; STDOUT against its `;; expect:` line, so a notice printed on stdout
;; turns an opt-in skip into a failure -- measured: test/image-real.ss
;; used `display` here, and pointing one of its asset paths at a
;; missing file made the suite go red rather than skip.  Its paths are
;; absolute and local to one machine, so that was every other machine.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (notrun)
  (export not-exercised!)
  (import (rnrs) (web js))

  (define _chan (js-eval "globalThis.__notrun=(s)=>{console.error(s);}"))
  (define __notrun (js-get (js-global) "__notrun"))
  (define (say s) (js-call __notrun (js-undefined) (string->js s)))

  ;; (not-exercised! why what detail ...)
  ;;   "  NOT EXERCISED HERE (why): what"
  ;;   "    detail"  ...
  (define (not-exercised! why what . details)
    (say (string-append "  NOT EXERCISED HERE (" why "): " what))
    (for-each (lambda (d) (say (string-append "    " d))) details)))

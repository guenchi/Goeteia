;; A name defined twice at the top level makes dead-code elimination
;; drop what only the FIRST definition calls, while keeping both
;; definitions to compile.  Compiling this file fails, on both
;; targets, with
;;
;;   at test/probes/dce-shadowed-name.ss:22 (use)
;;   Exception in goeteia: cannot call: bye
;;
;; `bye' is reachable only from the first `use'.  prune-dead builds
;; one table entry per NAME, so the second definition is the one whose
;; references are followed, and `bye' is never marked live; the filter
;; that keeps forms then asks only whether the NAME is live, so the
;; first `use' is emitted anyway and its call has no callee left.
;;
;; The shape reaches real programs through libraries, which the driver
;; inlines into the same top level: a program that defines `root' next
;; to (web reactive)'s `root' pruned that library's dispose path out
;; from under it.  A program file is the smallest statement of it.
;; Copyright (c) 2026 guenchi.  MIT license; see LICENSE.
(import (rnrs))
(define (bye) (display 'gone) (newline))
(define (use) (bye))
(define use 1)
(display use) (newline)

#lang prospect

(require (only-in racket/port read-line-evt))
(require "../drivers/timer.rkt")

(define (quasi-spy e s)
  (printf "----------------------------------------\n")
  (printf "QUASI-SPY:\n")
  (match e
    [(? patch? p) (pretty-print-patch p)]
    [other
     (write other)
     (newline)])
  (printf "========================================\n")
  #f)
(spawn quasi-spy (void) (sub ?))

(define (r e s)
  (match e
    [(message body) (transition s (message (at-meta `(print (got ,body)))))]
    [_ #f]))

(define (b e n)
  (match e
    [#f (if (< n 10)
	    (transition (+ n 1) (message `(hello ,n)))
	    #f)]
    [_ #f]))

(spawn-network (spawn r (void) (sub ?))
               (spawn b 0 '()))

(define (echoer e s)
  (match e
    [(message (at-meta (external-event _ (list (? eof-object?)))))
     (quit)]
    [(message (at-meta (external-event _ (list line))))
     (transition s (message `(print (got-line ,line))))]
    [_ #f]))

(spawn echoer
       (void)
       (sub (external-event (read-line-evt (current-input-port) 'any) ?) #:meta-level 1))

(define (ticker e s)
  (match e
    [(? patch? p)
     (printf "TICKER PATCH RECEIVED:\n")
     (pretty-print-patch p)
     #f]
    [(message (timer-expired 'tick now))
     (printf "TICK ~v\n" now)
     (if (< s 3)
         (transition (+ s 1) (message (set-timer 'tick 1000 'relative)))
         (quit))]
    [_ #f]))

(spawn-timer-driver)
(message (set-timer 'tick 1000 'relative))
(spawn ticker
       1
       (patch-seq (sub (observe (set-timer ? ? ?)))
                  (sub (timer-expired 'tick ?))))

(define (printer e s)
  (match e
    [(message (list 'print v))
     (log-info "PRINTER: ~a" v)
     #f]
    [_ #f]))

(spawn printer
       (void)
       (sub `(print ,?)))

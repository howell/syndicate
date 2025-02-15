#lang racket/base
;; Monolithic Syndicate adapter.

(provide event?
         action?
         clean-transition

         assertion
         subscription

         assertion-set-union
         assertion-set-union*
         scn/union

         (struct-out monolithic-wrapper)
         wrap-monolithic-state
         wrap-monolithic-behaviour
         (rename-out [actor-monolithic actor])
         (rename-out [actor-monolithic/stateless actor/stateless]))

(require racket/match)
(require (only-in racket/list flatten))

(require (for-syntax racket/base))
(require (for-syntax syntax/parse))
(require (for-syntax syntax/srcloc))
(require "../syntax-classes.rkt")

(require "scn.rkt")
(require "../trie.rkt")
(require (except-in "../core.rkt"
                    event?
                    action?
                    clean-actions
                    clean-transition))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (event? x) (or (scn? x) (message? x)))
(define (action? x) (or (event? x) (actor? x) (quit-dataspace? x)))

(define (clean-transition t)
  (match t
    [#f #f]
    [(<quit> exn actions) (quit exn (clean-actions actions))]
    [(transition state actions) (transition state (clean-actions actions))]
    [(? void?) #f]))

(define (clean-actions actions)
  (filter action? (flatten actions)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (assertion pattern)
  (pattern->trie '<assertion> pattern))

(define (subscription pattern)
  (pattern->trie '<subscription> (observe pattern)))

(define (assertion-set-union . tries)
  (assertion-set-union* tries))

(define (assertion-set-union* tries)
  (match tries
    ['() trie-empty]
    [(cons t1 rest)
     (for/fold [(t1 t1)] [(t2 (in-list rest))]
       (trie-union t1 t2 #:combiner (lambda (a b) (trie-success '<assertion-set-union*>))))]))

(define (scn/union . tries)
  (scn (assertion-set-union* tries)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(struct monolithic-wrapper (state assertions-in assertions-out) #:prefab)

(define (wrap-monolithic-state underlying-state)
  (monolithic-wrapper underlying-state trie-empty trie-empty))

(define (integrate-incoming incremental-e wrapped-state)
  (match incremental-e
    [(? patch? p)
     (define new-assertions-in
       (update-interests (monolithic-wrapper-assertions-in wrapped-state) p))
     (values (struct-copy monolithic-wrapper wrapped-state
                          [assertions-in new-assertions-in])
             (scn new-assertions-in))]
    [(or (? message?) #f)
     (values wrapped-state incremental-e)]))

(define (differentiate-outgoing wrapped-state monolithic-actions)
  (let loop ((assertions-out (monolithic-wrapper-assertions-out wrapped-state))
             (actions-remaining monolithic-actions)
             (incremental-actions-rev '()))
    (match actions-remaining
      ['()
       (transition (struct-copy monolithic-wrapper wrapped-state
                                [assertions-out assertions-out])
                   (reverse incremental-actions-rev))]
      [(cons monolithic-action rest)
       (match monolithic-action
         [(scn new-interests)
          (loop new-interests
                rest
                (cons (compute-patch assertions-out new-interests) incremental-actions-rev))]
         [other
          (loop assertions-out
                rest
                (cons other incremental-actions-rev))])])))

(define (wrap-monolithic-behaviour underlying-behavior)
  (lambda (incremental-e wrapped-state0)
    (define-values (wrapped-state monolithic-e) (integrate-incoming incremental-e wrapped-state0))
    (match (clean-transition
            (underlying-behavior monolithic-e (monolithic-wrapper-state wrapped-state)))
      [#f (if (eq? wrapped-state wrapped-state0)
              #f
              (transition wrapped-state '()))]
      [(<quit> exn monolithic-actions)
       (match-define (transition _ignored-final-state incremental-actions)
         (differentiate-outgoing wrapped-state monolithic-actions))
       (<quit> exn incremental-actions)]
      [(transition new-underlying-state monolithic-actions)
       (differentiate-outgoing (struct-copy monolithic-wrapper wrapped-state
                                            [state new-underlying-state])
                               monolithic-actions)])))

(define-syntax (actor-monolithic stx)
  (syntax-parse stx
    [(_ name:name assertions:assertions behavior-exp initial-state-exp initial-action-tree-exp)
     #'(make-actor (lambda ()
                     (list (wrap-monolithic-behaviour behavior-exp)
                           (differentiate-outgoing (wrap-monolithic-state initial-state-exp)
                                                   (clean-actions initial-action-tree-exp))
                           name.N))
                   assertions.P)]))

(define-syntax (actor-monolithic/stateless stx)
  (syntax-parse stx
    [(_ name:name assertions:assertions behavior-exp initial-action-tree-exp)
     #'(actor-monolithic #:name name.N
                         #:assertions* assertions.P
                         (stateless-behavior-wrap behavior-exp)
                         (void)
                         initial-action-tree-exp)]))

(define ((stateless-behavior-wrap b) e state)
  (match (b e)
    [#f #f]
    [(? quit? q) q]
    [actions (transition state actions)]))

#lang prospect

(require prospect/actor)
(require prospect/drivers/tcp)
(require (only-in racket/string string-trim))

(struct tcp-remote-open (id) #:prefab)
(struct tcp-local-open (id) #:prefab)
(struct tcp-incoming-data (id bytes) #:prefab)
(struct tcp-outgoing-data (id bytes) #:prefab)

(struct says (who what) #:prefab)
(struct present (who) #:prefab)

(define (spawn-session id)
  (actor (define (send-to-remote fmt . vs)
           (send! (tcp-outgoing-data id (string->bytes/utf-8 (apply format fmt vs)))))

         (define (say who fmt . vs)
           (unless (equal? who user)
             (send-to-remote "~a ~a\n" who (apply format fmt vs))))

         (define user (gensym 'user))
         (send-to-remote "Welcome, ~a.\n" user)

         (until (retracted (tcp-remote-open id))
                (assert (tcp-local-open id))
                (assert (present user))

                (on (asserted (present $who)) (say who "arrived."))
                (on (retracted (present $who)) (say who "departed."))
                (on (message (says $who $what)) (say who "says: ~a" what))

                (on (message (tcp-incoming-data id $bs))
                    (send! (says user (string-trim (bytes->string/utf-8 bs))))))))

(spawn-tcp-driver)

(define us (tcp-listener 5999))
(actor (forever (assert (advertise (observe (tcp-channel _ us _))))
                (on (asserted (advertise (tcp-channel $them us _)))
                    (define id (seal (list them us)))
                    (actor (state [(assert (tcp-remote-open id))
                                   (on (message (tcp-channel them us $bs))
                                       (send! (tcp-incoming-data id bs)))
                                   (on (message (tcp-outgoing-data id $bs))
                                       (send! (tcp-channel us them bs)))]
                                  [(retracted (advertise (tcp-channel them us _))) (void)]
                                  [(retracted (tcp-local-open id)) (void)])))))

(forever (on (asserted (tcp-remote-open $id))
             (spawn-session id)))

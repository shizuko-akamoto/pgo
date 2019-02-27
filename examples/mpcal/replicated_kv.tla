----------------------------- MODULE replicated_kv -----------------------------
(***************************************************************************************)
(* Specifies a simple replicated Key-Value store in MPCal.                             *)
(*                                                                                     *)
(* Specifies a replicated state machines (RSM) approach as described in:               *)
(*                                                                                     *)
(* Implementing fault-tolerant services using the state machine approach: a tutorial.  *)
(* http://dl.acm.org/citation.cfm?id=98167                                             *)
(***************************************************************************************)

\* Use some built-in TLA+ modules
EXTENDS Integers, Sequences, FiniteSets, TLC

\* Constant Definitions
\* --------------------

\* Defines the size of the network buffer in a FIFOChannel (the mapping macro).
\*
\* TLC will explore states with up to `BUFFER_SIZE` messages being held on the buffer.
\* If the communication buffer is full, a process that attempts to send a message will not
\* run until a message on the other end of the channel is received.
CONSTANT BUFFER_SIZE

\* Defines the number of key-value store replicas and clients in the system. The specification
\* is orthogonal to these numbers. Note, however, that increasing the number of replicas and/or
\* clients exponentially increases the state space that TLC needs to explore in order to model
\* check your specification.
CONSTANTS NUM_REPLICAS, NUM_CLIENTS

\* When a client sends a message to a replica, the client needs to be able to identify
\* what type of message it just received. These constants below are such labels. Make sure
\* to give them distinct concrete values when model checking.
CONSTANTS DISCONNECT_MSG, GET_MSG, PUT_MSG, NULL_MSG

\* The payload of a message sent by the replica when a `PUT` request is successful.
CONSTANT OK_RESPONSE

\* an arbitrary `NULL` value. We model the underlying key-value store as a function from
\* a certain key-space (function domain) to this `NULL` element. When a client issues a `PUT`
\* request, the database is updated and the key being set no longer maps to `NULL`.
CONSTANT NULL

\* Defines which keys are used by clients when performing Get and Put operations
\* Since we are interested to test properties like message stability detection
\* and the semantics of the database, we keep these constant throughout model checking.
CONSTANT GET_KEY, PUT_KEY

\* Whenever clients issue PUT requests, they set keys to the value declared in this constant.
CONSTANT PUT_VALUE

\* Define NUM_NODES to be the total number of nodes in the system, i.e., the number of
\* clients plus the number of replicas
NUM_NODES == NUM_REPLICAS + NUM_CLIENTS

\* Each replica and each client in the system need an identifier. By default, replicas
\* are identified from 1 to NUM_REPLICAS, and the clients are identified from NUM_REPLICAS+1
\* to NUM_NODES. It is important that identifiers are unique, consecutive and non-overlapping,
\* due to the way we are modeling our network in this specification.
ReplicaSet == 1..NUM_REPLICAS
ClientSet == (NUM_REPLICAS+1)..NUM_NODES

\* Defines the set of keys a client may set. In this specification, we restrict
\* it to them to GET_KEY and PUT_KEY
KeySpace == { GET_KEY, PUT_KEY }

\* We have clients that perform each of the operations supported by our Replicated KV-store:
\* Get, Put, Disconnect, and ClockUpdate (or 'null' request). PlusCal requires that every process
\* has a unique identifier. The set definitions below just ensure that our clients have
\* consecutive identifiers.
GetSet == (NUM_REPLICAS+1)..(NUM_REPLICAS+NUM_CLIENTS)
PutSet == (NUM_REPLICAS+NUM_CLIENTS+1)..(NUM_REPLICAS + 2*NUM_CLIENTS)
DisconnectSet == (NUM_REPLICAS+1+2*NUM_CLIENTS)..(NUM_REPLICAS+3*NUM_CLIENTS)
NullSet == (NUM_REPLICAS+1+3*NUM_CLIENTS)..(NUM_REPLICAS+4*NUM_CLIENTS)

\* These constants allow PlusCal processes to derive their client identifiers from
\* their PlusCal identifiers.
GET_ORDER == 0
PUT_ORDER == 1
DISCONNECT_ORDER == 2
NULL_ORDER == 3

(***************************************************************************
--mpcal ReplicatedKV {

  \* Broadcasts a certain `msg` to `nodes` with identifiers ranging from
  \* `domainStart` to `domainEnd`.
  \*
  \* Only returns once every message has been sent (i.e., it may "block" if
  \* the buffer of one of the receivers is full).
  procedure Broadcast(ref nodes, domainStart, domainEnd, msg)
  variable i = domainStart; {
    loop:
      while (i <= domainEnd) {
          nodes[i] := msg;
          i := i + 1;
      };

    ret:
      return;
  }

  \* Models a FIFO channel. Messages are always delivered. Every process
  \* can have up to `BUFFER_SIZE` messages in its buffer before being
  \* processed.
  mapping macro FIFOChannel {
      read {
          await Len($variable) > 0;
          with (msg = Head($variable)) {
              $variable := Tail($variable);
              yield msg;
          };
      }

      write {
          await Len($variable) < BUFFER_SIZE;
          yield Append($variable, $value);
      }
  }

  \* This archetype defines the behavior of the replica servers in the system.
  \* Its parameters are:
  \*
  \* - clients: connections to all clients in the system; it needs to wait
  \*            for client requests in order to perform operations.
  \* - replicas: connections to replicas. Since replicas do not talk to each
  \*             other, this parameter is only used in order to listen to
  \*             incoming messages.
  \* - kv: the underlying "database". When 'put' requests become stable, this
  \*       database is updated to include the value being set by the client.
  archetype AReplica(ref clients, replicas, ref kv)

  \* Local state in a replica:
  variables
            \* Each replica knows which clients are live (i.e., haven't disconnected)
            \* Initially, all clients are live.
            liveClients = ClientSet,

            \* Replicas remember which requests are pending (i.e., have not been
            \* replied yet). This variable maps client identifiers to a sequence
            \* of pending requests
            pendingRequests = [c \in liveClients |-> <<>>],

            \* Temporary variables: holds messages that are stable
            stableMessages = <<>>,

            \* incremented during in loops
            i,

            \* temporary variable: holds the first pending message from
            \* a client. The first pending message has the lowest logical
            \* clock in the sequence (logical clocks are monotonically increasing)
            firstPending,

            \* temporary variables used while finding the set of stable
            \* messages.
            timestamp,
            nextClient,
            lowestPending,
            chooseMessage,

            \* the replica needs to know the logical clocks of the last
            \* message received by each client in order to determine
            \* request stability.
            currentClocks = [c \in liveClients |-> 0];

            \* determines the lowest logical clock value seen from all
            \* clients. Any pending messages with timestamp lower than this
            \* can be considered stable.
            minClock,

            \* controls while loop execution. See the 'findStableRequestsLoop'
            \* step for more information
            continue,

            \* temporary variable: live clients that have pending
            \* messages (stable or not)
            pendingClients,

            \* Used when iterating over sets of clients
            clientsIter,

            \* used to hold messages sent/received by the replica
            msg,

            \* holds keys/values to be read from/written to the database
            key,
            val,

            \* a reference to the database associated with this instance
            \* of the replica
            mydb,

            \* used to hold the requester identifier when the replica
            \* receives a message
            requester,

            \* whether to continue in the replica main loop
            mainLoop = TRUE; {

    \* Main replica loop. In each iteration of the loop, the replica:
    \*
    \*     1. Waits for incoming messages from clients;
    \*     2. Finds stable messages;
    \*     3. Replies to all stable messages.
    replicaLoop:
      while (mainLoop) {

          \* Database reference used throughout the replica is the one associated with
          \* the current replica
          mydb := kv[self];
          stableMessages := <<>>;
          continue := TRUE;

          \* Waits for an incoming message from any client. This statement will
          \* "block" the replica until a message is read into 'msg'.
          \* See definition of client archetypes for the format of the messages.
          receiveClientRequest:
            msg := replicas[self];

          \* if the message received is a disconnection from a client,
          \* remove the client from the set of live clients
          clientDisconnected:
            if (msg[1] = DISCONNECT_MSG) {
                liveClients := liveClients \ {msg[2]};
            };

          \* if the message is a Get request:
          replicaGetRequest:
            if (msg[1] = GET_MSG) {
                requester := msg[3];

                \* safety assertion: a client requesting for a key must be live
                assert(requester \in liveClients);

                \* update our records of the current logical clock of the
                \* requesting client.
                currentClocks[requester] := msg[4];

                \* make this a pending message (to be dealt with later, during
                \* stability check)
                pendingRequests[requester] := Append(pendingRequests[requester], msg);
            };

          \* if the message is a Put request: similar to Get request.
          replicaPutRequest:
            if (msg[1] = PUT_MSG) {
                requester := msg[4];

                currentClocks[requester] := msg[5];
                pendingRequests[requester] := Append(pendingRequests[requester], msg);
            };

          \* if the message is a clock update from a client, inspect the logical clock
          \* to check if it's lower than that of any other message seen before.
          replicaNullRequest:
            if (msg[1] = NULL_MSG) {
                requester := msg[2];
                currentClocks[requester] := msg[3];
            };

          \* Message stability
          \* -----------------
          \*
          \* The replica needs to detect when messages become stable, and then respond to
          \* those messages. Finding out which messages are stable and totally ordering them
          \* is crucial for the correctness of the algorithm. If message stability does not work
          \* correctly in the replicas, the database may get inconsistent across replicas
          \* (if operations are applied in a different order), or clients may get "stuck"
          \* (if stable messages are not replied).


          \* This is the main loop that finds which of the pending requests (if any) are stable
          findStableRequestsLoop:
            while (continue) {

                \* only consider clients that have messages pending
                pendingClients := {c \in liveClients : Len(pendingRequests[c]) > 0};

                \* if two messages have the same logical clock, total ordering is enforced
                \* based on the client identifier: requests from smaller client identifiers
                \* are applied first
                nextClient := NUM_NODES + 1;

                clientsIter := liveClients;
                i := 0;
                minClock := 0;

                \* in order to find the set of stable messages, we need to determine
                \* the lowest logical clock among our set of live clients. Then, every
                \* pending message with a timestamp greater than 'minClock' can be
                \* considered stable.
                findMinClock:
                  while (i < Cardinality(clientsIter)) {
                      with (client \in clientsIter) {
                          if (minClock = 0 \/ currentClocks[client] < minClock) {
                              minClock := currentClocks[client];
                          };

                          clientsIter := clientsIter \ {client};
                      }
                  };

                \* this variable holds the timestamp of the request with the lowest clock
                \* value that is pending and stable
                lowestPending := minClock + 1;

                i := 0;

                \* find the next stable message to be processed
                findMinClient:
                  while (i < Cardinality(pendingClients)) {
                      with (client \in pendingClients) {

                          \* for each client with pending requests:
                          \* - inspect the first pending message (by definition, the message with
                          \*   lowest clock from that client)
                          \* - extract the timestamp from the message
                          \* - record the client and timestamp in case this is the "oldest" message

                          firstPending := Head(pendingRequests[client]);
                          assert(firstPending[1] = GET_MSG \/ firstPending[1] = PUT_MSG);

                          if (firstPending[1] = GET_MSG) {
                              timestamp := firstPending[4];
                          } else {
                              timestamp := firstPending[5];
                          };

                          \* a message is only stable if its timestamp is lower than
                          \* minClock
                          if (timestamp < minClock) {

                              \* this is the next stable message if it has the lowest
                              \* timestamp seen so far; if the timestamp is the same as
                              \* the lowest seen so far, do a client-id comparison
                              chooseMessage := (timestamp < lowestPending) \/ ((timestamp = lowestPending) /\ (client < nextClient));
                              if (chooseMessage) {
                                  nextClient := client;
                                  lowestPending := timestamp;
                              }
                          };

                          pendingClients := pendingClients \ {client};
                      }
                  };

                \* add the next stable message to the 'stableMessages' sequence.
                \* if 'lowestPending' is >= 'minClock', it means no more stable messages
                \* are pending, and we can leave this loop.
                addStableMessage:
                  if (lowestPending < minClock) {
                      msg := Head(pendingRequests[nextClient]);
                      pendingRequests[nextClient] := Tail(pendingRequests[nextClient]);

                      stableMessages := Append(stableMessages, msg);
                  } else {
                      continue := FALSE;
                  }
            };

          i := 1;

          \* iterate over our sequence of 'stableMessages' built in the previous
          \* step, responding to each of them in order.
          respondPendingRequestsLoop:
            while (i <= Len(stableMessages)) {
                msg := stableMessages[i];
                i := i + 1;

                respondStableGet:
                  if (msg[1] = GET_MSG) {
                      key := msg[2];
                      val := mydb[key];

                      \* send the value read from the database back to the client
                      clients[msg[3]] := val;
                  };

                respondStablePut:
                  if (msg[1] = PUT_MSG) {
                      key := msg[2];
                      val := msg[3];

                      \* update our database and send an OK back to the client
                      mydb[key] := val;
                      kv[self] := mydb;

                      clients[msg[4]] := OK_RESPONSE;
                  };
            }
      }
  }


  \* Client Definitions
  \* ------------------
  \*
  \* The following archetypes define the client functions as specified in A1.
  \* Note that these operations are the "logical" versions of the API: for example,
  \* a Put archetype here sends a "Put" message to all replicas.
  \*
  \* In all of the definitions below, note that 'clocks' represent the client's
  \* logical clock. However, upon disconnection, the clock is set to '-1', and
  \* clients know to terminate when that happens.


  \* Specifies a Get request from a client. Arguments:
  \*
  \* - replicas: connections to replica servers
  \* - clients: connections to clients. Used only to listen for incoming messages
  \*            from replicas (i.e., to send the value of the key being read).
  \* - key: the key being read. This *must* belong to the KeySpace set.
  \* - locked: whether or not an RPC call is allowed. Clients do not send
  \*           concurrent requests. This stops a Get request from being sent
  \*           while a Put request is underway.
  \* clocks: clients logical clocks. The instance's logical clock is incremented
  \*         when a request is sent to the replica.
  \*
  \* A Get message sent to the replica is a tuple in the following format:
  \*
  \*     << GET_MSG, key, client_id, lamport_clock >>
  archetype Get(ref replicas, clients, key, locked, ref clocks)
  variable continue = TRUE, i = 0, getReq, getResp, clientId;
  {
      \* Loop until disconnected
      getLoop:
        while (continue) {
            getRequest:
              clientId := self - (NUM_CLIENTS * GET_ORDER);

              \* only perform a get request if not locked (i.e., Put request underway)
              await ~locked[clientId];

              \* if disconnected, return
              if (clocks[clientId] = -1) {
                  continue := FALSE
              } else {

                  \* increment the logical clock, and construct a valid
                  \* Get message.
                  clocks[clientId] := clocks[clientId] + 1;
                  getReq := << GET_MSG, key, clientId, clocks[clientId] >>;

                  \* Choose some replica from the set of replicas to send this
                  \* request to
                  with (dst \in ReplicaSet) {
                      replicas[dst] := getReq;
                  };

                  \* Waits for the response from the replica
                  getResp := clients[clientId];
                  assert(getResp = NULL \/ getResp = PUT_VALUE);
              }
        }
  }

  \* Specifies a Put request from a client. Arguments:
  \*
  \* - replicas: connection to the replicas.
  \* - clients: connection to the clients. Used to read incoming messages (response
  \*            from the Put request
  \* - key: the key being set.
  \* - value: the value being written to the key
  \* - locked: set when the Put request is sent to the replica to indicate that
  \*           other calls should wait for its completion
  \* - clocks: Lamport clocks
  \*
  \* A Put message sent to the replica is a tuple in the following format:
  \*
  \*     << PUT_MSG, key, value, client_id, lamport_clock >>
  archetype Put(ref replicas, clients, key, value, ref locked, ref clocks)
  variables continue = TRUE, i, putReq, putResp, clientId;
  {
      \* Loops indefinitely until disconnected
      putLoop:
        while (continue) {
            clientId := self - (NUM_CLIENTS * PUT_ORDER);

            putRequest:
              \* if disconnected, return
              if (clocks[clientId] = -1) {
                  continue := FALSE;
              } else {

                  \* increment the logical clock, construct the payload to be sent
                  \* to the replica, and set 'locked' to TRUE
                  clocks[clientId] := clocks[clientId] + 1;
                  putReq := << PUT_MSG, key, value, clientId, clocks[clientId] >>;
                  locked[clientId] := TRUE;
                  i := 0;

                  \* Put requests must be broadcast to all replicas
                  call Broadcast(ref replicas, 1, NUM_REPLICAS, putReq);

                  \* wait for a response from all replicas, and allow other
                  \* calls to the replica to happen after that.
                  putResponse:
                    while (i < Cardinality(ReplicaSet)) {
                        putResp := clients[clientId];
                        assert(putResp = OK_RESPONSE);

                        i := i + 1;
                    };

                    locked[clientId] := FALSE;

                  putComplete:
                    skip;
              }
        }
  }

  \* Specifies a Disconnect message from the client.
  \* Does not disconnect if 'locked' (i.e., a Put request is underway).
  \*
  \* A Disconnect message sent to the replica is a tuple in the following format:
  \*
  \*     << DISCONNECT_MSG, client_id >>
  archetype Disconnect(ref replicas, locked, ref clocks)
  variables msg, clientId;
  {
      sendDisconnectRequest:
        clientId := self - (NUM_CLIENTS * DISCONNECT_ORDER);
        await ~locked[clientId];

        msg := << DISCONNECT_MSG, clientId >>;

        \* setting the logical clock internally to -1 indicates that this client
        \* has disconnected. Other operations terminate when accordingly.
        clocks[clientId] := -1;

        \* Disconnection messages need to be broadcast to all replicas.
        call Broadcast(ref replicas, 1, NUM_REPLICAS, msg);
  }

  \* Specifies a ClockUpdate ('null') message from the client.
  \* If the client has disconnected, no more clock updates are sent.
  \*
  \* A ClockUpdate message sent to the replica is a tuple in the following format:
  \*
  \*     << NULL_MSG, client_id, logical_clock >>
  archetype ClockUpdate(ref replicas, ref clocks)
  variables continue = TRUE, i = 0, msg, clientId;
  {
      clockUpdateLoop:
        while (continue) {
            clientId := self - (NUM_CLIENTS * NULL_ORDER);

            \* if we have disconnected, return
            if (clocks[clientId] = -1) {
                continue := FALSE;
            } else {
                \* tick the lock and construct the message accordingly
                clocks[clientId] := clocks[clientId] + 1;
                msg := << NULL_MSG, clientId, clocks[clientId] >>;

                \* clock update messages must be broadcast to all replicas.
                call Broadcast(ref replicas, 1, NUM_REPLICAS, msg);
            }
        }
  }

  \* Global Variables
  \* ----------------

  variables
            \* queue of incoming messages for each of the replicas
            replicasNetwork = [id \in ReplicaSet |-> <<>>],

            \* queue of incoming messages for each of the clients
            clientsNetwork = [id \in ClientSet |-> <<>>],

            \* the key-value database. Initially, all keys are blank
            \* (i.e., set to `NULL`). Each replica has a separate
            \* database.
            db = [id \in ReplicaSet |-> [k \in KeySpace |-> NULL]],

            \* Logical clocks for each client. They are initially set
            \* to zero and are incremented on every event.
            logicalClocks = [id \in ClientSet |-> 0],

            \* whether a Put request is underway (i.e., no RPC concurrency from
            \* the client). Set initially to false -- any request can be the
            \* first.
            busy = [id \in ClientSet |-> FALSE];


  \* Process Instantiations
  \* ----------------------
  \*
  \* This is where the archetypes defined above are instantiated into actual PlusCal
  \* processes. We instantiate NUM_REPLICAS replica servers and NUM_CLIENTS client
  \* processes for each possible client operation. TLC will be responsible for
  \* exploring the different orderings in which these clients and replicas
  \* may interact.


  \* Instantiate replica servers. The network model used is the one defined in
  \* the FIFOChannel mapping macro.
  fair process (Replica \in ReplicaSet) == instance AReplica(ref clientsNetwork, replicasNetwork, ref db)
      mapping clientsNetwork[_] via FIFOChannel
      mapping replicasNetwork[_] via FIFOChannel;

  \* Instantiate clients:

  fair process (GetClient \in GetSet) == instance Get(ref replicasNetwork, clientsNetwork, GET_KEY, busy, ref logicalClocks)
      mapping replicasNetwork[_] via FIFOChannel
      mapping clientsNetwork[_] via FIFOChannel;

  fair process (PutClient \in PutSet) == instance Put(ref replicasNetwork, clientsNetwork, PUT_KEY, PUT_VALUE, ref busy, ref logicalClocks)
      mapping replicasNetwork[_] via FIFOChannel
      mapping clientsNetwork[_] via FIFOChannel;

  fair process (DisconnectClient \in DisconnectSet) == instance Disconnect(ref replicasNetwork, busy, ref logicalClocks)
      mapping replicasNetwork[_] via FIFOChannel;

  fair process (ClockUpdateClient \in NullSet) == instance ClockUpdate(ref replicasNetwork, ref logicalClocks)
      mapping replicasNetwork[_] via FIFOChannel;
}

\* BEGIN PLUSCAL TRANSLATION
--algorithm ReplicatedKV {
    variables replicasNetwork = [id \in ReplicaSet |-> <<>>], clientsNetwork = [id \in ClientSet |-> <<>>], db = [id \in ReplicaSet |-> [k \in KeySpace |-> NULL]], logicalClocks = [id \in ClientSet |-> 0], busy = [id \in ClientSet |-> FALSE];
    procedure Broadcast0 (domainStart, domainEnd, msg)
    variables i = domainStart, nodesWrite, nodesWrite0;
    {
        loop:
            if ((i)<=(domainEnd)) {
                await (Len(replicasNetwork[i]))<(BUFFER_SIZE);
                nodesWrite := [replicasNetwork EXCEPT ![i] = Append(replicasNetwork[i], msg)];
                i := (i)+(1);
                nodesWrite0 := nodesWrite;
                replicasNetwork := nodesWrite0;
                goto loop;
            } else {
                nodesWrite0 := replicasNetwork;
                replicasNetwork := nodesWrite0;
            };
        ret:
            return;

    }
    fair process (Replica \in ReplicaSet)
    variables liveClients = ClientSet, pendingRequests = [c \in liveClients |-> <<>>], stableMessages = <<>>, i, firstPending, timestamp, nextClient, lowestPending, chooseMessage, currentClocks = [c \in liveClients |-> 0], minClock, continue, pendingClients, clientsIter, msg, key, val, mydb, requester, mainLoop = TRUE, kvRead, replicasRead, replicasWrite, clientsWrite, clientsWrite0, kvWrite, kvWrite0, clientsWrite1;
    {
        replicaLoop:
            if (mainLoop) {
                kvRead := db;
                mydb := kvRead[self];
                stableMessages := <<>>;
                continue := TRUE;
                receiveClientRequest:
                    await (Len(replicasNetwork[self]))>(0);
                    with (msg0 = Head(replicasNetwork[self])) {
                        replicasWrite := [replicasNetwork EXCEPT ![self] = Tail(replicasNetwork[self])];
                        replicasRead := msg0;
                    };
                    msg := replicasRead;
                    replicasNetwork := replicasWrite;

                clientDisconnected:
                    if ((msg[1])=(DISCONNECT_MSG)) {
                        liveClients := (liveClients)\({msg[2]});
                    };

                replicaGetRequest:
                    if ((msg[1])=(GET_MSG)) {
                        requester := msg[3];
                        assert (requester)\in(liveClients);
                        currentClocks[requester] := msg[4];
                        pendingRequests[requester] := Append(pendingRequests[requester], msg);
                    };

                replicaPutRequest:
                    if ((msg[1])=(PUT_MSG)) {
                        requester := msg[4];
                        currentClocks[requester] := msg[5];
                        pendingRequests[requester] := Append(pendingRequests[requester], msg);
                    };

                replicaNullRequest:
                    if ((msg[1])=(NULL_MSG)) {
                        requester := msg[2];
                        currentClocks[requester] := msg[3];
                    };

                findStableRequestsLoop:
                    if (continue) {
                        pendingClients := {c \in liveClients : (Len(pendingRequests[c]))>(0)};
                        nextClient := (NUM_NODES)+(1);
                        clientsIter := liveClients;
                        i := 0;
                        minClock := 0;
                        findMinClock:
                            if ((i)<(Cardinality(clientsIter))) {
                                with (client \in clientsIter) {
                                    if (((minClock)=(0))\/((currentClocks[client])<(minClock))) {
                                        minClock := currentClocks[client];
                                    };
                                    clientsIter := (clientsIter)\({client});
                                };
                                goto findMinClock;
                            } else {
                                lowestPending := (minClock)+(1);
                                i := 0;
                            };

                        findMinClient:
                            if ((i)<(Cardinality(pendingClients))) {
                                with (client \in pendingClients) {
                                    firstPending := Head(pendingRequests[client]);
                                    assert ((firstPending[1])=(GET_MSG))\/((firstPending[1])=(PUT_MSG));
                                    if ((firstPending[1])=(GET_MSG)) {
                                        timestamp := firstPending[4];
                                    } else {
                                        timestamp := firstPending[5];
                                    };
                                    if ((timestamp)<(minClock)) {
                                        chooseMessage := ((timestamp)<(lowestPending))\/(((timestamp)=(lowestPending))/\((client)<(nextClient)));
                                        if (chooseMessage) {
                                            nextClient := client;
                                            lowestPending := timestamp;
                                        };
                                    };
                                    pendingClients := (pendingClients)\({client});
                                };
                                goto findMinClient;
                            };

                        addStableMessage:
                            if ((lowestPending)<(minClock)) {
                                msg := Head(pendingRequests[nextClient]);
                                pendingRequests[nextClient] := Tail(pendingRequests[nextClient]);
                                stableMessages := Append(stableMessages, msg);
                                goto findStableRequestsLoop;
                            } else {
                                continue := FALSE;
                                goto findStableRequestsLoop;
                            };

                    } else {
                        i := 1;
                    };

                respondPendingRequestsLoop:
                    if ((i)<=(Len(stableMessages))) {
                        msg := stableMessages[i];
                        i := (i)+(1);
                        respondStableGet:
                            if ((msg[1])=(GET_MSG)) {
                                key := msg[2];
                                val := mydb[key];
                                await (Len(clientsNetwork[msg[3]]))<(BUFFER_SIZE);
                                clientsWrite := [clientsNetwork EXCEPT ![msg[3]] = Append(clientsNetwork[msg[3]], val)];
                                clientsWrite0 := clientsWrite;
                                clientsNetwork := clientsWrite0;
                            } else {
                                clientsWrite0 := clientsNetwork;
                                clientsNetwork := clientsWrite0;
                            };

                        respondStablePut:
                            if ((msg[1])=(PUT_MSG)) {
                                key := msg[2];
                                val := msg[3];
                                mydb[key] := val;
                                kvWrite := [db EXCEPT ![self] = mydb];
                                await (Len(clientsNetwork[msg[4]]))<(BUFFER_SIZE);
                                clientsWrite := [clientsNetwork EXCEPT ![msg[4]] = Append(clientsNetwork[msg[4]], OK_RESPONSE)];
                                kvWrite0 := kvWrite;
                                clientsWrite1 := clientsWrite;
                                clientsNetwork := clientsWrite1;
                                db := kvWrite0;
                                goto respondPendingRequestsLoop;
                            } else {
                                kvWrite0 := db;
                                clientsWrite1 := clientsNetwork;
                                clientsNetwork := clientsWrite1;
                                db := kvWrite0;
                                goto respondPendingRequestsLoop;
                            };

                    } else {
                        goto replicaLoop;
                    };

            };

    }
    fair process (GetClient \in GetSet)
    variables continue = TRUE, i = 0, getReq, getResp, clientId, lockedRead, clocksRead, clocksRead0, clocksWrite, keyRead, clocksRead1, replicasWrite0, clientsRead, clientsWrite2, clocksWrite0, replicasWrite1, clientsWrite3;
    {
        getLoop:
            if (continue) {
                getRequest:
                    clientId := (self)-((NUM_CLIENTS)*(GET_ORDER));
                    lockedRead := busy;
                    await ~(lockedRead[clientId]);
                    clocksRead := logicalClocks;
                    if ((clocksRead[clientId])=(-(1))) {
                        continue := FALSE;
                        clocksWrite0 := logicalClocks;
                        replicasWrite1 := replicasNetwork;
                        clientsWrite3 := clientsNetwork;
                        replicasNetwork := replicasWrite1;
                        clientsNetwork := clientsWrite3;
                        logicalClocks := clocksWrite0;
                        goto getLoop;
                    } else {
                        clocksRead0 := logicalClocks;
                        clocksWrite := [logicalClocks EXCEPT ![clientId] = (clocksRead0[clientId])+(1)];
                        keyRead := GET_KEY;
                        clocksRead1 := clocksWrite;
                        getReq := <<GET_MSG, keyRead, clientId, clocksRead1[clientId]>>;
                        with (dst \in ReplicaSet) {
                            await (Len(replicasNetwork[dst]))<(BUFFER_SIZE);
                            replicasWrite0 := [replicasNetwork EXCEPT ![dst] = Append(replicasNetwork[dst], getReq)];
                        };
                        await (Len(clientsNetwork[clientId]))>(0);
                        with (msg1 = Head(clientsNetwork[clientId])) {
                            clientsWrite2 := [clientsNetwork EXCEPT ![clientId] = Tail(clientsNetwork[clientId])];
                            clientsRead := msg1;
                        };
                        getResp := clientsRead;
                        assert ((getResp)=(NULL))\/((getResp)=(PUT_VALUE));
                        clocksWrite0 := clocksWrite;
                        replicasWrite1 := replicasWrite0;
                        clientsWrite3 := clientsWrite2;
                        replicasNetwork := replicasWrite1;
                        clientsNetwork := clientsWrite3;
                        logicalClocks := clocksWrite0;
                        goto getLoop;
                    };

            };

    }
    fair process (PutClient \in PutSet)
    variables continue = TRUE, i, putReq, putResp, clientId, clocksRead2, clocksRead3, clocksWrite1, keyRead0, valueRead, clocksRead4, lockedWrite, clientsRead0, clientsWrite4, clientsWrite5, lockedWrite0;
    {
        putLoop:
            if (continue) {
                clientId := (self)-((NUM_CLIENTS)*(PUT_ORDER));
                putRequest:
                    clocksRead2 := logicalClocks;
                    if ((clocksRead2[clientId])=(-(1))) {
                        continue := FALSE;
                        goto putLoop;
                    } else {
                        clocksRead3 := logicalClocks;
                        clocksWrite1 := [logicalClocks EXCEPT ![clientId] = (clocksRead3[clientId])+(1)];
                        keyRead0 := PUT_KEY;
                        valueRead := PUT_VALUE;
                        clocksRead4 := clocksWrite1;
                        putReq := <<PUT_MSG, keyRead0, valueRead, clientId, clocksRead4[clientId]>>;
                        lockedWrite := [busy EXCEPT ![clientId] = TRUE];
                        i := 0;
                        busy := lockedWrite;
                        logicalClocks := clocksWrite1;
                        call Broadcast0(1, NUM_REPLICAS, putReq);
                        putResponse:
                            if ((i)<(Cardinality(ReplicaSet))) {
                                await (Len(clientsNetwork[clientId]))>(0);
                                with (msg2 = Head(clientsNetwork[clientId])) {
                                    clientsWrite4 := [clientsNetwork EXCEPT ![clientId] = Tail(clientsNetwork[clientId])];
                                    clientsRead0 := msg2;
                                };
                                putResp := clientsRead0;
                                assert (putResp)=(OK_RESPONSE);
                                i := (i)+(1);
                                clientsWrite5 := clientsWrite4;
                                lockedWrite0 := busy;
                                clientsNetwork := clientsWrite5;
                                busy := lockedWrite0;
                                goto putResponse;
                            } else {
                                lockedWrite := [busy EXCEPT ![clientId] = FALSE];
                                clientsWrite5 := clientsNetwork;
                                lockedWrite0 := lockedWrite;
                                clientsNetwork := clientsWrite5;
                                busy := lockedWrite0;
                            };

                        putComplete:
                            goto putLoop;

                    };

            };

    }
    fair process (DisconnectClient \in DisconnectSet)
    variables msg, clientId, lockedRead0, clocksWrite2;
    {
        sendDisconnectRequest:
            clientId := (self)-((NUM_CLIENTS)*(DISCONNECT_ORDER));
            lockedRead0 := busy;
            await ~(lockedRead0[clientId]);
            msg := <<DISCONNECT_MSG, clientId>>;
            clocksWrite2 := [logicalClocks EXCEPT ![clientId] = -(1)];
            logicalClocks := clocksWrite2;
            call Broadcast0(1, NUM_REPLICAS, msg);

    }
    fair process (ClockUpdateClient \in NullSet)
    variables continue = TRUE, i = 0, msg, clientId, clocksRead5, clocksRead6, clocksWrite3, clocksRead7, clocksWrite4;
    {
        clockUpdateLoop:
            if (continue) {
                clientId := (self)-((NUM_CLIENTS)*(NULL_ORDER));
                clocksRead5 := logicalClocks;
                if ((clocksRead5[clientId])=(-(1))) {
                    continue := FALSE;
                    clocksWrite4 := logicalClocks;
                    logicalClocks := clocksWrite4;
                    goto clockUpdateLoop;
                } else {
                    clocksRead6 := logicalClocks;
                    clocksWrite3 := [logicalClocks EXCEPT ![clientId] = (clocksRead6[clientId])+(1)];
                    clocksRead7 := clocksWrite3;
                    msg := <<NULL_MSG, clientId, clocksRead7[clientId]>>;
                    logicalClocks := clocksWrite3;
                    call Broadcast0(1, NUM_REPLICAS, msg);
                    goto clockUpdateLoop;
                };
            } else {
                logicalClocks := clocksWrite4;
            };

    }
}
\* END PLUSCAL TRANSLATION


***************************************************************************)
\* BEGIN TRANSLATION
\* Process variable i of process Replica at line 645 col 111 changed to i_
\* Process variable continue of process Replica at line 645 col 234 changed to continue_
\* Process variable msg of process Replica at line 645 col 273 changed to msg_
\* Process variable continue of process GetClient at line 792 col 35 changed to continue_G
\* Process variable i of process GetClient at line 792 col 52 changed to i_G
\* Process variable clientId of process GetClient at line 792 col 76 changed to clientId_
\* Process variable continue of process PutClient at line 839 col 36 changed to continue_P
\* Process variable i of process PutClient at line 839 col 53 changed to i_P
\* Process variable clientId of process PutClient at line 839 col 73 changed to clientId_P
\* Process variable msg of process DisconnectClient at line 892 col 15 changed to msg_D
\* Process variable clientId of process DisconnectClient at line 892 col 20 changed to clientId_D
\* Process variable i of process ClockUpdateClient at line 905 col 32 changed to i_C
\* Process variable msg of process ClockUpdateClient at line 905 col 39 changed to msg_C
CONSTANT defaultInitValue
VARIABLES replicasNetwork, clientsNetwork, db, logicalClocks, x, busy, pc,
          stack, domainStart, domainEnd, msg, i, nodesWrite, nodesWrite0,
          liveClients, pendingRequests, stableMessages, i_, firstPending,
          timestamp, nextClient, lowestPending, chooseMessage, currentClocks,
          minClock, continue_, pendingClients, clientsIter, msg_, key, val,
          mydb, requester, mainLoop, kvRead, replicasRead, replicasWrite,
          clientsWrite, clientsWrite0, kvWrite, kvWrite0, clientsWrite1,
          keyRead, continue_G, i_G, getReq, getResp, clientId_, lockedRead,
          clocksRead, clocksRead0, clocksWrite, clocksRead1, replicasWrite0,
          clientsRead, clientsWrite2, clocksWrite0, replicasWrite1,
          clientsWrite3, keyRead0, continue_P, i_P, putReq, putResp,
          clientId_P, clocksRead2, clocksRead3, clocksWrite1, valueRead,
          clocksRead4, lockedWrite, clientsRead0, clientsWrite4,
          clientsWrite5, lockedWrite0, msg_D, clientId_D, lockedRead0,
          clocksWrite2, continue, i_C, msg_C, clientId, clocksRead5,
          clocksRead6, clocksWrite3, clocksRead7, clocksWrite4

vars == << replicasNetwork, clientsNetwork, db, logicalClocks, x, busy, pc,
           stack, domainStart, domainEnd, msg, i, nodesWrite, nodesWrite0,
           liveClients, pendingRequests, stableMessages, i_, firstPending,
           timestamp, nextClient, lowestPending, chooseMessage, currentClocks,
           minClock, continue_, pendingClients, clientsIter, msg_, key, val,
           mydb, requester, mainLoop, kvRead, replicasRead, replicasWrite,
           clientsWrite, clientsWrite0, kvWrite, kvWrite0, clientsWrite1,
           keyRead, continue_G, i_G, getReq, getResp, clientId_, lockedRead,
           clocksRead, clocksRead0, clocksWrite, clocksRead1, replicasWrite0,
           clientsRead, clientsWrite2, clocksWrite0, replicasWrite1,
           clientsWrite3, keyRead0, continue_P, i_P, putReq, putResp,
           clientId_P, clocksRead2, clocksRead3, clocksWrite1, valueRead,
           clocksRead4, lockedWrite, clientsRead0, clientsWrite4,
           clientsWrite5, lockedWrite0, msg_D, clientId_D, lockedRead0,
           clocksWrite2, continue, i_C, msg_C, clientId, clocksRead5,
           clocksRead6, clocksWrite3, clocksRead7, clocksWrite4 >>

ProcSet == (ReplicaSet) \cup (GetSet) \cup (PutSet) \cup (DisconnectSet) \cup (NullSet)

Init == (* Global variables *)
        /\ replicasNetwork = [id \in ReplicaSet |-> <<>>]
        /\ clientsNetwork = [id \in ClientSet |-> <<>>]
        /\ db = [id \in ReplicaSet |-> [k \in KeySpace |-> NULL]]
        /\ logicalClocks = [id \in ClientSet |-> 0]
        /\ x = 0
        /\ busy = [id \in ClientSet |-> FALSE]
        (* Procedure Broadcast0 *)
        /\ domainStart = [ self \in ProcSet |-> defaultInitValue]
        /\ domainEnd = [ self \in ProcSet |-> defaultInitValue]
        /\ msg = [ self \in ProcSet |-> defaultInitValue]
        /\ i = [ self \in ProcSet |-> domainStart[self]]
        /\ nodesWrite = [ self \in ProcSet |-> defaultInitValue]
        /\ nodesWrite0 = [ self \in ProcSet |-> defaultInitValue]
        (* Process Replica *)
        /\ liveClients = [self \in ReplicaSet |-> ClientSet]
        /\ pendingRequests = [self \in ReplicaSet |-> [c \in liveClients[self] |-> <<>>]]
        /\ stableMessages = [self \in ReplicaSet |-> <<>>]
        /\ i_ = [self \in ReplicaSet |-> defaultInitValue]
        /\ firstPending = [self \in ReplicaSet |-> defaultInitValue]
        /\ timestamp = [self \in ReplicaSet |-> defaultInitValue]
        /\ nextClient = [self \in ReplicaSet |-> defaultInitValue]
        /\ lowestPending = [self \in ReplicaSet |-> defaultInitValue]
        /\ chooseMessage = [self \in ReplicaSet |-> defaultInitValue]
        /\ currentClocks = [self \in ReplicaSet |-> [c \in liveClients[self] |-> 0]]
        /\ minClock = [self \in ReplicaSet |-> defaultInitValue]
        /\ continue_ = [self \in ReplicaSet |-> defaultInitValue]
        /\ pendingClients = [self \in ReplicaSet |-> defaultInitValue]
        /\ clientsIter = [self \in ReplicaSet |-> defaultInitValue]
        /\ msg_ = [self \in ReplicaSet |-> defaultInitValue]
        /\ key = [self \in ReplicaSet |-> defaultInitValue]
        /\ val = [self \in ReplicaSet |-> defaultInitValue]
        /\ mydb = [self \in ReplicaSet |-> defaultInitValue]
        /\ requester = [self \in ReplicaSet |-> defaultInitValue]
        /\ mainLoop = [self \in ReplicaSet |-> TRUE]
        /\ kvRead = [self \in ReplicaSet |-> defaultInitValue]
        /\ replicasRead = [self \in ReplicaSet |-> defaultInitValue]
        /\ replicasWrite = [self \in ReplicaSet |-> defaultInitValue]
        /\ clientsWrite = [self \in ReplicaSet |-> defaultInitValue]
        /\ clientsWrite0 = [self \in ReplicaSet |-> defaultInitValue]
        /\ kvWrite = [self \in ReplicaSet |-> defaultInitValue]
        /\ kvWrite0 = [self \in ReplicaSet |-> defaultInitValue]
        /\ clientsWrite1 = [self \in ReplicaSet |-> defaultInitValue]
        (* Process GetClient *)
        /\ keyRead = [self \in GetSet |-> "getKey"]
        /\ continue_G = [self \in GetSet |-> TRUE]
        /\ i_G = [self \in GetSet |-> 0]
        /\ getReq = [self \in GetSet |-> defaultInitValue]
        /\ getResp = [self \in GetSet |-> defaultInitValue]
        /\ clientId_ = [self \in GetSet |-> defaultInitValue]
        /\ lockedRead = [self \in GetSet |-> defaultInitValue]
        /\ clocksRead = [self \in GetSet |-> defaultInitValue]
        /\ clocksRead0 = [self \in GetSet |-> defaultInitValue]
        /\ clocksWrite = [self \in GetSet |-> defaultInitValue]
        /\ clocksRead1 = [self \in GetSet |-> defaultInitValue]
        /\ replicasWrite0 = [self \in GetSet |-> defaultInitValue]
        /\ clientsRead = [self \in GetSet |-> defaultInitValue]
        /\ clientsWrite2 = [self \in GetSet |-> defaultInitValue]
        /\ clocksWrite0 = [self \in GetSet |-> defaultInitValue]
        /\ replicasWrite1 = [self \in GetSet |-> defaultInitValue]
        /\ clientsWrite3 = [self \in GetSet |-> defaultInitValue]
        (* Process PutClient *)
        /\ keyRead0 = [self \in PutSet |-> "putKey"]
        /\ continue_P = [self \in PutSet |-> TRUE]
        /\ i_P = [self \in PutSet |-> defaultInitValue]
        /\ putReq = [self \in PutSet |-> defaultInitValue]
        /\ putResp = [self \in PutSet |-> defaultInitValue]
        /\ clientId_P = [self \in PutSet |-> defaultInitValue]
        /\ clocksRead2 = [self \in PutSet |-> defaultInitValue]
        /\ clocksRead3 = [self \in PutSet |-> defaultInitValue]
        /\ clocksWrite1 = [self \in PutSet |-> defaultInitValue]
        /\ valueRead = [self \in PutSet |-> defaultInitValue]
        /\ clocksRead4 = [self \in PutSet |-> defaultInitValue]
        /\ lockedWrite = [self \in PutSet |-> defaultInitValue]
        /\ clientsRead0 = [self \in PutSet |-> defaultInitValue]
        /\ clientsWrite4 = [self \in PutSet |-> defaultInitValue]
        /\ clientsWrite5 = [self \in PutSet |-> defaultInitValue]
        /\ lockedWrite0 = [self \in PutSet |-> defaultInitValue]
        (* Process DisconnectClient *)
        /\ msg_D = [self \in DisconnectSet |-> defaultInitValue]
        /\ clientId_D = [self \in DisconnectSet |-> defaultInitValue]
        /\ lockedRead0 = [self \in DisconnectSet |-> defaultInitValue]
        /\ clocksWrite2 = [self \in DisconnectSet |-> defaultInitValue]
        (* Process ClockUpdateClient *)
        /\ continue = [self \in NullSet |-> TRUE]
        /\ i_C = [self \in NullSet |-> 0]
        /\ msg_C = [self \in NullSet |-> defaultInitValue]
        /\ clientId = [self \in NullSet |-> defaultInitValue]
        /\ clocksRead5 = [self \in NullSet |-> defaultInitValue]
        /\ clocksRead6 = [self \in NullSet |-> defaultInitValue]
        /\ clocksWrite3 = [self \in NullSet |-> defaultInitValue]
        /\ clocksRead7 = [self \in NullSet |-> defaultInitValue]
        /\ clocksWrite4 = [self \in NullSet |-> defaultInitValue]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self \in ReplicaSet -> "replicaLoop"
                                        [] self \in GetSet -> "getLoop"
                                        [] self \in PutSet -> "putLoop"
                                        [] self \in DisconnectSet -> "sendDisconnectRequest"
                                        [] self \in NullSet -> "clockUpdateLoop"]

loop(self) == /\ pc[self] = "loop"
              /\ IF (i[self])<=(domainEnd[self])
                    THEN /\ (Len(replicasNetwork[i[self]]))<(BUFFER_SIZE)
                         /\ nodesWrite' = [nodesWrite EXCEPT ![self] = [replicasNetwork EXCEPT ![i[self]] = Append(replicasNetwork[i[self]], msg[self])]]
                         /\ i' = [i EXCEPT ![self] = (i[self])+(1)]
                         /\ nodesWrite0' = [nodesWrite0 EXCEPT ![self] = nodesWrite'[self]]
                         /\ replicasNetwork' = nodesWrite0'[self]
                         /\ pc' = [pc EXCEPT ![self] = "loop"]
                    ELSE /\ nodesWrite0' = [nodesWrite0 EXCEPT ![self] = replicasNetwork]
                         /\ replicasNetwork' = nodesWrite0'[self]
                         /\ pc' = [pc EXCEPT ![self] = "ret"]
                         /\ UNCHANGED << i, nodesWrite >>
              /\ UNCHANGED << clientsNetwork, db, logicalClocks, x, busy,
                              stack, domainStart, domainEnd, msg, liveClients,
                              pendingRequests, stableMessages, i_,
                              firstPending, timestamp, nextClient,
                              lowestPending, chooseMessage, currentClocks,
                              minClock, continue_, pendingClients, clientsIter,
                              msg_, key, val, mydb, requester, mainLoop,
                              kvRead, replicasRead, replicasWrite,
                              clientsWrite, clientsWrite0, kvWrite, kvWrite0,
                              clientsWrite1, keyRead, continue_G, i_G, getReq,
                              getResp, clientId_, lockedRead, clocksRead,
                              clocksRead0, clocksWrite, clocksRead1,
                              replicasWrite0, clientsRead, clientsWrite2,
                              clocksWrite0, replicasWrite1, clientsWrite3,
                              keyRead0, continue_P, i_P, putReq, putResp,
                              clientId_P, clocksRead2, clocksRead3,
                              clocksWrite1, valueRead, clocksRead4,
                              lockedWrite, clientsRead0, clientsWrite4,
                              clientsWrite5, lockedWrite0, msg_D, clientId_D,
                              lockedRead0, clocksWrite2, continue, i_C, msg_C,
                              clientId, clocksRead5, clocksRead6, clocksWrite3,
                              clocksRead7, clocksWrite4 >>

ret(self) == /\ pc[self] = "ret"
             /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
             /\ i' = [i EXCEPT ![self] = Head(stack[self]).i]
             /\ nodesWrite' = [nodesWrite EXCEPT ![self] = Head(stack[self]).nodesWrite]
             /\ nodesWrite0' = [nodesWrite0 EXCEPT ![self] = Head(stack[self]).nodesWrite0]
             /\ domainStart' = [domainStart EXCEPT ![self] = Head(stack[self]).domainStart]
             /\ domainEnd' = [domainEnd EXCEPT ![self] = Head(stack[self]).domainEnd]
             /\ msg' = [msg EXCEPT ![self] = Head(stack[self]).msg]
             /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
             /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                             logicalClocks, x, busy, liveClients,
                             pendingRequests, stableMessages, i_, firstPending,
                             timestamp, nextClient, lowestPending,
                             chooseMessage, currentClocks, minClock, continue_,
                             pendingClients, clientsIter, msg_, key, val, mydb,
                             requester, mainLoop, kvRead, replicasRead,
                             replicasWrite, clientsWrite, clientsWrite0,
                             kvWrite, kvWrite0, clientsWrite1, keyRead,
                             continue_G, i_G, getReq, getResp, clientId_,
                             lockedRead, clocksRead, clocksRead0, clocksWrite,
                             clocksRead1, replicasWrite0, clientsRead,
                             clientsWrite2, clocksWrite0, replicasWrite1,
                             clientsWrite3, keyRead0, continue_P, i_P, putReq,
                             putResp, clientId_P, clocksRead2, clocksRead3,
                             clocksWrite1, valueRead, clocksRead4, lockedWrite,
                             clientsRead0, clientsWrite4, clientsWrite5,
                             lockedWrite0, msg_D, clientId_D, lockedRead0,
                             clocksWrite2, continue, i_C, msg_C, clientId,
                             clocksRead5, clocksRead6, clocksWrite3,
                             clocksRead7, clocksWrite4 >>

Broadcast0(self) == loop(self) \/ ret(self)

replicaLoop(self) == /\ pc[self] = "replicaLoop"
                     /\ IF mainLoop[self]
                           THEN /\ kvRead' = [kvRead EXCEPT ![self] = db]
                                /\ mydb' = [mydb EXCEPT ![self] = kvRead'[self][self]]
                                /\ stableMessages' = [stableMessages EXCEPT ![self] = <<>>]
                                /\ continue_' = [continue_ EXCEPT ![self] = TRUE]
                                /\ pc' = [pc EXCEPT ![self] = "receiveClientRequest"]
                           ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                                /\ UNCHANGED << stableMessages, continue_,
                                                mydb, kvRead >>
                     /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                     logicalClocks, x, busy, stack,
                                     domainStart, domainEnd, msg, i,
                                     nodesWrite, nodesWrite0, liveClients,
                                     pendingRequests, i_, firstPending,
                                     timestamp, nextClient, lowestPending,
                                     chooseMessage, currentClocks, minClock,
                                     pendingClients, clientsIter, msg_, key,
                                     val, requester, mainLoop, replicasRead,
                                     replicasWrite, clientsWrite,
                                     clientsWrite0, kvWrite, kvWrite0,
                                     clientsWrite1, keyRead, continue_G, i_G,
                                     getReq, getResp, clientId_, lockedRead,
                                     clocksRead, clocksRead0, clocksWrite,
                                     clocksRead1, replicasWrite0, clientsRead,
                                     clientsWrite2, clocksWrite0,
                                     replicasWrite1, clientsWrite3, keyRead0,
                                     continue_P, i_P, putReq, putResp,
                                     clientId_P, clocksRead2, clocksRead3,
                                     clocksWrite1, valueRead, clocksRead4,
                                     lockedWrite, clientsRead0, clientsWrite4,
                                     clientsWrite5, lockedWrite0, msg_D,
                                     clientId_D, lockedRead0, clocksWrite2,
                                     continue, i_C, msg_C, clientId,
                                     clocksRead5, clocksRead6, clocksWrite3,
                                     clocksRead7, clocksWrite4 >>

receiveClientRequest(self) == /\ pc[self] = "receiveClientRequest"
                              /\ (Len(replicasNetwork[self]))>(0)
                              /\ LET msg0 == Head(replicasNetwork[self]) IN
                                   /\ replicasWrite' = [replicasWrite EXCEPT ![self] = [replicasNetwork EXCEPT ![self] = Tail(replicasNetwork[self])]]
                                   /\ replicasRead' = [replicasRead EXCEPT ![self] = msg0]
                              /\ msg_' = [msg_ EXCEPT ![self] = replicasRead'[self]]
                              /\ replicasNetwork' = replicasWrite'[self]
                              /\ pc' = [pc EXCEPT ![self] = "clientDisconnected"]
                              /\ UNCHANGED << clientsNetwork, db,
                                              logicalClocks, x, busy, stack,
                                              domainStart, domainEnd, msg, i,
                                              nodesWrite, nodesWrite0,
                                              liveClients, pendingRequests,
                                              stableMessages, i_, firstPending,
                                              timestamp, nextClient,
                                              lowestPending, chooseMessage,
                                              currentClocks, minClock,
                                              continue_, pendingClients,
                                              clientsIter, key, val, mydb,
                                              requester, mainLoop, kvRead,
                                              clientsWrite, clientsWrite0,
                                              kvWrite, kvWrite0, clientsWrite1,
                                              keyRead, continue_G, i_G, getReq,
                                              getResp, clientId_, lockedRead,
                                              clocksRead, clocksRead0,
                                              clocksWrite, clocksRead1,
                                              replicasWrite0, clientsRead,
                                              clientsWrite2, clocksWrite0,
                                              replicasWrite1, clientsWrite3,
                                              keyRead0, continue_P, i_P,
                                              putReq, putResp, clientId_P,
                                              clocksRead2, clocksRead3,
                                              clocksWrite1, valueRead,
                                              clocksRead4, lockedWrite,
                                              clientsRead0, clientsWrite4,
                                              clientsWrite5, lockedWrite0,
                                              msg_D, clientId_D, lockedRead0,
                                              clocksWrite2, continue, i_C,
                                              msg_C, clientId, clocksRead5,
                                              clocksRead6, clocksWrite3,
                                              clocksRead7, clocksWrite4 >>

clientDisconnected(self) == /\ pc[self] = "clientDisconnected"
                            /\ IF (msg_[self][1])=(DISCONNECT_MSG)
                                  THEN /\ liveClients' = [liveClients EXCEPT ![self] = (liveClients[self])\({msg_[self][2]})]
                                  ELSE /\ TRUE
                                       /\ UNCHANGED liveClients
                            /\ pc' = [pc EXCEPT ![self] = "replicaGetRequest"]
                            /\ UNCHANGED << replicasNetwork, clientsNetwork,
                                            db, logicalClocks, x, busy, stack,
                                            domainStart, domainEnd, msg, i,
                                            nodesWrite, nodesWrite0,
                                            pendingRequests, stableMessages,
                                            i_, firstPending, timestamp,
                                            nextClient, lowestPending,
                                            chooseMessage, currentClocks,
                                            minClock, continue_,
                                            pendingClients, clientsIter, msg_,
                                            key, val, mydb, requester,
                                            mainLoop, kvRead, replicasRead,
                                            replicasWrite, clientsWrite,
                                            clientsWrite0, kvWrite, kvWrite0,
                                            clientsWrite1, keyRead, continue_G,
                                            i_G, getReq, getResp, clientId_,
                                            lockedRead, clocksRead,
                                            clocksRead0, clocksWrite,
                                            clocksRead1, replicasWrite0,
                                            clientsRead, clientsWrite2,
                                            clocksWrite0, replicasWrite1,
                                            clientsWrite3, keyRead0,
                                            continue_P, i_P, putReq, putResp,
                                            clientId_P, clocksRead2,
                                            clocksRead3, clocksWrite1,
                                            valueRead, clocksRead4,
                                            lockedWrite, clientsRead0,
                                            clientsWrite4, clientsWrite5,
                                            lockedWrite0, msg_D, clientId_D,
                                            lockedRead0, clocksWrite2,
                                            continue, i_C, msg_C, clientId,
                                            clocksRead5, clocksRead6,
                                            clocksWrite3, clocksRead7,
                                            clocksWrite4 >>

replicaGetRequest(self) == /\ pc[self] = "replicaGetRequest"
                           /\ IF (msg_[self][1])=(GET_MSG)
                                 THEN /\ requester' = [requester EXCEPT ![self] = msg_[self][3]]
                                      /\ Assert((requester'[self])\in(liveClients[self]),
                                                "Failure of assertion at line 670, column 25.")
                                      /\ currentClocks' = [currentClocks EXCEPT ![self][requester'[self]] = msg_[self][4]]
                                      /\ pendingRequests' = [pendingRequests EXCEPT ![self][requester'[self]] = Append(pendingRequests[self][requester'[self]], msg_[self])]
                                 ELSE /\ TRUE
                                      /\ UNCHANGED << pendingRequests,
                                                      currentClocks, requester >>
                           /\ pc' = [pc EXCEPT ![self] = "replicaPutRequest"]
                           /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                           logicalClocks, x, busy, stack,
                                           domainStart, domainEnd, msg, i,
                                           nodesWrite, nodesWrite0,
                                           liveClients, stableMessages, i_,
                                           firstPending, timestamp, nextClient,
                                           lowestPending, chooseMessage,
                                           minClock, continue_, pendingClients,
                                           clientsIter, msg_, key, val, mydb,
                                           mainLoop, kvRead, replicasRead,
                                           replicasWrite, clientsWrite,
                                           clientsWrite0, kvWrite, kvWrite0,
                                           clientsWrite1, keyRead, continue_G,
                                           i_G, getReq, getResp, clientId_,
                                           lockedRead, clocksRead, clocksRead0,
                                           clocksWrite, clocksRead1,
                                           replicasWrite0, clientsRead,
                                           clientsWrite2, clocksWrite0,
                                           replicasWrite1, clientsWrite3,
                                           keyRead0, continue_P, i_P, putReq,
                                           putResp, clientId_P, clocksRead2,
                                           clocksRead3, clocksWrite1,
                                           valueRead, clocksRead4, lockedWrite,
                                           clientsRead0, clientsWrite4,
                                           clientsWrite5, lockedWrite0, msg_D,
                                           clientId_D, lockedRead0,
                                           clocksWrite2, continue, i_C, msg_C,
                                           clientId, clocksRead5, clocksRead6,
                                           clocksWrite3, clocksRead7,
                                           clocksWrite4 >>

replicaPutRequest(self) == /\ pc[self] = "replicaPutRequest"
                           /\ IF (msg_[self][1])=(PUT_MSG)
                                 THEN /\ requester' = [requester EXCEPT ![self] = msg_[self][4]]
                                      /\ currentClocks' = [currentClocks EXCEPT ![self][requester'[self]] = msg_[self][5]]
                                      /\ pendingRequests' = [pendingRequests EXCEPT ![self][requester'[self]] = Append(pendingRequests[self][requester'[self]], msg_[self])]
                                 ELSE /\ TRUE
                                      /\ UNCHANGED << pendingRequests,
                                                      currentClocks, requester >>
                           /\ pc' = [pc EXCEPT ![self] = "replicaNullRequest"]
                           /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                           logicalClocks, x, busy, stack,
                                           domainStart, domainEnd, msg, i,
                                           nodesWrite, nodesWrite0,
                                           liveClients, stableMessages, i_,
                                           firstPending, timestamp, nextClient,
                                           lowestPending, chooseMessage,
                                           minClock, continue_, pendingClients,
                                           clientsIter, msg_, key, val, mydb,
                                           mainLoop, kvRead, replicasRead,
                                           replicasWrite, clientsWrite,
                                           clientsWrite0, kvWrite, kvWrite0,
                                           clientsWrite1, keyRead, continue_G,
                                           i_G, getReq, getResp, clientId_,
                                           lockedRead, clocksRead, clocksRead0,
                                           clocksWrite, clocksRead1,
                                           replicasWrite0, clientsRead,
                                           clientsWrite2, clocksWrite0,
                                           replicasWrite1, clientsWrite3,
                                           keyRead0, continue_P, i_P, putReq,
                                           putResp, clientId_P, clocksRead2,
                                           clocksRead3, clocksWrite1,
                                           valueRead, clocksRead4, lockedWrite,
                                           clientsRead0, clientsWrite4,
                                           clientsWrite5, lockedWrite0, msg_D,
                                           clientId_D, lockedRead0,
                                           clocksWrite2, continue, i_C, msg_C,
                                           clientId, clocksRead5, clocksRead6,
                                           clocksWrite3, clocksRead7,
                                           clocksWrite4 >>

replicaNullRequest(self) == /\ pc[self] = "replicaNullRequest"
                            /\ IF (msg_[self][1])=(NULL_MSG)
                                  THEN /\ requester' = [requester EXCEPT ![self] = msg_[self][2]]
                                       /\ currentClocks' = [currentClocks EXCEPT ![self][requester'[self]] = msg_[self][3]]
                                  ELSE /\ TRUE
                                       /\ UNCHANGED << currentClocks,
                                                       requester >>
                            /\ pc' = [pc EXCEPT ![self] = "findStableRequestsLoop"]
                            /\ UNCHANGED << replicasNetwork, clientsNetwork,
                                            db, logicalClocks, x, busy, stack,
                                            domainStart, domainEnd, msg, i,
                                            nodesWrite, nodesWrite0,
                                            liveClients, pendingRequests,
                                            stableMessages, i_, firstPending,
                                            timestamp, nextClient,
                                            lowestPending, chooseMessage,
                                            minClock, continue_,
                                            pendingClients, clientsIter, msg_,
                                            key, val, mydb, mainLoop, kvRead,
                                            replicasRead, replicasWrite,
                                            clientsWrite, clientsWrite0,
                                            kvWrite, kvWrite0, clientsWrite1,
                                            keyRead, continue_G, i_G, getReq,
                                            getResp, clientId_, lockedRead,
                                            clocksRead, clocksRead0,
                                            clocksWrite, clocksRead1,
                                            replicasWrite0, clientsRead,
                                            clientsWrite2, clocksWrite0,
                                            replicasWrite1, clientsWrite3,
                                            keyRead0, continue_P, i_P, putReq,
                                            putResp, clientId_P, clocksRead2,
                                            clocksRead3, clocksWrite1,
                                            valueRead, clocksRead4,
                                            lockedWrite, clientsRead0,
                                            clientsWrite4, clientsWrite5,
                                            lockedWrite0, msg_D, clientId_D,
                                            lockedRead0, clocksWrite2,
                                            continue, i_C, msg_C, clientId,
                                            clocksRead5, clocksRead6,
                                            clocksWrite3, clocksRead7,
                                            clocksWrite4 >>

findStableRequestsLoop(self) == /\ pc[self] = "findStableRequestsLoop"
                                /\ IF continue_[self]
                                      THEN /\ pendingClients' = [pendingClients EXCEPT ![self] = {c \in liveClients[self] : (Len(pendingRequests[self][c]))>(0)}]
                                           /\ nextClient' = [nextClient EXCEPT ![self] = (NUM_NODES)+(1)]
                                           /\ clientsIter' = [clientsIter EXCEPT ![self] = liveClients[self]]
                                           /\ i_' = [i_ EXCEPT ![self] = 0]
                                           /\ minClock' = [minClock EXCEPT ![self] = 0]
                                           /\ pc' = [pc EXCEPT ![self] = "findMinClock"]
                                      ELSE /\ i_' = [i_ EXCEPT ![self] = 1]
                                           /\ pc' = [pc EXCEPT ![self] = "respondPendingRequestsLoop"]
                                           /\ UNCHANGED << nextClient,
                                                           minClock,
                                                           pendingClients,
                                                           clientsIter >>
                                /\ UNCHANGED << replicasNetwork,
                                                clientsNetwork, db,
                                                logicalClocks, x, busy, stack,
                                                domainStart, domainEnd, msg, i,
                                                nodesWrite, nodesWrite0,
                                                liveClients, pendingRequests,
                                                stableMessages, firstPending,
                                                timestamp, lowestPending,
                                                chooseMessage, currentClocks,
                                                continue_, msg_, key, val,
                                                mydb, requester, mainLoop,
                                                kvRead, replicasRead,
                                                replicasWrite, clientsWrite,
                                                clientsWrite0, kvWrite,
                                                kvWrite0, clientsWrite1,
                                                keyRead, continue_G, i_G,
                                                getReq, getResp, clientId_,
                                                lockedRead, clocksRead,
                                                clocksRead0, clocksWrite,
                                                clocksRead1, replicasWrite0,
                                                clientsRead, clientsWrite2,
                                                clocksWrite0, replicasWrite1,
                                                clientsWrite3, keyRead0,
                                                continue_P, i_P, putReq,
                                                putResp, clientId_P,
                                                clocksRead2, clocksRead3,
                                                clocksWrite1, valueRead,
                                                clocksRead4, lockedWrite,
                                                clientsRead0, clientsWrite4,
                                                clientsWrite5, lockedWrite0,
                                                msg_D, clientId_D, lockedRead0,
                                                clocksWrite2, continue, i_C,
                                                msg_C, clientId, clocksRead5,
                                                clocksRead6, clocksWrite3,
                                                clocksRead7, clocksWrite4 >>

findMinClock(self) == /\ pc[self] = "findMinClock"
                      /\ IF (i_[self])<(Cardinality(clientsIter[self]))
                            THEN /\ \E client \in clientsIter[self]:
                                      /\ IF ((minClock[self])=(0))\/((currentClocks[self][client])<(minClock[self]))
                                            THEN /\ minClock' = [minClock EXCEPT ![self] = currentClocks[self][client]]
                                            ELSE /\ TRUE
                                                 /\ UNCHANGED minClock
                                      /\ clientsIter' = [clientsIter EXCEPT ![self] = (clientsIter[self])\({client})]
                                 /\ pc' = [pc EXCEPT ![self] = "findMinClock"]
                                 /\ UNCHANGED << i_, lowestPending >>
                            ELSE /\ lowestPending' = [lowestPending EXCEPT ![self] = (minClock[self])+(1)]
                                 /\ i_' = [i_ EXCEPT ![self] = 0]
                                 /\ pc' = [pc EXCEPT ![self] = "findMinClient"]
                                 /\ UNCHANGED << minClock, clientsIter >>
                      /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                      logicalClocks, x, busy, stack,
                                      domainStart, domainEnd, msg, i,
                                      nodesWrite, nodesWrite0, liveClients,
                                      pendingRequests, stableMessages,
                                      firstPending, timestamp, nextClient,
                                      chooseMessage, currentClocks, continue_,
                                      pendingClients, msg_, key, val, mydb,
                                      requester, mainLoop, kvRead,
                                      replicasRead, replicasWrite,
                                      clientsWrite, clientsWrite0, kvWrite,
                                      kvWrite0, clientsWrite1, keyRead,
                                      continue_G, i_G, getReq, getResp,
                                      clientId_, lockedRead, clocksRead,
                                      clocksRead0, clocksWrite, clocksRead1,
                                      replicasWrite0, clientsRead,
                                      clientsWrite2, clocksWrite0,
                                      replicasWrite1, clientsWrite3, keyRead0,
                                      continue_P, i_P, putReq, putResp,
                                      clientId_P, clocksRead2, clocksRead3,
                                      clocksWrite1, valueRead, clocksRead4,
                                      lockedWrite, clientsRead0, clientsWrite4,
                                      clientsWrite5, lockedWrite0, msg_D,
                                      clientId_D, lockedRead0, clocksWrite2,
                                      continue, i_C, msg_C, clientId,
                                      clocksRead5, clocksRead6, clocksWrite3,
                                      clocksRead7, clocksWrite4 >>

findMinClient(self) == /\ pc[self] = "findMinClient"
                       /\ IF (i_[self])<(Cardinality(pendingClients[self]))
                             THEN /\ \E client \in pendingClients[self]:
                                       /\ firstPending' = [firstPending EXCEPT ![self] = Head(pendingRequests[self][client])]
                                       /\ Assert(((firstPending'[self][1])=(GET_MSG))\/((firstPending'[self][1])=(PUT_MSG)),
                                                 "Failure of assertion at line 713, column 37.")
                                       /\ IF (firstPending'[self][1])=(GET_MSG)
                                             THEN /\ timestamp' = [timestamp EXCEPT ![self] = firstPending'[self][4]]
                                             ELSE /\ timestamp' = [timestamp EXCEPT ![self] = firstPending'[self][5]]
                                       /\ IF (timestamp'[self])<(minClock[self])
                                             THEN /\ chooseMessage' = [chooseMessage EXCEPT ![self] = ((timestamp'[self])<(lowestPending[self]))\/(((timestamp'[self])=(lowestPending[self]))/\((client)<(nextClient[self])))]
                                                  /\ IF chooseMessage'[self]
                                                        THEN /\ nextClient' = [nextClient EXCEPT ![self] = client]
                                                             /\ lowestPending' = [lowestPending EXCEPT ![self] = timestamp'[self]]
                                                        ELSE /\ TRUE
                                                             /\ UNCHANGED << nextClient,
                                                                             lowestPending >>
                                             ELSE /\ TRUE
                                                  /\ UNCHANGED << nextClient,
                                                                  lowestPending,
                                                                  chooseMessage >>
                                       /\ pendingClients' = [pendingClients EXCEPT ![self] = (pendingClients[self])\({client})]
                                  /\ pc' = [pc EXCEPT ![self] = "findMinClient"]
                             ELSE /\ pc' = [pc EXCEPT ![self] = "addStableMessage"]
                                  /\ UNCHANGED << firstPending, timestamp,
                                                  nextClient, lowestPending,
                                                  chooseMessage,
                                                  pendingClients >>
                       /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                       logicalClocks, x, busy, stack,
                                       domainStart, domainEnd, msg, i,
                                       nodesWrite, nodesWrite0, liveClients,
                                       pendingRequests, stableMessages, i_,
                                       currentClocks, minClock, continue_,
                                       clientsIter, msg_, key, val, mydb,
                                       requester, mainLoop, kvRead,
                                       replicasRead, replicasWrite,
                                       clientsWrite, clientsWrite0, kvWrite,
                                       kvWrite0, clientsWrite1, keyRead,
                                       continue_G, i_G, getReq, getResp,
                                       clientId_, lockedRead, clocksRead,
                                       clocksRead0, clocksWrite, clocksRead1,
                                       replicasWrite0, clientsRead,
                                       clientsWrite2, clocksWrite0,
                                       replicasWrite1, clientsWrite3, keyRead0,
                                       continue_P, i_P, putReq, putResp,
                                       clientId_P, clocksRead2, clocksRead3,
                                       clocksWrite1, valueRead, clocksRead4,
                                       lockedWrite, clientsRead0,
                                       clientsWrite4, clientsWrite5,
                                       lockedWrite0, msg_D, clientId_D,
                                       lockedRead0, clocksWrite2, continue,
                                       i_C, msg_C, clientId, clocksRead5,
                                       clocksRead6, clocksWrite3, clocksRead7,
                                       clocksWrite4 >>

addStableMessage(self) == /\ pc[self] = "addStableMessage"
                          /\ IF (lowestPending[self])<(minClock[self])
                                THEN /\ msg_' = [msg_ EXCEPT ![self] = Head(pendingRequests[self][nextClient[self]])]
                                     /\ pendingRequests' = [pendingRequests EXCEPT ![self][nextClient[self]] = Tail(pendingRequests[self][nextClient[self]])]
                                     /\ stableMessages' = [stableMessages EXCEPT ![self] = Append(stableMessages[self], msg_'[self])]
                                     /\ pc' = [pc EXCEPT ![self] = "findStableRequestsLoop"]
                                     /\ UNCHANGED continue_
                                ELSE /\ continue_' = [continue_ EXCEPT ![self] = FALSE]
                                     /\ pc' = [pc EXCEPT ![self] = "findStableRequestsLoop"]
                                     /\ UNCHANGED << pendingRequests,
                                                     stableMessages, msg_ >>
                          /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                          logicalClocks, x, busy, stack,
                                          domainStart, domainEnd, msg, i,
                                          nodesWrite, nodesWrite0, liveClients,
                                          i_, firstPending, timestamp,
                                          nextClient, lowestPending,
                                          chooseMessage, currentClocks,
                                          minClock, pendingClients,
                                          clientsIter, key, val, mydb,
                                          requester, mainLoop, kvRead,
                                          replicasRead, replicasWrite,
                                          clientsWrite, clientsWrite0, kvWrite,
                                          kvWrite0, clientsWrite1, keyRead,
                                          continue_G, i_G, getReq, getResp,
                                          clientId_, lockedRead, clocksRead,
                                          clocksRead0, clocksWrite,
                                          clocksRead1, replicasWrite0,
                                          clientsRead, clientsWrite2,
                                          clocksWrite0, replicasWrite1,
                                          clientsWrite3, keyRead0, continue_P,
                                          i_P, putReq, putResp, clientId_P,
                                          clocksRead2, clocksRead3,
                                          clocksWrite1, valueRead, clocksRead4,
                                          lockedWrite, clientsRead0,
                                          clientsWrite4, clientsWrite5,
                                          lockedWrite0, msg_D, clientId_D,
                                          lockedRead0, clocksWrite2, continue,
                                          i_C, msg_C, clientId, clocksRead5,
                                          clocksRead6, clocksWrite3,
                                          clocksRead7, clocksWrite4 >>

respondPendingRequestsLoop(self) == /\ pc[self] = "respondPendingRequestsLoop"
                                    /\ IF (i_[self])<=(Len(stableMessages[self]))
                                          THEN /\ msg_' = [msg_ EXCEPT ![self] = stableMessages[self][i_[self]]]
                                               /\ i_' = [i_ EXCEPT ![self] = (i_[self])+(1)]
                                               /\ pc' = [pc EXCEPT ![self] = "respondStableGet"]
                                          ELSE /\ pc' = [pc EXCEPT ![self] = "replicaLoop"]
                                               /\ UNCHANGED << i_, msg_ >>
                                    /\ UNCHANGED << replicasNetwork,
                                                    clientsNetwork, db,
                                                    logicalClocks, x, busy,
                                                    stack, domainStart,
                                                    domainEnd, msg, i,
                                                    nodesWrite, nodesWrite0,
                                                    liveClients,
                                                    pendingRequests,
                                                    stableMessages,
                                                    firstPending, timestamp,
                                                    nextClient, lowestPending,
                                                    chooseMessage,
                                                    currentClocks, minClock,
                                                    continue_, pendingClients,
                                                    clientsIter, key, val,
                                                    mydb, requester, mainLoop,
                                                    kvRead, replicasRead,
                                                    replicasWrite,
                                                    clientsWrite,
                                                    clientsWrite0, kvWrite,
                                                    kvWrite0, clientsWrite1,
                                                    keyRead, continue_G, i_G,
                                                    getReq, getResp, clientId_,
                                                    lockedRead, clocksRead,
                                                    clocksRead0, clocksWrite,
                                                    clocksRead1,
                                                    replicasWrite0,
                                                    clientsRead, clientsWrite2,
                                                    clocksWrite0,
                                                    replicasWrite1,
                                                    clientsWrite3, keyRead0,
                                                    continue_P, i_P, putReq,
                                                    putResp, clientId_P,
                                                    clocksRead2, clocksRead3,
                                                    clocksWrite1, valueRead,
                                                    clocksRead4, lockedWrite,
                                                    clientsRead0,
                                                    clientsWrite4,
                                                    clientsWrite5,
                                                    lockedWrite0, msg_D,
                                                    clientId_D, lockedRead0,
                                                    clocksWrite2, continue,
                                                    i_C, msg_C, clientId,
                                                    clocksRead5, clocksRead6,
                                                    clocksWrite3, clocksRead7,
                                                    clocksWrite4 >>

respondStableGet(self) == /\ pc[self] = "respondStableGet"
                          /\ IF (msg_[self][1])=(GET_MSG)
                                THEN /\ key' = [key EXCEPT ![self] = msg_[self][2]]
                                     /\ val' = [val EXCEPT ![self] = mydb[self][key'[self]]]
                                     /\ (Len(clientsNetwork[msg_[self][3]]))<(BUFFER_SIZE)
                                     /\ clientsWrite' = [clientsWrite EXCEPT ![self] = [clientsNetwork EXCEPT ![msg_[self][3]] = Append(clientsNetwork[msg_[self][3]], val'[self])]]
                                     /\ clientsWrite0' = [clientsWrite0 EXCEPT ![self] = clientsWrite'[self]]
                                     /\ clientsNetwork' = clientsWrite0'[self]
                                ELSE /\ clientsWrite0' = [clientsWrite0 EXCEPT ![self] = clientsNetwork]
                                     /\ clientsNetwork' = clientsWrite0'[self]
                                     /\ UNCHANGED << key, val, clientsWrite >>
                          /\ pc' = [pc EXCEPT ![self] = "respondStablePut"]
                          /\ UNCHANGED << replicasNetwork, db, logicalClocks,
                                          x, busy, stack, domainStart,
                                          domainEnd, msg, i, nodesWrite,
                                          nodesWrite0, liveClients,
                                          pendingRequests, stableMessages, i_,
                                          firstPending, timestamp, nextClient,
                                          lowestPending, chooseMessage,
                                          currentClocks, minClock, continue_,
                                          pendingClients, clientsIter, msg_,
                                          mydb, requester, mainLoop, kvRead,
                                          replicasRead, replicasWrite, kvWrite,
                                          kvWrite0, clientsWrite1, keyRead,
                                          continue_G, i_G, getReq, getResp,
                                          clientId_, lockedRead, clocksRead,
                                          clocksRead0, clocksWrite,
                                          clocksRead1, replicasWrite0,
                                          clientsRead, clientsWrite2,
                                          clocksWrite0, replicasWrite1,
                                          clientsWrite3, keyRead0, continue_P,
                                          i_P, putReq, putResp, clientId_P,
                                          clocksRead2, clocksRead3,
                                          clocksWrite1, valueRead, clocksRead4,
                                          lockedWrite, clientsRead0,
                                          clientsWrite4, clientsWrite5,
                                          lockedWrite0, msg_D, clientId_D,
                                          lockedRead0, clocksWrite2, continue,
                                          i_C, msg_C, clientId, clocksRead5,
                                          clocksRead6, clocksWrite3,
                                          clocksRead7, clocksWrite4 >>

respondStablePut(self) == /\ pc[self] = "respondStablePut"
                          /\ IF (msg_[self][1])=(PUT_MSG)
                                THEN /\ key' = [key EXCEPT ![self] = msg_[self][2]]
                                     /\ val' = [val EXCEPT ![self] = msg_[self][3]]
                                     /\ mydb' = [mydb EXCEPT ![self][key'[self]] = val'[self]]
                                     /\ kvWrite' = [kvWrite EXCEPT ![self] = [db EXCEPT ![self] = mydb'[self]]]
                                     /\ (Len(clientsNetwork[msg_[self][4]]))<(BUFFER_SIZE)
                                     /\ clientsWrite' = [clientsWrite EXCEPT ![self] = [clientsNetwork EXCEPT ![msg_[self][4]] = Append(clientsNetwork[msg_[self][4]], OK_RESPONSE)]]
                                     /\ kvWrite0' = [kvWrite0 EXCEPT ![self] = kvWrite'[self]]
                                     /\ clientsWrite1' = [clientsWrite1 EXCEPT ![self] = clientsWrite'[self]]
                                     /\ clientsNetwork' = clientsWrite1'[self]
                                     /\ db' = kvWrite0'[self]
                                     /\ pc' = [pc EXCEPT ![self] = "respondPendingRequestsLoop"]
                                ELSE /\ kvWrite0' = [kvWrite0 EXCEPT ![self] = db]
                                     /\ clientsWrite1' = [clientsWrite1 EXCEPT ![self] = clientsNetwork]
                                     /\ clientsNetwork' = clientsWrite1'[self]
                                     /\ db' = kvWrite0'[self]
                                     /\ pc' = [pc EXCEPT ![self] = "respondPendingRequestsLoop"]
                                     /\ UNCHANGED << key, val, mydb,
                                                     clientsWrite, kvWrite >>
                          /\ UNCHANGED << replicasNetwork, logicalClocks, x,
                                          busy, stack, domainStart, domainEnd,
                                          msg, i, nodesWrite, nodesWrite0,
                                          liveClients, pendingRequests,
                                          stableMessages, i_, firstPending,
                                          timestamp, nextClient, lowestPending,
                                          chooseMessage, currentClocks,
                                          minClock, continue_, pendingClients,
                                          clientsIter, msg_, requester,
                                          mainLoop, kvRead, replicasRead,
                                          replicasWrite, clientsWrite0,
                                          keyRead, continue_G, i_G, getReq,
                                          getResp, clientId_, lockedRead,
                                          clocksRead, clocksRead0, clocksWrite,
                                          clocksRead1, replicasWrite0,
                                          clientsRead, clientsWrite2,
                                          clocksWrite0, replicasWrite1,
                                          clientsWrite3, keyRead0, continue_P,
                                          i_P, putReq, putResp, clientId_P,
                                          clocksRead2, clocksRead3,
                                          clocksWrite1, valueRead, clocksRead4,
                                          lockedWrite, clientsRead0,
                                          clientsWrite4, clientsWrite5,
                                          lockedWrite0, msg_D, clientId_D,
                                          lockedRead0, clocksWrite2, continue,
                                          i_C, msg_C, clientId, clocksRead5,
                                          clocksRead6, clocksWrite3,
                                          clocksRead7, clocksWrite4 >>

Replica(self) == replicaLoop(self) \/ receiveClientRequest(self)
                    \/ clientDisconnected(self) \/ replicaGetRequest(self)
                    \/ replicaPutRequest(self) \/ replicaNullRequest(self)
                    \/ findStableRequestsLoop(self) \/ findMinClock(self)
                    \/ findMinClient(self) \/ addStableMessage(self)
                    \/ respondPendingRequestsLoop(self)
                    \/ respondStableGet(self) \/ respondStablePut(self)

getLoop(self) == /\ pc[self] = "getLoop"
                 /\ IF continue_G[self]
                       THEN /\ pc' = [pc EXCEPT ![self] = "getRequest"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                 /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                 logicalClocks, x, busy, stack, domainStart,
                                 domainEnd, msg, i, nodesWrite, nodesWrite0,
                                 liveClients, pendingRequests, stableMessages,
                                 i_, firstPending, timestamp, nextClient,
                                 lowestPending, chooseMessage, currentClocks,
                                 minClock, continue_, pendingClients,
                                 clientsIter, msg_, key, val, mydb, requester,
                                 mainLoop, kvRead, replicasRead, replicasWrite,
                                 clientsWrite, clientsWrite0, kvWrite,
                                 kvWrite0, clientsWrite1, keyRead, continue_G,
                                 i_G, getReq, getResp, clientId_, lockedRead,
                                 clocksRead, clocksRead0, clocksWrite,
                                 clocksRead1, replicasWrite0, clientsRead,
                                 clientsWrite2, clocksWrite0, replicasWrite1,
                                 clientsWrite3, keyRead0, continue_P, i_P,
                                 putReq, putResp, clientId_P, clocksRead2,
                                 clocksRead3, clocksWrite1, valueRead,
                                 clocksRead4, lockedWrite, clientsRead0,
                                 clientsWrite4, clientsWrite5, lockedWrite0,
                                 msg_D, clientId_D, lockedRead0, clocksWrite2,
                                 continue, i_C, msg_C, clientId, clocksRead5,
                                 clocksRead6, clocksWrite3, clocksRead7,
                                 clocksWrite4 >>

getRequest(self) == /\ pc[self] = "getRequest"
                    /\ clientId_' = [clientId_ EXCEPT ![self] = (self)-((NUM_CLIENTS)*(GET_ORDER))]
                    /\ lockedRead' = [lockedRead EXCEPT ![self] = busy]
                    /\ ~(lockedRead'[self][clientId_'[self]])
                    /\ clocksRead' = [clocksRead EXCEPT ![self] = logicalClocks]
                    /\ IF (clocksRead'[self][clientId_'[self]])=(-(1))
                          THEN /\ continue_G' = [continue_G EXCEPT ![self] = FALSE]
                               /\ clocksWrite0' = [clocksWrite0 EXCEPT ![self] = logicalClocks]
                               /\ replicasWrite1' = [replicasWrite1 EXCEPT ![self] = replicasNetwork]
                               /\ clientsWrite3' = [clientsWrite3 EXCEPT ![self] = clientsNetwork]
                               /\ replicasNetwork' = replicasWrite1'[self]
                               /\ clientsNetwork' = clientsWrite3'[self]
                               /\ logicalClocks' = clocksWrite0'[self]
                               /\ pc' = [pc EXCEPT ![self] = "getLoop"]
                               /\ UNCHANGED << getReq, getResp, clocksRead0,
                                               clocksWrite, clocksRead1,
                                               replicasWrite0, clientsRead,
                                               clientsWrite2 >>
                          ELSE /\ clocksRead0' = [clocksRead0 EXCEPT ![self] = logicalClocks]
                               /\ clocksWrite' = [clocksWrite EXCEPT ![self] = [logicalClocks EXCEPT ![clientId_'[self]] = (clocksRead0'[self][clientId_'[self]])+(1)]]
                               /\ clocksRead1' = [clocksRead1 EXCEPT ![self] = clocksWrite'[self]]
                               /\ getReq' = [getReq EXCEPT ![self] = <<GET_MSG, keyRead[self], clientId_'[self], clocksRead1'[self][clientId_'[self]]>>]
                               /\ \E dst \in ReplicaSet:
                                    /\ (Len(replicasNetwork[dst]))<(BUFFER_SIZE)
                                    /\ replicasWrite0' = [replicasWrite0 EXCEPT ![self] = [replicasNetwork EXCEPT ![dst] = Append(replicasNetwork[dst], getReq'[self])]]
                               /\ (Len(clientsNetwork[clientId_'[self]]))>(0)
                               /\ LET msg1 == Head(clientsNetwork[clientId_'[self]]) IN
                                    /\ clientsWrite2' = [clientsWrite2 EXCEPT ![self] = [clientsNetwork EXCEPT ![clientId_'[self]] = Tail(clientsNetwork[clientId_'[self]])]]
                                    /\ clientsRead' = [clientsRead EXCEPT ![self] = msg1]
                               /\ getResp' = [getResp EXCEPT ![self] = clientsRead'[self]]
                               /\ Assert(((getResp'[self])=(NULL))\/((getResp'[self])=(PUT_VALUE)),
                                         "Failure of assertion at line 825, column 25.")
                               /\ clocksWrite0' = [clocksWrite0 EXCEPT ![self] = clocksWrite'[self]]
                               /\ replicasWrite1' = [replicasWrite1 EXCEPT ![self] = replicasWrite0'[self]]
                               /\ clientsWrite3' = [clientsWrite3 EXCEPT ![self] = clientsWrite2'[self]]
                               /\ replicasNetwork' = replicasWrite1'[self]
                               /\ clientsNetwork' = clientsWrite3'[self]
                               /\ logicalClocks' = clocksWrite0'[self]
                               /\ pc' = [pc EXCEPT ![self] = "getLoop"]
                               /\ UNCHANGED continue_G
                    /\ UNCHANGED << db, x, busy, stack, domainStart, domainEnd,
                                    msg, i, nodesWrite, nodesWrite0,
                                    liveClients, pendingRequests,
                                    stableMessages, i_, firstPending,
                                    timestamp, nextClient, lowestPending,
                                    chooseMessage, currentClocks, minClock,
                                    continue_, pendingClients, clientsIter,
                                    msg_, key, val, mydb, requester, mainLoop,
                                    kvRead, replicasRead, replicasWrite,
                                    clientsWrite, clientsWrite0, kvWrite,
                                    kvWrite0, clientsWrite1, keyRead, i_G,
                                    keyRead0, continue_P, i_P, putReq, putResp,
                                    clientId_P, clocksRead2, clocksRead3,
                                    clocksWrite1, valueRead, clocksRead4,
                                    lockedWrite, clientsRead0, clientsWrite4,
                                    clientsWrite5, lockedWrite0, msg_D,
                                    clientId_D, lockedRead0, clocksWrite2,
                                    continue, i_C, msg_C, clientId,
                                    clocksRead5, clocksRead6, clocksWrite3,
                                    clocksRead7, clocksWrite4 >>

GetClient(self) == getLoop(self) \/ getRequest(self)

putLoop(self) == /\ pc[self] = "putLoop"
                 /\ IF continue_P[self]
                       THEN /\ clientId_P' = [clientId_P EXCEPT ![self] = (self)-((NUM_CLIENTS)*(PUT_ORDER))]
                            /\ pc' = [pc EXCEPT ![self] = "putRequest"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                            /\ UNCHANGED clientId_P
                 /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                 logicalClocks, x, busy, stack, domainStart,
                                 domainEnd, msg, i, nodesWrite, nodesWrite0,
                                 liveClients, pendingRequests, stableMessages,
                                 i_, firstPending, timestamp, nextClient,
                                 lowestPending, chooseMessage, currentClocks,
                                 minClock, continue_, pendingClients,
                                 clientsIter, msg_, key, val, mydb, requester,
                                 mainLoop, kvRead, replicasRead, replicasWrite,
                                 clientsWrite, clientsWrite0, kvWrite,
                                 kvWrite0, clientsWrite1, keyRead, continue_G,
                                 i_G, getReq, getResp, clientId_, lockedRead,
                                 clocksRead, clocksRead0, clocksWrite,
                                 clocksRead1, replicasWrite0, clientsRead,
                                 clientsWrite2, clocksWrite0, replicasWrite1,
                                 clientsWrite3, keyRead0, continue_P, i_P,
                                 putReq, putResp, clocksRead2, clocksRead3,
                                 clocksWrite1, valueRead, clocksRead4,
                                 lockedWrite, clientsRead0, clientsWrite4,
                                 clientsWrite5, lockedWrite0, msg_D,
                                 clientId_D, lockedRead0, clocksWrite2,
                                 continue, i_C, msg_C, clientId, clocksRead5,
                                 clocksRead6, clocksWrite3, clocksRead7,
                                 clocksWrite4 >>

putRequest(self) == /\ pc[self] = "putRequest"
                    /\ clocksRead2' = [clocksRead2 EXCEPT ![self] = logicalClocks]
                    /\ IF (clocksRead2'[self][clientId_P[self]])=(-(1))
                          THEN /\ continue_P' = [continue_P EXCEPT ![self] = FALSE]
                               /\ pc' = [pc EXCEPT ![self] = "putLoop"]
                               /\ UNCHANGED << logicalClocks, busy, stack,
                                               domainStart, domainEnd, msg, i,
                                               nodesWrite, nodesWrite0, i_P,
                                               putReq, clocksRead3,
                                               clocksWrite1, valueRead,
                                               clocksRead4, lockedWrite >>
                          ELSE /\ clocksRead3' = [clocksRead3 EXCEPT ![self] = logicalClocks]
                               /\ clocksWrite1' = [clocksWrite1 EXCEPT ![self] = [logicalClocks EXCEPT ![clientId_P[self]] = (clocksRead3'[self][clientId_P[self]])+(1)]]
                               /\ valueRead' = [valueRead EXCEPT ![self] = PUT_VALUE]
                               /\ clocksRead4' = [clocksRead4 EXCEPT ![self] = clocksWrite1'[self]]
                               /\ putReq' = [putReq EXCEPT ![self] = <<PUT_MSG, keyRead0[self], valueRead'[self], clientId_P[self], clocksRead4'[self][clientId_P[self]]>>]
                               /\ lockedWrite' = [lockedWrite EXCEPT ![self] = [busy EXCEPT ![clientId_P[self]] = TRUE]]
                               /\ i_P' = [i_P EXCEPT ![self] = 0]
                               /\ busy' = lockedWrite'[self]
                               /\ logicalClocks' = clocksWrite1'[self]
                               /\ /\ domainEnd' = [domainEnd EXCEPT ![self] = NUM_REPLICAS]
                                  /\ domainStart' = [domainStart EXCEPT ![self] = 1]
                                  /\ msg' = [msg EXCEPT ![self] = putReq'[self]]
                                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Broadcast0",
                                                                           pc        |->  "putResponse",
                                                                           i         |->  i[self],
                                                                           nodesWrite |->  nodesWrite[self],
                                                                           nodesWrite0 |->  nodesWrite0[self],
                                                                           domainStart |->  domainStart[self],
                                                                           domainEnd |->  domainEnd[self],
                                                                           msg       |->  msg[self] ] >>
                                                                       \o stack[self]]
                               /\ i' = [i EXCEPT ![self] = domainStart'[self]]
                               /\ nodesWrite' = [nodesWrite EXCEPT ![self] = defaultInitValue]
                               /\ nodesWrite0' = [nodesWrite0 EXCEPT ![self] = defaultInitValue]
                               /\ pc' = [pc EXCEPT ![self] = "loop"]
                               /\ UNCHANGED continue_P
                    /\ UNCHANGED << replicasNetwork, clientsNetwork, db, x,
                                    liveClients, pendingRequests,
                                    stableMessages, i_, firstPending,
                                    timestamp, nextClient, lowestPending,
                                    chooseMessage, currentClocks, minClock,
                                    continue_, pendingClients, clientsIter,
                                    msg_, key, val, mydb, requester, mainLoop,
                                    kvRead, replicasRead, replicasWrite,
                                    clientsWrite, clientsWrite0, kvWrite,
                                    kvWrite0, clientsWrite1, keyRead,
                                    continue_G, i_G, getReq, getResp,
                                    clientId_, lockedRead, clocksRead,
                                    clocksRead0, clocksWrite, clocksRead1,
                                    replicasWrite0, clientsRead, clientsWrite2,
                                    clocksWrite0, replicasWrite1,
                                    clientsWrite3, keyRead0, putResp,
                                    clientId_P, clientsRead0, clientsWrite4,
                                    clientsWrite5, lockedWrite0, msg_D,
                                    clientId_D, lockedRead0, clocksWrite2,
                                    continue, i_C, msg_C, clientId,
                                    clocksRead5, clocksRead6, clocksWrite3,
                                    clocksRead7, clocksWrite4 >>

putResponse(self) == /\ pc[self] = "putResponse"
                     /\ IF (i_P[self])<(Cardinality(ReplicaSet))
                           THEN /\ (Len(clientsNetwork[clientId_P[self]]))>(0)
                                /\ LET msg2 == Head(clientsNetwork[clientId_P[self]]) IN
                                     /\ clientsWrite4' = [clientsWrite4 EXCEPT ![self] = [clientsNetwork EXCEPT ![clientId_P[self]] = Tail(clientsNetwork[clientId_P[self]])]]
                                     /\ clientsRead0' = [clientsRead0 EXCEPT ![self] = msg2]
                                /\ putResp' = [putResp EXCEPT ![self] = clientsRead0'[self]]
                                /\ Assert((putResp'[self])=(OK_RESPONSE),
                                          "Failure of assertion at line 868, column 33.")
                                /\ i_P' = [i_P EXCEPT ![self] = (i_P[self])+(1)]
                                /\ clientsWrite5' = [clientsWrite5 EXCEPT ![self] = clientsWrite4'[self]]
                                /\ lockedWrite0' = [lockedWrite0 EXCEPT ![self] = busy]
                                /\ clientsNetwork' = clientsWrite5'[self]
                                /\ busy' = lockedWrite0'[self]
                                /\ pc' = [pc EXCEPT ![self] = "putResponse"]
                                /\ UNCHANGED lockedWrite
                           ELSE /\ lockedWrite' = [lockedWrite EXCEPT ![self] = [busy EXCEPT ![clientId_P[self]] = FALSE]]
                                /\ clientsWrite5' = [clientsWrite5 EXCEPT ![self] = clientsNetwork]
                                /\ lockedWrite0' = [lockedWrite0 EXCEPT ![self] = lockedWrite'[self]]
                                /\ clientsNetwork' = clientsWrite5'[self]
                                /\ busy' = lockedWrite0'[self]
                                /\ pc' = [pc EXCEPT ![self] = "putComplete"]
                                /\ UNCHANGED << i_P, putResp, clientsRead0,
                                                clientsWrite4 >>
                     /\ UNCHANGED << replicasNetwork, db, logicalClocks, x,
                                     stack, domainStart, domainEnd, msg, i,
                                     nodesWrite, nodesWrite0, liveClients,
                                     pendingRequests, stableMessages, i_,
                                     firstPending, timestamp, nextClient,
                                     lowestPending, chooseMessage,
                                     currentClocks, minClock, continue_,
                                     pendingClients, clientsIter, msg_, key,
                                     val, mydb, requester, mainLoop, kvRead,
                                     replicasRead, replicasWrite, clientsWrite,
                                     clientsWrite0, kvWrite, kvWrite0,
                                     clientsWrite1, keyRead, continue_G, i_G,
                                     getReq, getResp, clientId_, lockedRead,
                                     clocksRead, clocksRead0, clocksWrite,
                                     clocksRead1, replicasWrite0, clientsRead,
                                     clientsWrite2, clocksWrite0,
                                     replicasWrite1, clientsWrite3, keyRead0,
                                     continue_P, putReq, clientId_P,
                                     clocksRead2, clocksRead3, clocksWrite1,
                                     valueRead, clocksRead4, msg_D, clientId_D,
                                     lockedRead0, clocksWrite2, continue, i_C,
                                     msg_C, clientId, clocksRead5, clocksRead6,
                                     clocksWrite3, clocksRead7, clocksWrite4 >>

putComplete(self) == /\ pc[self] = "putComplete"
                     /\ pc' = [pc EXCEPT ![self] = "putLoop"]
                     /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                     logicalClocks, x, busy, stack,
                                     domainStart, domainEnd, msg, i,
                                     nodesWrite, nodesWrite0, liveClients,
                                     pendingRequests, stableMessages, i_,
                                     firstPending, timestamp, nextClient,
                                     lowestPending, chooseMessage,
                                     currentClocks, minClock, continue_,
                                     pendingClients, clientsIter, msg_, key,
                                     val, mydb, requester, mainLoop, kvRead,
                                     replicasRead, replicasWrite, clientsWrite,
                                     clientsWrite0, kvWrite, kvWrite0,
                                     clientsWrite1, keyRead, continue_G, i_G,
                                     getReq, getResp, clientId_, lockedRead,
                                     clocksRead, clocksRead0, clocksWrite,
                                     clocksRead1, replicasWrite0, clientsRead,
                                     clientsWrite2, clocksWrite0,
                                     replicasWrite1, clientsWrite3, keyRead0,
                                     continue_P, i_P, putReq, putResp,
                                     clientId_P, clocksRead2, clocksRead3,
                                     clocksWrite1, valueRead, clocksRead4,
                                     lockedWrite, clientsRead0, clientsWrite4,
                                     clientsWrite5, lockedWrite0, msg_D,
                                     clientId_D, lockedRead0, clocksWrite2,
                                     continue, i_C, msg_C, clientId,
                                     clocksRead5, clocksRead6, clocksWrite3,
                                     clocksRead7, clocksWrite4 >>

PutClient(self) == putLoop(self) \/ putRequest(self) \/ putResponse(self)
                      \/ putComplete(self)

sendDisconnectRequest(self) == /\ pc[self] = "sendDisconnectRequest"
                               /\ clientId_D' = [clientId_D EXCEPT ![self] = (self)-((NUM_CLIENTS)*(DISCONNECT_ORDER))]
                               /\ lockedRead0' = [lockedRead0 EXCEPT ![self] = busy]
                               /\ ~(lockedRead0'[self][clientId_D'[self]])
                               /\ msg_D' = [msg_D EXCEPT ![self] = <<DISCONNECT_MSG, clientId_D'[self]>>]
                               /\ clocksWrite2' = [clocksWrite2 EXCEPT ![self] = [logicalClocks EXCEPT ![clientId_D'[self]] = -(1)]]
                               /\ logicalClocks' = clocksWrite2'[self]
                               /\ /\ domainEnd' = [domainEnd EXCEPT ![self] = NUM_REPLICAS]
                                  /\ domainStart' = [domainStart EXCEPT ![self] = 1]
                                  /\ msg' = [msg EXCEPT ![self] = msg_D'[self]]
                                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Broadcast0",
                                                                           pc        |->  "Done",
                                                                           i         |->  i[self],
                                                                           nodesWrite |->  nodesWrite[self],
                                                                           nodesWrite0 |->  nodesWrite0[self],
                                                                           domainStart |->  domainStart[self],
                                                                           domainEnd |->  domainEnd[self],
                                                                           msg       |->  msg[self] ] >>
                                                                       \o stack[self]]
                               /\ i' = [i EXCEPT ![self] = domainStart'[self]]
                               /\ nodesWrite' = [nodesWrite EXCEPT ![self] = defaultInitValue]
                               /\ nodesWrite0' = [nodesWrite0 EXCEPT ![self] = defaultInitValue]
                               /\ pc' = [pc EXCEPT ![self] = "loop"]
                               /\ UNCHANGED << replicasNetwork, clientsNetwork,
                                               db, x, busy, liveClients,
                                               pendingRequests, stableMessages,
                                               i_, firstPending, timestamp,
                                               nextClient, lowestPending,
                                               chooseMessage, currentClocks,
                                               minClock, continue_,
                                               pendingClients, clientsIter,
                                               msg_, key, val, mydb, requester,
                                               mainLoop, kvRead, replicasRead,
                                               replicasWrite, clientsWrite,
                                               clientsWrite0, kvWrite,
                                               kvWrite0, clientsWrite1,
                                               keyRead, continue_G, i_G,
                                               getReq, getResp, clientId_,
                                               lockedRead, clocksRead,
                                               clocksRead0, clocksWrite,
                                               clocksRead1, replicasWrite0,
                                               clientsRead, clientsWrite2,
                                               clocksWrite0, replicasWrite1,
                                               clientsWrite3, keyRead0,
                                               continue_P, i_P, putReq,
                                               putResp, clientId_P,
                                               clocksRead2, clocksRead3,
                                               clocksWrite1, valueRead,
                                               clocksRead4, lockedWrite,
                                               clientsRead0, clientsWrite4,
                                               clientsWrite5, lockedWrite0,
                                               continue, i_C, msg_C, clientId,
                                               clocksRead5, clocksRead6,
                                               clocksWrite3, clocksRead7,
                                               clocksWrite4 >>

DisconnectClient(self) == sendDisconnectRequest(self)

clockUpdateLoop(self) == /\ pc[self] = "clockUpdateLoop"
                         /\ IF continue[self]
                               THEN /\ clientId' = [clientId EXCEPT ![self] = (self)-((NUM_CLIENTS)*(NULL_ORDER))]
                                    /\ clocksRead5' = [clocksRead5 EXCEPT ![self] = logicalClocks]
                                    /\ IF (clocksRead5'[self][clientId'[self]])=(-(1))
                                          THEN /\ continue' = [continue EXCEPT ![self] = FALSE]
                                               /\ clocksWrite4' = [clocksWrite4 EXCEPT ![self] = logicalClocks]
                                               /\ logicalClocks' = clocksWrite4'[self]
                                               /\ pc' = [pc EXCEPT ![self] = "clockUpdateLoop"]
                                               /\ UNCHANGED << stack,
                                                               domainStart,
                                                               domainEnd, msg,
                                                               i, nodesWrite,
                                                               nodesWrite0,
                                                               msg_C,
                                                               clocksRead6,
                                                               clocksWrite3,
                                                               clocksRead7 >>
                                          ELSE /\ clocksRead6' = [clocksRead6 EXCEPT ![self] = logicalClocks]
                                               /\ clocksWrite3' = [clocksWrite3 EXCEPT ![self] = [logicalClocks EXCEPT ![clientId'[self]] = (clocksRead6'[self][clientId'[self]])+(1)]]
                                               /\ clocksRead7' = [clocksRead7 EXCEPT ![self] = clocksWrite3'[self]]
                                               /\ msg_C' = [msg_C EXCEPT ![self] = <<NULL_MSG, clientId'[self], clocksRead7'[self][clientId'[self]]>>]
                                               /\ logicalClocks' = clocksWrite3'[self]
                                               /\ /\ domainEnd' = [domainEnd EXCEPT ![self] = NUM_REPLICAS]
                                                  /\ domainStart' = [domainStart EXCEPT ![self] = 1]
                                                  /\ msg' = [msg EXCEPT ![self] = msg_C'[self]]
                                                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Broadcast0",
                                                                                           pc        |->  "clockUpdateLoop",
                                                                                           i         |->  i[self],
                                                                                           nodesWrite |->  nodesWrite[self],
                                                                                           nodesWrite0 |->  nodesWrite0[self],
                                                                                           domainStart |->  domainStart[self],
                                                                                           domainEnd |->  domainEnd[self],
                                                                                           msg       |->  msg[self] ] >>
                                                                                       \o stack[self]]
                                               /\ i' = [i EXCEPT ![self] = domainStart'[self]]
                                               /\ nodesWrite' = [nodesWrite EXCEPT ![self] = defaultInitValue]
                                               /\ nodesWrite0' = [nodesWrite0 EXCEPT ![self] = defaultInitValue]
                                               /\ pc' = [pc EXCEPT ![self] = "loop"]
                                               /\ UNCHANGED << continue,
                                                               clocksWrite4 >>
                               ELSE /\ logicalClocks' = clocksWrite4[self]
                                    /\ pc' = [pc EXCEPT ![self] = "Done"]
                                    /\ UNCHANGED << stack, domainStart,
                                                    domainEnd, msg, i,
                                                    nodesWrite, nodesWrite0,
                                                    continue, msg_C, clientId,
                                                    clocksRead5, clocksRead6,
                                                    clocksWrite3, clocksRead7,
                                                    clocksWrite4 >>
                         /\ UNCHANGED << replicasNetwork, clientsNetwork, db,
                                         x, busy, liveClients, pendingRequests,
                                         stableMessages, i_, firstPending,
                                         timestamp, nextClient, lowestPending,
                                         chooseMessage, currentClocks,
                                         minClock, continue_, pendingClients,
                                         clientsIter, msg_, key, val, mydb,
                                         requester, mainLoop, kvRead,
                                         replicasRead, replicasWrite,
                                         clientsWrite, clientsWrite0, kvWrite,
                                         kvWrite0, clientsWrite1, keyRead,
                                         continue_G, i_G, getReq, getResp,
                                         clientId_, lockedRead, clocksRead,
                                         clocksRead0, clocksWrite, clocksRead1,
                                         replicasWrite0, clientsRead,
                                         clientsWrite2, clocksWrite0,
                                         replicasWrite1, clientsWrite3,
                                         keyRead0, continue_P, i_P, putReq,
                                         putResp, clientId_P, clocksRead2,
                                         clocksRead3, clocksWrite1, valueRead,
                                         clocksRead4, lockedWrite,
                                         clientsRead0, clientsWrite4,
                                         clientsWrite5, lockedWrite0, msg_D,
                                         clientId_D, lockedRead0, clocksWrite2,
                                         i_C >>

ClockUpdateClient(self) == clockUpdateLoop(self)

Next == (\E self \in ProcSet: Broadcast0(self))
           \/ (\E self \in ReplicaSet: Replica(self))
           \/ (\E self \in GetSet: GetClient(self))
           \/ (\E self \in PutSet: PutClient(self))
           \/ (\E self \in DisconnectSet: DisconnectClient(self))
           \/ (\E self \in NullSet: ClockUpdateClient(self))
           \/ (* Disjunct to prevent deadlock on termination *)
              ((\A self \in ProcSet: pc[self] = "Done") /\ UNCHANGED vars)

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in ReplicaSet : WF_vars(Replica(self))
        /\ \A self \in GetSet : WF_vars(GetClient(self))
        /\ \A self \in PutSet : WF_vars(PutClient(self)) /\ WF_vars(Broadcast0(self))
        /\ \A self \in DisconnectSet : WF_vars(DisconnectClient(self)) /\ WF_vars(Broadcast0(self))
        /\ \A self \in NullSet : WF_vars(ClockUpdateClient(self)) /\ WF_vars(Broadcast0(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

\* This predicate is true when all client processes are finished.
AllClientsDisconnected == LET allClients == GetSet \cup PutSet \cup DisconnectSet \cup NullSet
                          IN
                             \A client \in allClients : pc[client] = "Done"


\* The Timestamp operator extracts the logical clock associated with a GET or PUT message
Timestamp(message) == CASE message[1] = GET_MSG -> message[4]
                        [] message[1] = PUT_MSG -> message[5]
                        [] TRUE             -> Assert(FALSE, "Cannot extract timestamp")


\* Invariants
\* **********

\* These ensure that, in all states explored by TLC, the buffers (from client to replica and vice versa)
\* are within bounds. Using the FIFOChannel mapping macro is sufficient for this invariant to
\* hold.
BufferOk(net, node) == Len(net[node]) >= 0 /\ Len(net[node]) <= BUFFER_SIZE
ClientBuffersOk == \A node \in DOMAIN clientsNetwork : BufferOk(clientsNetwork, node)
ReplicaBuffersOk == \A node \in DOMAIN replicasNetwork : BufferOk(replicasNetwork, node)
AllBuffersOk == ClientBuffersOk /\ ReplicaBuffersOk

\* This invariant tests that message stability detection in the replica is safe:
\* every message considered stable must have a timestamp lower than the current logical
\* clock of any live client.
MessageStability == \A replica \in ReplicaSet :
                        LET stable == stableMessages[replica]
                            alive == { c \in ClientSet : logicalClocks[c] > 0 }
                        IN
                            Len(stable) > 0 =>
                                \A m_id \in DOMAIN stable :
                                    \A client \in alive : Timestamp(stable[m_id]) < logicalClocks[client]


\* Put semantics: once a client has been notified that a Put request was succesful
\* every replica must have the updated value.
PersistentPut == \A client \in PutSet :
                     pc[client] = "putComplete" => \A replica \in ReplicaSet : db[replica][PUT_KEY] = PUT_VALUE


\* Properties
\* **********

\* Logical clocks are monotonically increasing. This property checks that in every state,
\* pending messages in the replicas have increasing timestamps (or the process disconnected)
ClockIncreased == logicalClocks' /= logicalClocks =>
                 \E c \in ClientSet : logicalClocks'[c] = logicalClocks[c]+1 \/ logicalClocks'[c] = -1

MonotonicallyIncreasingClocks == [][ClockIncreased]_<<logicalClocks>>


\* Safety of disconnection: once a client has disconnected (and sent a message to all replicas
\* informing of that event), then the logical clock of that client should remain
\* unchanced -- i.e., no more messages from that client should be seen in the system.
DisconnectionSafe == \A client \in ClientSet : <>[](logicalClocks[client] = -1)

=============================================================================
\* Modification History
\* Last modified Wed Feb 06 12:42:07 PST 2019 by rmc

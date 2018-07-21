# Raft

A library implementing the Raft distributed consensus algorithm. The algorithm
itself is implemented as a single function in a simple Reader-Writer-State-ish
monad transformer. The base monad can be specified by the user, and doesn't have
to be `IO`.

The function signature is as follows
```haskell
handleMessage :: MonadLogger m => Message a -> ExtServerT a m [Message a]
```

Roughly, this says that the function takes a `Message` and returns an
`ExtServerT`, which is a monad that holds the state of the node. By threading
multiple calls to `handleMessage` together, the state of the node can be
evolved. From the outside, the _only_ way to modify the state of a node is by
passing it a `Message` via `handleMessage`.

The `Message` type is as follows
```haskell
data Message a b =
    AppendEntriesReq ServerId ServerId (AppendEntries a)
  | AppendEntriesRes ServerId ServerId (Term, Bool)
  | RequestVoteReq ServerId ServerId (RequestVote a)
  | RequestVoteRes ServerId ServerId (Term, Bool)
  | Tick ServerId
  | ClientRequest ServerId RequestId a
  | ClientResponse ServerId RequestId (Either T.Text b)
```

That is, an ADT with a variant for each RPC request and response, client
requests and responses (e.g. read this value, write this value) and a final
variant called `Tick`, which represents a change in time. Because the
implementation is entirely pure, the evolution of time must be communicated to
the node via a message. This makes it possible to test all sorts of different
time-based scenarios, such as slow clocks, out of sync clocks, network latency,
etc.

## Implemented features
- A working implementation of the core algorithm (log replication and leader
  election).
- Unit tests for the behaviour of nodes in response to the two RPC calls.
- A basic integration test of a three-node cluster, with simulated clocks.
- A prototype implementation over HTTP
  - Clients can send read/write requests and receive responses

## Planned features
- Unit tests for all node behaviours (the "Rules for Servers" section on page 4
  of the Raft paper).
- Full support for client requests
  - Request redirection from non-leaders to leader
  - Full support for the client RPCs described in the Raft thesis
- Membership changes
- Tests for common failure scenarios
- Randomised tests for edge case failure scenarios

## Potential future features
- Persistence
- Log compaction
- Linearizability
- Performance tests

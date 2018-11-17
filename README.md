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
    AEReq (AppendEntriesReq a)
  | AERes AppendEntriesRes
  | RVReq RequestVoteReq
  | RVRes RequestVoteRes
  | CReq (ClientReq a)
  | CRes (ClientRes b)
  | Tick
```

That is, an ADT with a variant for each RPC request and response, client
requests and responses and a final variant called `Tick`, which represents a
change in time. Because the implementation is entirely pure, the evolution of
time must be communicated to the node via a message. This makes it possible to
test all sorts of different time-based scenarios, such as slow clocks, out of
sync clocks, network latency, etc.

`Message` is parameterised over two types `a` and `b` representing the type of
state machine commands and return values, respectively.

## Implemented features
- A working implementation of the core algorithm (log replication and leader
  election).
- Unit tests for all node behaviours and the `AppendEntries` and `RequestVote`
  RPC calls.
- A basic integration test of a three-node cluster, with simulated clocks.
- An implementation using HTTP transport
  - Clients can send read/write requests and receive responses
  - Request redirection from non-leaders to leader

## Planned features
- Membership changes
- Tests for common failure scenarios
- Randomised tests for edge case failure scenarios

## Potential future features
- Persistence
- Log compaction
- Linearizability
- Performance tests

# Try it out

There's an example app that uses HTTP as the transport and a HashMap as the
state machine.  You'll need [Stack](https://haskellstack.org) installed to run
it.

Build the project
```shell
stack build
```

Start three nodes, each in their own shell:
```shell
stack exec http server localhost:10501 ./example-config.dhall
stack exec http server localhost:10502 ./example-config.dhall
stack exec http server localhost:10503 ./example-config.dhall
```

Set a value on the state machine
```shell
stack exec http client localhost:10501 set name harry
```

Read it back
```shell
stack exec http client localhost:10501 get name
```

--

# Membership Changes

Raft supports cluster membership changes by storing cluster configuration in the log
itself, and ensures that nodes can be safely added to the cluster one at a time.

To support this, a cluster is constructed by booting each node one at a time and adding
each to the cluster separately. The process works roughly like this:

1. Node 1 is booted, forms a cluster of one, and quickly becomes leader.
2. Node 2 is booted in "bootstrap mode". In this mode it requires at least two votes to
   become leader. It will therefore not form a cluster of one but will instead stay in
   follower mode.
3. The AddServer RPC call is used to initiate the addition of node 2 to the node 1
   cluster.
4. Node 1 begins replicating log entries to node 2 until it is up to date. This will be a
   no-op for a new cluster.
5. Node 2 writes a new cluster configuration to the log, specifying the cluster nodes to
   be {1, 2}.
6. Once it is written to the log, this configuration immediately takes effect for node 1.
   At this point, node 2 is considered a full member of the cluster (by node 1, at least).
7. The new configuration is replicated to node 2, and takes effect immediately. The
   presence of a new configuration causes node 2 to exit bootstrap mode and begin
   operation as a normal node. At this point, node 2 is considered a full member of the
   cluster by all nodes.
8. The AddServer RPC call returns successfully.

In order to support this, we provide no initial cluster configuration to nodes when they
boot. All they know is their own network address - any further configuration is discovered
dynamically when they receive RPCs from the cluster leader. The only boot-time
configuration is bootstrap mode, which is used for every new node except for the initial
one.

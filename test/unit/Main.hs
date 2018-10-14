{-# LANGUAGE DuplicateRecordFields #-}

import Control.Monad.Identity
import Control.Monad.Logger
import Control.Monad.State.Strict

import Data.Maybe (fromJust)

import qualified Data.HashMap.Strict as Map
import Raft
import Raft.Lens hiding (apply)
import Raft.Log
import Raft.Rpc
import Raft.Server hiding (apply, mkServerState)
import qualified Raft.Server (mkServerState)

import Test.Hspec

data Command =
    NoOp
  | Set Int
  deriving (Eq, Show)
type Response = ()

newtype StateMachine = StateMachine { value :: Int }
  deriving (Eq, Show)

type StateMachineM = StateT StateMachine (NoLoggingT Identity)

apply :: Command -> StateMachineM ()
apply _ = return ()

sendMsg :: ServerState Command () StateMachineM -> Message Command Response -> ([Message Command Response], ServerState Command () StateMachineM)
sendMsg server msgIn = (msgs, server')
  where ((msgs, server'), _machine) = runIdentity $ runNoLoggingT $ runStateT (runStateT (handleMessage msgIn) server) emptyStateMachine
        emptyStateMachine = StateMachine { value = 0 }

main :: IO ()
main = hspec $ do
  testElectionTimeout
  testHeartbeatTimeout
  testAppendEntriesReq
  testRequestVoteReq
  testRequestVoteRes
  testAppendEntriesRes
  testAddServerReq

mkLogEntry :: LogIndex -> Term -> LogEntry Command
mkLogEntry i t = LogEntry { _index = i
                          , _term = t
                          , _command = NoOp
                          , _requestId = 0 }

mkServerState :: ServerId -> [ServerId] -> Int -> MonotonicCounter -> ServerState Command () StateMachineM
mkServerState self others electionTimeout heartbeatTimeout =
  Raft.Server.mkServerState self others (electionTimeout, electionTimeout, 0) heartbeatTimeout NoOp apply

s1 :: ServerId
s1 = ServerId "http://localhost:10501"

s2 :: ServerId
s2 = ServerId "http://localhost:10502"

s3 :: ServerId
s3 = ServerId "http://localhost:10503"

testElectionTimeout :: Spec
testElectionTimeout = do
  let mkNode timeout = mkServerState s1 [s2] timeout 10
  context "when a node has not reached its election timeout" $
    it "doesn't call an election" $ do
      let timeout = 2
      case sendMsg (mkNode 2) Tick of
        (msgs, _) -> msgs `shouldBe` []
  context "when a node reaches its election timeout" $
    it "calls an election" $ do
      let timeout = 1
          ([RVReq rpc], node') = sendMsg (mkNode timeout) Tick
      rpc^.from `shouldBe` s1
      rpc^.to `shouldBe` s2
      rpc^.candidateTerm `shouldBe` 1
      rpc^.lastLogIndex `shouldBe` 0
      rpc^.lastLogTerm `shouldBe` 0

      node'^.serverTerm `shouldBe` 1
      node'^.role `shouldBe` Candidate
      node'^.votedFor `shouldBe` Just s1
      node'^.votesReceived `shouldBe` 1
      node'^.electionTimer `shouldBe` 0

testHeartbeatTimeout :: Spec
testHeartbeatTimeout = do
  let mkNode timeout = mkServerState s1 [s2] 10 timeout
  context "when a node is not a leader" $
    it "does not send heartbeats" $ do
      let node = (mkNode 1) { _role = Follower }
      case sendMsg node Tick of
        (msgs, _) -> msgs `shouldBe`[]
  context "when a node is a leader but has not reached its heartbeat timeout" $
    it "does not send heartbeats" $ do
      let node = (mkNode 2) { _role = Leader }
      case sendMsg node Tick of
        (msgs, _) -> msgs `shouldBe`[]
  context "when a node is a leader and has reached its heartbeat timeout" $
    it "sends a heartbeat to each server" $ do
      let node = (mkNode 1) { _role = Leader }
          ([msg], _) = sendMsg node Tick
      case msg of
        AEReq rpc -> do
          rpc ^. from `shouldBe` s1
          rpc ^. to `shouldBe` s2
          rpc ^. leaderTerm `shouldBe` 0
          rpc ^. prevLogIndex `shouldBe` 0
          rpc ^. prevLogTerm `shouldBe` 0
          rpc ^. entries `shouldBe` []
          rpc ^. leaderCommit `shouldBe` 0
        _ -> error "unexpected response"

testAppendEntriesReq :: Spec
testAppendEntriesReq = do
  let mkNode = mkServerState s1 [s2] 10 10
  context "when the message's term is less than the node's term" $ do
    let node = mkNode { _serverTerm = 2 }
        appendEntriesPayload = AppendEntriesReq { _from = s2
                                                , _to = s1
                                                , _leaderTerm = 1
                                                , _prevLogIndex = 0
                                                , _prevLogTerm = 0
                                                , _entries = []
                                                , _leaderCommit = 0 }
    let req = AEReq appendEntriesPayload
    it "replies with false" $
      case sendMsg node req of
        (msgs, _) -> do
          length msgs `shouldBe` 1
          let (AERes rpc) = head msgs
          rpc^.from `shouldBe` s1
          rpc^.to `shouldBe` s2
          rpc^.term `shouldBe` 2
          rpc^.success `shouldBe` False
          rpc^.logIndex `shouldBe` 0
  context "when the log doesn't contain an entry at prevLogIndex whose term matches prevLogTerm" $ do
    let node = mkNode
        appendEntriesPayload = AppendEntriesReq { _leaderTerm = 1
                                                , _from = s2
                                                , _to = s1
                                                , _prevLogIndex = 0
                                                , _prevLogTerm = 3
                                                , _entries = []
                                                , _leaderCommit = 0 }
        req = AEReq appendEntriesPayload
    it "replies with false" $
      case sendMsg node req of
        (msgs, _) -> do
          length msgs `shouldBe` 1
          let (AERes rpc) = head msgs
          rpc^.from `shouldBe` s1
          rpc^.to `shouldBe` s2
          rpc^.success `shouldBe` False
          rpc^.term `shouldBe` 1
          rpc^.logIndex `shouldBe` 0
  context "when the log contains a conflicting entry" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
        thirdEntry = mkLogEntry 1 3
        mkAppendEntries prevIndex es
          = AEReq AppendEntriesReq { _leaderTerm = 1
                                   , _from = s2
                                   , _to = s1
                                   , _prevLogIndex = prevIndex
                                   , _prevLogTerm = 0
                                   , _entries = es
                                   , _leaderCommit = 0 }
        req1 = mkAppendEntries 0 [firstEntry, secondEntry]
        req2 = mkAppendEntries 0 [thirdEntry]
    it "deletes the entry and all that follow it" $ do
      let (msgs, node') = sendMsg mkNode req1
      node'^.entryLog `shouldBe` [zerothEntry, firstEntry, secondEntry]
      length msgs `shouldBe` 1
      let (AERes rpc) = head msgs
      rpc^.from `shouldBe` s1
      rpc^.to `shouldBe` s2
      rpc^.term `shouldBe` 1
      rpc^.success `shouldBe` True
      rpc^.logIndex `shouldBe` 2
      case sendMsg node' req2 of
        (_, node'') -> node''^.entryLog `shouldBe` [zerothEntry, thirdEntry]
  context "when the log contains a valid entry" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        mkAppendEntries prevIndex es
          = AEReq AppendEntriesReq { _leaderTerm = 1
                                   , _from = s2
                                   , _to = s1
                                   , _prevLogIndex = prevIndex
                                   , _prevLogTerm = 0
                                   , _entries = es
                                   , _leaderCommit = 0 }
        req = mkAppendEntries 0 [firstEntry]
    it "appends it to the log" $
      case sendMsg mkNode req of
        (msgs, node') -> do
          length msgs `shouldBe` 1
          let (AERes rpc) = head msgs
          rpc^.from `shouldBe` s1
          rpc^.to `shouldBe` s2
          rpc^.term `shouldBe` 1
          rpc^.success `shouldBe` True
          rpc^.logIndex `shouldBe` 1
          node'^.entryLog `shouldBe` [zerothEntry, firstEntry]
  context "when leaderCommit > node's commitIndex" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
    context "and leaderCommit <= index of last new entry" $ do
      let req = AEReq AppendEntriesReq { _leaderTerm = 1
                                       , _from = s2
                                       , _to = s1
                                       , _prevLogIndex = 0
                                       , _prevLogTerm = 0
                                       , _entries = [firstEntry, secondEntry]
                                       , _leaderCommit = 1 }
      it "sets commitIndex = leaderCommit" $
        case sendMsg mkNode req of
          (msgs, node') -> do
            length msgs `shouldBe` 1
            let (AERes rpc) = head msgs
            rpc^.from `shouldBe` s1
            rpc^.to `shouldBe` s2
            rpc^.term `shouldBe` 1
            rpc^.success `shouldBe` True
            rpc^.logIndex `shouldBe` 2
            node'^.commitIndex `shouldBe` 1
    context "and leaderCommit > index of last new entry" $ do
      let req = AEReq AppendEntriesReq { _leaderTerm = 1
                                       , _from = s2
                                       , _to = s1
                                       , _prevLogIndex = 0
                                       , _prevLogTerm = 0
                                       , _entries = [firstEntry, secondEntry]
                                       , _leaderCommit = 3 }
      it "sets commitIndex = index of last new entry" $
        case sendMsg mkNode req of
          (msgs, node') -> do
            length msgs `shouldBe` 1
            let (AERes rpc) = head msgs
            rpc^.from `shouldBe` s1
            rpc^.to `shouldBe` s2
            rpc^.term `shouldBe` 1
            rpc^.success `shouldBe` True
            rpc^.logIndex `shouldBe` 2
            node'^.commitIndex `shouldBe` 2
  context "when leaderCommit <= node's commitIndex" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
        req = AEReq AppendEntriesReq { _leaderTerm = 1
                                     , _from = s2
                                     , _to = s1
                                     , _prevLogIndex = 0
                                     , _prevLogTerm = 0
                                     , _entries = [firstEntry, secondEntry]
                                     , _leaderCommit = 0 }
        res = sendMsg mkNode req
    it "does not modify commitIndex" $
      case res of
        (msgs, node') -> do
          length msgs `shouldBe` 1
          let (AERes rpc) = head msgs
          rpc^.from `shouldBe` s1
          rpc^.to `shouldBe` s2
          rpc^.term `shouldBe` 1
          rpc^.success `shouldBe` True
          rpc^.logIndex `shouldBe` 2
          node'^.commitIndex `shouldBe` 0

testAppendEntriesRes :: Spec
testAppendEntriesRes = do
  let (_, node_) = sendMsg (mkServerState s1 [s2] 0 10) Tick -- trigger election
  let (_, node) = sendMsg node_ (RVRes RequestVoteRes { _from = s2
                                                      , _to = s1
                                                      , _voterTerm = 0
                                                      , _requestVoteSuccess = True
                                                      }) -- grant vote
  context "intially" $ do
    it "should be leader" $ do
      node^.role `shouldBe` Leader
    it "should have nextIndex set to last log index + 1" $ do
      node^.nextIndex `shouldBe` Map.fromList [(s2, 1)]
  context "if successful" $ do
    let (msgs, node') = sendMsg node (AERes AppendEntriesRes { _from = s2
                                                             , _to = s1
                                                             , _term = 0
                                                             , _success = True
                                                             , _logIndex = 1
                                                             } )
    it "sends no RPCs in response" $
      msgs `shouldBe` []
    it "updates nextIndex" $ do
      node'^.nextIndex `shouldBe` Map.fromList [(s2, 2)]



-- TODO: test case where there are 3 nodes, but log is only committed on leader
-- + 1 node. Leader should NOT apply log to statemachine

testRequestVoteReq :: Spec
testRequestVoteReq = do
  let mkNode = mkServerState s1 [s2] 10 10
      req cTerm lTerm lIndex = RVReq RequestVoteReq { _candidateTerm = cTerm
                                                    , _from = s2
                                                    , _to = s1
                                                    , _lastLogIndex = lIndex
                                                    , _lastLogTerm = lTerm }
  context "if candidate's term < currentTerm" $ do
    let node = mkNode { _serverTerm = 2 }
    let ([RVRes rpc], _) = sendMsg node (req 1 0 0)
    it "replies false" $ do
      rpc^.from `shouldBe` s1
      rpc^.to `shouldBe` s2
      rpc^.voterTerm `shouldBe` 2
      rpc^.requestVoteSuccess `shouldBe` False
  context "if votedFor = Nothing" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Nothing }
    let ([RVRes rpc], _) = sendMsg node (req 1 0 0)
    context "and candidate's log is as up-to-date as receiver's log" $
      it "grants vote" $ do
        rpc^.from `shouldBe` s1
        rpc^.to `shouldBe` s2
        rpc^.voterTerm `shouldBe` 1
        rpc^.requestVoteSuccess `shouldBe` True
    context "and candidate's log is more up-to-date than receiver's log" $ do
      let ([RVRes rpc], _) = sendMsg node (req 2 2 2)
      it "grants vote" $ do
        rpc^.from `shouldBe` s1
        rpc^.to `shouldBe` s2
        rpc^.voterTerm `shouldBe` 2
        rpc^.requestVoteSuccess `shouldBe` True
    context "and candidate's log is not as up-to-date as receiver's log" $ do
      let zerothEntry = mkLogEntry 0 0
          firstEntry = mkLogEntry 1 1
          node' = node { _serverTerm = 1, _entryLog = [zerothEntry, firstEntry] }
          ([RVRes rpc], _) = sendMsg node' (req 1 0 0)
      it "does not grant vote but still updates term" $ do
        rpc^.from `shouldBe` s1
        rpc^.to `shouldBe` s2
        rpc^.voterTerm `shouldBe` 1
        rpc^.requestVoteSuccess `shouldBe` False
  context "if votedFor = candidateId" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Just s2 }
    context "and candidate's log is as up-to-date as receiver's log" $ do
      let ([RVRes rpc], _) = sendMsg node (req 1 0 0)
      it "grants vote" $ do
        rpc^.from `shouldBe`s1
        rpc^.to `shouldBe` s2
        rpc^.voterTerm `shouldBe` 1
        rpc^.requestVoteSuccess `shouldBe` True
    context "and candidate's log is more up-to-date than receiver's log" $ do
      let ([RVRes rpc], _) = sendMsg node (req 2 2 2)
      it "grants vote" $ do
        rpc^.from `shouldBe` s1
        rpc^.to `shouldBe` s2
        rpc^.voterTerm `shouldBe` 2
        rpc^.requestVoteSuccess `shouldBe` True
    context "and candidate's log is not as up-to-date as receiver's log" $ do
      let zerothEntry = mkLogEntry 0 0
          firstEntry = mkLogEntry 1 1
          node' = node { _serverTerm = 1, _entryLog = [zerothEntry, firstEntry] }
      it "does not grant vote but still updates term" $ do
        let ([RVRes rpc], _) = sendMsg node' (req 1 0 0)
        rpc^.from `shouldBe` s1
        rpc^.to `shouldBe` s2
        rpc^.voterTerm `shouldBe` 1
        rpc^.requestVoteSuccess `shouldBe` False
  context "if votedFor = some other candidate id" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Just s3 }
    it "does not grant vote but still updates term" $ do
      let ([RVRes rpc], _) = sendMsg node (req 1 0 0)
      rpc^.from `shouldBe` s1
      rpc^.to `shouldBe` s2
      rpc^.voterTerm `shouldBe` 1
      rpc^.requestVoteSuccess `shouldBe` False

testRequestVoteRes :: Spec
testRequestVoteRes = do
  let (_, node) = sendMsg (mkServerState s1 [s2, s3] 0 10) Tick

  -- this just ensures that the followup tests assume the correct initial state
  context "for a server that has converted to candidate" $
    it "should have voted for itself" $ do
      node^.votedFor `shouldBe` Just s1
      node^.votesReceived `shouldBe` 1
      node^.role `shouldBe` Candidate

  context "when vote has been granted" $ do
    let msg = RVRes RequestVoteRes { _from = s2
                                   , _to = s1
                                   , _voterTerm = 1
                                   , _requestVoteSuccess = True
                                   }
        (msgs, node') = sendMsg node msg
    it "increments votesReceived" $ do
      node'^.votesReceived `shouldBe` 2

    context "if vote grant results in a majority" $ do
      let (_, node) = sendMsg (mkServerState s1 [s2] 0 10) Tick
          (msgs, node') = sendMsg node msg
      it "converts to leader" $ do
        node'^.role `shouldBe` Leader
        node'^.electionTimer `shouldBe` 0
        node'^.nextIndex `shouldBe` Map.fromList [(s2, 1)]

      it "sends AppendEntries RPCs to all other servers" $
        msgs `shouldBe` [AEReq AppendEntriesReq { _leaderTerm = 1
                                                , _from = s1
                                                , _to = s2
                                                , _prevLogIndex = 0
                                                , _prevLogTerm = 0
                                                , _entries = []
                                                , _leaderCommit = 0
                                                }]

testAddServerReq :: Spec
testAddServerReq = do
  let (_, node) = sendMsg (mkServerState s1 [s2, s3] 0 10) Tick
  let newServerId = ServerId "the-new-server"

  context "when AddServer RPC is sent" $ do
    let msg = ASReq AddServerReq { _newServer = newServerId }
        (msgs, node') = sendMsg node msg
    it "starts a server addition" $ do
      let addition = fromJust $ node'^.serverAddition
      addition^.newServer `shouldBe` newServerId
      addition^.maxRounds `shouldBe` 10
      addition^.currentRound `shouldBe` 1
      addition^.roundIndex `shouldBe` 0
      addition^.roundTimer `shouldBe` MonotonicCounter 0
    it "sends an AppendEntriesReq to the new server" $ do
      length msgs `shouldBe` 1
      let [AEReq rpc] = msgs
      rpc^.from `shouldBe` node'^.selfId
      rpc^.to `shouldBe` newServerId
      length (rpc^.entries) `shouldBe` 1

-- TODO:
-- - test that rounds are incremented
-- - test that sufficient catchup is detected
-- - test that round exhaustion is detected

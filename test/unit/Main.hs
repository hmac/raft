import           Control.Lens
import           Control.Monad.Logger
import           Control.Monad.State.Strict

import           Raft
import           Raft.Log
import           Raft.Rpc
import           Raft.Server                hiding (apply, mkServerState)
import qualified Raft.Server                (mkServerState)

import           Test.Hspec

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
  testAppendEntries
  testRequestVote

mkLogEntry :: LogIndex -> Term -> LogEntry Command
mkLogEntry i t = LogEntry { _Index = i, _Term = t, _Command = NoOp, _RequestId = 0 }

mkServerState :: ServerId -> [ServerId] -> (Int, Int, Int) -> MonotonicCounter -> ServerState Command () StateMachineM
mkServerState self others electionTimeout heartbeatTimeout =
  Raft.Server.mkServerState self others electionTimeout heartbeatTimeout NoOp apply

testElectionTimeout :: Spec
testElectionTimeout = do
  let mkNode timeout = mkServerState 0 [1] timeout 10
  context "when a node has not reached its election timeout" $
    it "doesn't call an election" $ do
      let timeout = (2, 2, 0)
      case sendMsg (mkNode timeout) (Tick 0) of
        (msgs, _) -> msgs `shouldBe` []
  context "when a node reaches its election timeout" $
    it "calls an election" $ do
      let timeout = (1, 1, 0)
          (msgs, _) = sendMsg (mkNode timeout) (Tick 0)
      case msgs of
        [RequestVoteReq from to rpc] -> do
          from `shouldBe` 0
          to `shouldBe` 1
          rpc ^. candidateTerm `shouldBe` 1
          rpc ^. candidateId `shouldBe` 0
          rpc ^. lastLogIndex `shouldBe` 0
          rpc ^. lastLogTerm `shouldBe` 0
        _ -> error "unexpected response"

testHeartbeatTimeout :: Spec
testHeartbeatTimeout = do
  let mkNode timeout = mkServerState 0 [1] (10, 10, 0) timeout
  context "when a node is not a leader" $
    it "does not send heartbeats" $ do
      let node = (mkNode 1) { _role = Follower }
      case sendMsg node (Tick 0) of
        (msgs, _) -> msgs `shouldBe`[]
  context "when a node is a leader but has not reached its heartbeat timeout" $
    it "does not send heartbeats" $ do
      let node = (mkNode 2) { _role = Leader }
      case sendMsg node (Tick 0) of
        (msgs, _) -> msgs `shouldBe`[]
  context "when a node is a leader and has reached its heartbeat timeout" $
    it "sends a heartbeat to each server" $ do
      let node = (mkNode 1) { _role = Leader }
          ([msg], _) = sendMsg node (Tick 1)
      case msg of
        AppendEntriesReq 0 1 rpc -> do
          rpc ^. leaderTerm `shouldBe` 0
          rpc ^. leaderId `shouldBe` 0
          rpc ^. prevLogIndex `shouldBe` 0
          rpc ^. prevLogTerm `shouldBe` 0
          rpc ^. entries `shouldBe` []
          rpc ^. leaderCommit `shouldBe` 0
        _ -> error "unexpected response"

testAppendEntries :: Spec
testAppendEntries = do
  let mkNode = mkServerState 0 [1] (10, 10, 0) 10
  context "when the message's term is less than the node's term" $ do
    let node = mkNode { _serverTerm = 2 }
        appendEntriesPayload = AppendEntries { _LeaderTerm = 1
                                             , _LeaderId = 1
                                             , _PrevLogIndex = 0
                                             , _PrevLogTerm = 0
                                             , _Entries = []
                                             , _LeaderCommit = 0 }
    let req = AppendEntriesReq 1 0 appendEntriesPayload
    it "replies with false" $
      case sendMsg node req of
        (msgs, _) -> msgs `shouldBe` [AppendEntriesRes 0 1 (2, False)]
  context "when the log doesn't contain an entry at prevLogIndex whose term matches prevLogTerm" $ do
    let node = mkNode
        appendEntriesPayload = AppendEntries { _LeaderTerm = 1
                                             , _LeaderId = 1
                                             , _PrevLogIndex = 0
                                             , _PrevLogTerm = 3
                                             , _Entries = []
                                             , _LeaderCommit = 0 }
        req = AppendEntriesReq 1 0 appendEntriesPayload
    it "replies with false" $
      case sendMsg node req of
        (msgs, _) -> msgs `shouldBe` [AppendEntriesRes 0 1 (0, False)]
  context "when the log contains a conflicting entry" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
        thirdEntry = mkLogEntry 1 3
        mkAppendEntries prevIndex es
          = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                               , _LeaderId = 1
                                               , _PrevLogIndex = prevIndex
                                               , _PrevLogTerm = 0
                                               , _Entries = es
                                               , _LeaderCommit = 0 }
        req1 = mkAppendEntries 0 [firstEntry, secondEntry]
        req2 = mkAppendEntries 0 [thirdEntry]
    it "deletes the entry and all that follow it" $ do
      let (msgs, node') = sendMsg mkNode req1
      node'^.entryLog `shouldBe` [zerothEntry, firstEntry, secondEntry]
      msgs `shouldBe` [AppendEntriesRes 0 1 (1, True)]
      case sendMsg node' req2 of
        (_, node'') -> node''^.entryLog `shouldBe` [zerothEntry, thirdEntry]
  context "when the log contains a valid entry" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        mkAppendEntries prevIndex es
          = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                               , _LeaderId = 1
                                               , _PrevLogIndex = prevIndex
                                               , _PrevLogTerm = 0
                                               , _Entries = es
                                               , _LeaderCommit = 0 }
        req = mkAppendEntries 0 [firstEntry]
    it "appends it to the log" $
      case sendMsg mkNode req of
        (msgs, node') -> do
          msgs `shouldBe` [AppendEntriesRes 0 1 (1, True)]
          node'^.entryLog `shouldBe` [zerothEntry, firstEntry]
  context "when leaderCommit > node's commitIndex" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
    context "and leaderCommit <= index of last new entry" $ do
      let req = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                               , _LeaderId = 1
                                               , _PrevLogIndex = 0
                                               , _PrevLogTerm = 0
                                               , _Entries = [firstEntry, secondEntry]
                                               , _LeaderCommit = 1 }
      it "sets commitIndex = leaderCommit" $
        case sendMsg mkNode req of
          (msgs, node') -> do
            msgs `shouldBe` [AppendEntriesRes 0 1 (1, True)]
            node'^.commitIndex `shouldBe` 1
    context "and leaderCommit > index of last new entry" $ do
      let req = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                                   , _LeaderId = 1
                                                   , _PrevLogIndex = 0
                                                   , _PrevLogTerm = 0
                                                   , _Entries = [firstEntry, secondEntry]
                                                   , _LeaderCommit = 3 }
      it "sets commitIndex = index of last new entry" $
        case sendMsg mkNode req of
          (msgs, node') -> do
            msgs `shouldBe` [AppendEntriesRes 0 1 (1, True)]
            node'^.commitIndex `shouldBe` 2
  context "when leaderCommit <= node's commitIndex" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
        req = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                                 , _LeaderId = 1
                                                 , _PrevLogIndex = 0
                                                 , _PrevLogTerm = 0
                                                 , _Entries = [firstEntry, secondEntry]
                                                 , _LeaderCommit = 0 }
        res = sendMsg mkNode req
    it "does not modify commitIndex" $
      case res of
        (msgs, node') -> do
          msgs `shouldBe` [AppendEntriesRes 0 1 (1, True)]
          node'^.commitIndex `shouldBe` 0

-- TODO: test case where there are 3 nodes, but log is only committed on leader
-- + 1 node. Leader should NOT apply log to statemachine

testRequestVote :: Spec
testRequestVote = do
  let mkNode = mkServerState 0 [1] (10, 10, 0) 10
      req cTerm lTerm lIndex = RequestVoteReq 1 0 RequestVote { _CandidateTerm = cTerm
                                                              , _CandidateId = 1
                                                              , _LastLogIndex = lIndex
                                                              , _LastLogTerm = lTerm }
  context "if candidate's term < currentTerm" $ do
    let node = mkNode { _serverTerm = 2 }
    it "replies false" $
      case sendMsg node (req 1 0 0) of
        (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (2, False)]
  context "if votedFor = Nothing" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Nothing }
    context "and candidate's log is as up-to-date as receiver's log" $
      it "grants vote" $
        case sendMsg node (req 1 0 0) of
          (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (1, True)]
    context "and candidate's log is more up-to-date than receiver's log" $
      it "grants vote" $
        case sendMsg node (req 2 2 2) of
          (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (2, True)]
    context "and candidate's log is not as up-to-date as receiver's log" $ do
      let zerothEntry = mkLogEntry 0 0
          firstEntry = mkLogEntry 1 1
          node' = node { _serverTerm = 1, _entryLog = [zerothEntry, firstEntry] }
      it "does not grant vote but still updates term" $
        case sendMsg node' (req 1 0 0) of
          (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (1, False)]
  context "if votedFor = candidateId" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Just 1 }
    context "and candidate's log is as up-to-date as receiver's log" $
      it "grants vote" $
        case sendMsg node (req 1 0 0) of
          (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (1, True)]
    context "and candidate's log is more up-to-date than receiver's log" $
      it "grants vote" $
        case sendMsg node (req 2 2 2) of
          (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (2, True)]
    context "and candidate's log is not as up-to-date as receiver's log" $ do
      let zerothEntry = mkLogEntry 0 0
          firstEntry = mkLogEntry 1 1
          node' = node { _serverTerm = 1, _entryLog = [zerothEntry, firstEntry] }
      it "does not grant vote but still updates term" $
        case sendMsg node' (req 1 0 0) of
          (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (1, False)]
  context "if votedFor = some other candidate id" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Just 2 }
    it "does not grant vote but still updates term" $
      case sendMsg node (req 1 0 0) of
        (msgs, _) -> msgs `shouldBe` [RequestVoteRes 0 1 (1, False)]

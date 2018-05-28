import           Control.Lens
import           Control.Monad.Log
import           Control.Monad.State.Strict

import           Raft
import           Raft.Log
import           Raft.Rpc
import           Raft.Server

import           Test.Hspec

data Command =
    NoOp
  | Set Int
  deriving (Eq, Show)

newtype StateMachine = StateMachine { value :: Int }
  deriving (Eq, Show)

type StateMachineM = StateT StateMachine Maybe

apply :: Command -> Maybe ()
apply _ = return ()

sendMsg :: ServerState Command -> Message Command -> Maybe ([Message Command], ServerState Command)
sendMsg node msgIn = fmap (\((msgs, _logs), state) -> (msgs, state)) res
  where res = runStateT (runPureLoggingT (handleMessage apply msgIn)) node

main :: IO ()
main = hspec $ do
  testElectionTimeout
  testHeartbeatTimeout
  testAppendEntries
  testRequestVote

mkLogEntry :: LogIndex -> Term -> LogEntry Command
mkLogEntry index term = LogEntry { _Index = index, _Term = term, _Command = NoOp, _RequestId = 0 }

testElectionTimeout :: Spec
testElectionTimeout = do
  let mkNode timeout = mkServerState 0 [1] timeout 10 NoOp
  context "when a node has not reached its election timeout" $ do
    it "doesn't call an election" $ do
      let timeout = 2
      case sendMsg (mkNode timeout) (Tick 0) of
        Just (msgs, node') -> do
          msgs `shouldBe` []
  context "when a node reaches its election timeout" $ do
    it "calls an election" $ do
      let timeout = 1
      case sendMsg (mkNode timeout) (Tick 0) of
        Just ([msg], node') -> do
          case msg of
            RequestVoteReq from to rpc -> do
              from `shouldBe` 0
              to `shouldBe` 1
              rpc ^. candidateTerm `shouldBe` 1
              rpc ^. candidateId `shouldBe` 0
              rpc ^. lastLogIndex `shouldBe` 0
              rpc ^. lastLogTerm `shouldBe` 0

testHeartbeatTimeout :: Spec
testHeartbeatTimeout = do
  let mkNode timeout = mkServerState 0 [1] 10 timeout NoOp
  context "when a node is not a leader" $ do
    it "does not send heartbeats" $ do
      let node = (mkNode 1) { _role = Follower }
      case sendMsg node (Tick 0) of
        Just (msgs, node') -> do
          length msgs `shouldBe` 0
  context "when a node is a leader but has not reached its heartbeat timeout" $ do
    it "does not send heartbeats" $ do
      let node = (mkNode 2) { _role = Leader }
      case sendMsg node (Tick 0) of
        Just (msgs, node') -> do
          length msgs `shouldBe` 0
  context "when a node is a leader and has reached its heartbeat timeout" $ do
    it "sends a heartbeat to each server" $ do
      let node = (mkNode 1) { _role = Leader }
      case sendMsg node (Tick 1) of
        Just ([msg], node') -> do
          case msg of
            AppendEntriesReq 0 1 rpc -> do
              rpc ^. leaderTerm `shouldBe` 0
              rpc ^. leaderId `shouldBe` 0
              rpc ^. prevLogIndex `shouldBe` 0
              rpc ^. prevLogTerm `shouldBe` 0
              rpc ^. entries `shouldBe` []
              rpc ^. leaderCommit `shouldBe` 0

testAppendEntries :: Spec
testAppendEntries = do
  let apply _ = return () :: Maybe ()
      mkNode = mkServerState 0 [1] 10 10 NoOp
  context "when the message's term is less than the node's term" $ do
    let node = mkNode { _serverTerm = 2 }
        appendEntriesPayload = AppendEntries { _LeaderTerm = 1
                                             , _LeaderId = 1
                                             , _PrevLogIndex = 0
                                             , _PrevLogTerm = 0
                                             , _Entries = []
                                             , _LeaderCommit = 0 }
    let req = AppendEntriesReq 1 0 appendEntriesPayload
    it "replies with false" $ do
      case sendMsg node req of
        Just ([msg], node') -> msg `shouldBe` AppendEntriesRes 0 1 (2, False)
  context "when the log doesn't contain an entry at prevLogIndex whose term matches prevLogTerm" $ do
    let node = mkNode
        appendEntriesPayload = AppendEntries { _LeaderTerm = 1
                                             , _LeaderId = 1
                                             , _PrevLogIndex = 0
                                             , _PrevLogTerm = 3
                                             , _Entries = []
                                             , _LeaderCommit = 0 }
        req = AppendEntriesReq 1 0 appendEntriesPayload
    it "replies with false" $ do
      case sendMsg node req of
        Just ([msg], node') -> msg `shouldBe` AppendEntriesRes 0 1 (1, False)
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
      case sendMsg mkNode req1 of
        Just ([msg], node') -> do
          node'^.entryLog `shouldBe` [zerothEntry, firstEntry, secondEntry]
          msg `shouldBe` AppendEntriesRes 0 1 (1, True)
          case sendMsg node' req2 of
            Just (_, node'') -> do
              node''^.entryLog `shouldBe` [zerothEntry, thirdEntry]
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
    it "appends it to the log" $ do
      case sendMsg mkNode req of
        Just ([msg], node') -> do
          msg `shouldBe` AppendEntriesRes 0 1 (1, True)
          node'^.entryLog `shouldBe` [zerothEntry, firstEntry]
  context "when leaderCommit > node's commitIndex" $ do
    let zerothEntry = mkLogEntry 0 0
        firstEntry = mkLogEntry 1 1
        secondEntry = mkLogEntry 2 1
        req = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                                 , _LeaderId = 1
                                                 , _PrevLogIndex = 0
                                                 , _PrevLogTerm = 0
                                                 , _Entries = [firstEntry, secondEntry]
                                                 , _LeaderCommit = 1 }
        res = sendMsg mkNode req
    context "and leaderCommit <= index of last new entry" $ do
      it "sets commitIndex = leaderCommit" $ do
        case res of
          Just ([msg], node') -> do
            msg `shouldBe` AppendEntriesRes 0 1 (1, True)
            node'^.commitIndex `shouldBe` 1
    context "and leaderCommit > index of last new entry" $ do
      let req = AppendEntriesReq 1 0 AppendEntries { _LeaderTerm = 1
                                                 , _LeaderId = 1
                                                 , _PrevLogIndex = 0
                                                 , _PrevLogTerm = 0
                                                 , _Entries = [firstEntry, secondEntry]
                                                 , _LeaderCommit = 3 }
      it "sets commitIndex = index of last new entry" $
        case res of
          Just ([msg], node') -> do
            msg `shouldBe` AppendEntriesRes 0 1 (1, True)
            node'^.commitIndex `shouldBe` 1
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
    it "does not modify commitIndex" $ do
      case res of
        Just ([msg], node') -> do
          msg `shouldBe` AppendEntriesRes 0 1 (1, True)
          node'^.commitIndex `shouldBe` 0

testRequestVote :: Spec
testRequestVote = do
  let mkNode = mkServerState 0 [1] 10 10 NoOp
      req cTerm lTerm lIndex = RequestVoteReq 1 0 RequestVote { _CandidateTerm = cTerm
                                                              , _CandidateId = 1
                                                              , _LastLogIndex = lIndex
                                                              , _LastLogTerm = lTerm }
  context "if candidate's term < currentTerm" $ do
    let node = mkNode { _serverTerm = 2 }
    it "replies false" $
      case sendMsg node (req 1 0 0) of
        Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (2, False)
  context "if votedFor = Nothing" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Nothing }
    context "and candidate's log is as up-to-date as receiver's log" $
      it "grants vote" $
        case sendMsg node (req 1 0 0) of
          Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (1, True)
    context "and candidate's log is more up-to-date than receiver's log" $
      it "grants vote" $
        case sendMsg node (req 2 2 2) of
          Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (2, True)
    context "and candidate's log is not as up-to-date as receiver's log" $ do
      let zerothEntry = mkLogEntry 0 0
          firstEntry = mkLogEntry 1 1
          log = [zerothEntry, firstEntry]
          node' = node { _serverTerm = 1, _entryLog = log }
      it "does not grant vote" $
        case sendMsg node' (req 1 0 0) of
          Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (1, False)
  context "if votedFor = candidateId" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Just 1 }
    context "and candidate's log is as up-to-date as receiver's log" $
      it "grants vote" $
        case sendMsg node (req 1 0 0) of
          Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (1, True)
    context "and candidate's log is more up-to-date than receiver's log" $
      it "grants vote" $
        case sendMsg node (req 2 2 2) of
          Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (2, True)
    context "and candidate's log is not as up-to-date as receiver's log" $ do
      let zerothEntry = mkLogEntry 0 0
          firstEntry = mkLogEntry 1 1
          node' = node { _serverTerm = 1, _entryLog = [zerothEntry, firstEntry] }
      it "does not grant vote" $
        case sendMsg node' (req 1 0 0) of
          Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (1, False)
  context "if votedFor = some other candidate id" $ do
    let node = mkNode { _serverTerm = 0, _votedFor = Just 2 }
    it "does not grant vote" $
      case sendMsg node (req 1 0 0) of
        Just ([msg], _) -> msg `shouldBe` RequestVoteRes 0 1 (1, False)

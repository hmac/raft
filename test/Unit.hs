import           Control.Lens
import           Control.Monad.Identity
import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import           Data.Foldable               (foldl')
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (fromJust)

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

apply :: Command -> StateMachineM ()
apply NoOp    = pure ()
apply (Set i) = put StateMachine { value = i }

main :: IO ()
main = hspec $ do
  testElectionTimeout
  testHeartbeatTimeout
  testAppendEntries

testElectionTimeout :: Spec
testElectionTimeout = do
  let apply cmd = return () :: Maybe ()
  let mkNode timeout = mkServerState 0 [1] timeout 10 NoOp
  let output node msgIn = runStateT (runWriterT (handleMessage apply msgIn)) node
  context "when a node has not reached its election timeout" $ do
    it "doesn't call an election" $ do
      let timeout = 2
      case output (mkNode timeout) (Tick 0) of
        Just (((), msgs), node') -> do
          msgs `shouldBe` []
  context "when a node reaches its election timeout" $ do
    it "calls an election" $ do
      let timeout = 1
      case output (mkNode timeout) (Tick 0) of
        Just (((), [msg]), node') -> do
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
  let apply cmd = return () :: Maybe ()
  let mkNode timeout = mkServerState 0 [1] 10 timeout NoOp
  let output node msgIn = runStateT (runWriterT (handleMessage apply msgIn)) node
  context "when a node is not a leader" $ do
    it "does not send heartbeats" $ do
      let node = (mkNode 1) { _role = Follower }
      case output node (Tick 0) of
        Just (((), msgs), node') -> do
          length msgs `shouldBe` 0
  context "when a node is a leader but has not reached its heartbeat timeout" $ do
    it "does not send heartbeats" $ do
      let node = (mkNode 2) { _role = Leader }
      case output node (Tick 0) of
        Just (((), msgs), node') -> do
          length msgs `shouldBe` 0
  context "when a node is a leader and has reached its heartbeat timeout" $ do
    it "sends a heartbeat to each server" $ do
      let node = (mkNode 1) { _role = Leader }
      case output node (Tick 1) of
        Just (((), [msg]), node') -> do
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
      output node msgIn = runStateT (runWriterT (handleMessage apply msgIn)) node
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
      case output node req of
        Just (((), [msg]), node') -> msg `shouldBe` AppendEntriesRes 0 1 (2, False)
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
      case output node req of
        Just (((), [msg]), node') -> msg `shouldBe` AppendEntriesRes 0 1 (1, False)
  context "when the log contains a conflicting entry" $ do
    let node = mkNode
        zerothEntry = LogEntry { _Index = 0, _Term = 0, _Command = NoOp }
        firstEntry = LogEntry { _Index = 1, _Term = 1, _Command = NoOp }
        secondEntry = LogEntry { _Index = 2, _Term = 1, _Command = NoOp }
        thirdEntry = LogEntry { _Index = 1, _Term = 3, _Command = NoOp }
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
      case output node req1 of
        Just (((), [msg]), node') -> do
          node'^.entryLog `shouldBe` [zerothEntry, firstEntry, secondEntry]
          msg `shouldBe` AppendEntriesRes 0 1 (1, True)
          case output node' req2 of
            Just (_, node'') -> do
              1 `shouldBe` 1
              node''^.entryLog `shouldBe` [zerothEntry, thirdEntry]

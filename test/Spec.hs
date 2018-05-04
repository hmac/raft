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
-- main = do
--   let s0 :: (ServerState Command, StateMachine)
--       s0 = mkServer 0 [1, 2] 3 2
--       s1 = mkServer 1 [0, 2] 4 2
--       s2 = mkServer 2 [0, 1] 5 2
--       servers = Map.insert 2 s2 $ Map.insert 1 s1 $ Map.insert 0 s0 Map.empty
--   testLoop servers mkClient

type Client = [(Int, Message Command)]

mkClient :: Client
mkClient = [(5, ClientRequest 0 (Set 42))
          , (10, ClientRequest 0 (Set 43))
          , (15, ClientRequest 0 (Set 7))]

testLoop :: Map.Map ServerId (ServerState Command, StateMachine) -> Client -> IO ()
testLoop s client = go s 0 client
  where go servers clock [] = mapM_ sendTick servers
          where sendTick = undefined
        go servers clock ((time, msg):queue) = do
          let r = recipient msg
              (state, machine) = servers Map.! r
              run = if time > clock
                       then handleMessage apply (Tick r) >> handleMessage apply msg
                       else handleMessage apply (Tick r)
              res = runStateT (runStateT (runWriterT run) state) machine
          case res of
            Just (((_, msgs), state'), machine') -> do
              let servers' = Map.insert r (state', machine') servers
              print (Tick r :: Message Int)
              print msg
              print state'
              putStrLn $ show (_selfId state) ++ ": " ++ show machine'
              go servers' (clock + 1) (queue ++ map (\m -> (clock, m)) msgs)
            Nothing -> do
              putStrLn "\n\n"
              print msg
              print state
              print res
              error "received nothing!"

tickServer :: ServerId -> ServerState Command -> StateMachine -> ([Message Command], (ServerState Command, StateMachine))
tickServer sid state machine = (msgs, (state', machine'))
  where msg = Tick sid
        res = runStateT (runStateT (runWriterT (handleMessage apply msg)) state) machine
        (((_, msgs), state'), machine') = fromJust res

recipient :: Message a -> ServerId
recipient msg =
  case msg of
    Tick to                   -> to
    AppendEntriesReq _ to _   -> to
    (AppendEntriesRes _ to _) -> to
    (RequestVoteReq _ to _)   -> to
    (RequestVoteRes _ to _)   -> to
    (ClientRequest to _)      -> to

mkServer :: Int -> [ServerId] -> Int -> Int -> (ServerState Command, StateMachine)
mkServer serverId otherServerIds electionTimeout heartbeatTimeout = (serverState, StateMachine { value = 0 })
  where serverState = mkServerState serverId otherServerIds electionTimeout heartbeatTimeout NoOp

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
              rpc ^. candidateTerm `shouldBe` Term { unTerm = 1 }
              rpc ^. candidateId `shouldBe` 0
              rpc ^. lastLogIndex `shouldBe` 0
              rpc ^. lastLogTerm `shouldBe` Term { unTerm = 0 }

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
              rpc ^. leaderTerm `shouldBe` Term { unTerm = 0 }
              rpc ^. leaderId `shouldBe` 0
              rpc ^. prevLogIndex `shouldBe` 0
              rpc ^. prevLogTerm `shouldBe` Term { unTerm = 0 }
              rpc ^. entries `shouldBe` []
              rpc ^. leaderCommit `shouldBe` 0

testAppendEntries :: Spec
testAppendEntries = do
  let apply cmd = return () :: Maybe ()
  let mkNode = mkServerState 0 [1] 10 10 NoOp
  let output node msgIn = runStateT (runWriterT (handleMessage apply msgIn)) node
  context "when the message's term is less than the node's term" $ do
    let term = Term { unTerm = 2 }
    let node = mkNode { _serverTerm = term }
    let appendEntriesPayload = AppendEntries { _LeaderTerm = Term { unTerm = 1 }
                                             , _LeaderId = 1
                                             , _PrevLogIndex = 0
                                             , _PrevLogTerm = Term { unTerm = 0 }
                                             , _Entries = []
                                             , _LeaderCommit = 0 }
    let req = AppendEntriesReq 1 0 appendEntriesPayload
    it "replies with false" $ do
      case output node req of
        Just (((), [msg]), node') -> msg `shouldBe` AppendEntriesRes 0 1 (term, False)
  context "when the log doesn't contain an entry at prevLogIndex whose term matches prevLogTerm" $ do
    it "cba to write this right now" $ do
      1 `shouldBe` 1

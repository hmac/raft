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

data Command a b =
    NoOp
  | Set a b
  deriving (Eq, Show)

newtype StateMachine a b = StateMachine { smMap :: Map.Map a b }
  deriving (Eq, Show)

type StateMachineM a b = StateT (StateMachine a b) Maybe

apply :: Ord a => Command a b -> StateMachineM a b ()
apply NoOp = pure ()
apply (Set k v) = do
  machineMap <- gets smMap
  (put . StateMachine) $ Map.insert k v machineMap

main :: IO ()
main = do
  let s0 :: (ServerState (Command String Int), StateMachine String Int)
      s0 = mkServer 0 [1, 2] 1
      s1 = mkServer 1 [0, 2] 3
      s2 = mkServer 2 [0, 1] 4
      servers = Map.insert 2 s2 $ Map.insert 1 s1 $ Map.insert 0 s0 Map.empty
  testLoop servers

testLoop :: Map.Map ServerId (ServerState (Command String Int), StateMachine String Int) -> IO ()
testLoop s = go s [Tick 0, Tick 0, ClientRequest 0 (Set "foo" 42), ClientRequest 1 (Set "bar" 43), ClientRequest 0 (Set "foo" 7)]
  where go :: Map.Map ServerId (ServerState (Command String Int), StateMachine String Int) -> [Message (Command String Int)] -> IO ()
        go servers [] = putStrLn "finished."
        go servers (msg:queue) = do
          let recipient = case msg of
                            Tick to                   -> to
                            AppendEntriesReq _ to _   -> to
                            (AppendEntriesRes _ to _) -> to
                            (RequestVoteReq _ to _)   -> to
                            (RequestVoteRes _ to _)   -> to
                            (ClientRequest to _)      -> to
              (state, machine) = servers Map.! recipient
              (((_, msgs), state'), machine') = fromJust $ runStateT (runStateT (runWriterT (handleMessage apply msg)) state) machine
              servers' = Map.insert recipient (state', machine') servers
          print msg
          print state'
          print machine'
          go servers' (queue ++ msgs)

mkServer :: Int -> [ServerId] -> Int -> (ServerState (Command a b), StateMachine a b)
mkServer serverId otherServerIds electionTimeout = (serverState, StateMachine { smMap = Map.empty })
  where t0 = Term { unTerm = 0 }
        initialMap :: Map.Map ServerId Int
        initialMap = foldl' (\m sid -> Map.insert sid 0 m) Map.empty otherServerIds
        serverState = ServerState { sId = serverId
                                  , sRole = Follower
                                  , sServerIds = otherServerIds
                                  , sCurrentTerm = t0
                                  , sVotedFor = Nothing
                                  , sLog = [LogEntry { eIndex = 0, eTerm = t0, eCommand = NoOp }]
                                  , sCommitIndex = 0
                                  , sLastApplied = 0
                                  , sTock = 0
                                  , sElectionTimeout = electionTimeout
                                  , sNextIndex = initialMap
                                  , sMatchIndex = initialMap
                                  , sVotesReceived = 0 }


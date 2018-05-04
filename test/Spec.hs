import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (fromJust)

import           Raft
import           Raft.Server

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

main = do
  let s0 :: (ServerState Command, StateMachine)
      s0 = mkServer 0 [1, 2] 3 2
      s1 = mkServer 1 [0, 2] 4 2
      s2 = mkServer 2 [0, 1] 5 2
      servers = Map.insert 2 s2 $ Map.insert 1 s1 $ Map.insert 0 s0 Map.empty
  testLoop servers mkClient

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

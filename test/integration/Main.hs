import           Control.Monad.Logger
import           Control.Monad.State.Strict
import           Data.Functor.Identity
import qualified Data.HashMap.Strict        as Map
import           Data.List                  (partition, sortOn)

import           Raft
import           Raft.Server                hiding (apply)

data Command =
    NoOp
  | Set Int
  deriving (Eq, Show)
type Response = ()

newtype StateMachine = StateMachine { value :: Int }
  deriving (Eq, Show)

type StateMachineM = StateT StateMachine (NoLoggingT Identity)

-- apply is a lens on StateMachine that we don't want to clash with
apply :: Command -> StateMachineM ()
apply NoOp    = pure ()
apply (Set i) = put StateMachine { value = i }

main :: IO ()
main = do
  let s0 :: (ServerState Command () StateMachineM, StateMachine)
      s0 = mkServer 0 [1, 2] (30, 30, 0) 20 apply
      s1 = mkServer 1 [0, 2] (40, 40, 0) 20 apply
      s2 = mkServer 2 [0, 1] (50, 50, 0) 20 apply
      servers = Map.insert 2 s2 $ Map.insert 1 s1 $ Map.insert 0 s0 Map.empty
  testLoop servers mkClient

type Client = [(Integer, Message Command Response)]

mkClient :: Client
mkClient = [(500, ClientRequest 0 0 (Set 42))
          , (1000, ClientRequest 0 1 (Set 43))
          , (1500, ClientRequest 0 2 (Set 7))
          , (1521, Tick 1)
          , (1521, Tick 2)] -- wait for the followers to apply their logs

testLoop ::
     Map.HashMap ServerId (ServerState Command () StateMachineM, StateMachine) -> Client -> IO ()
testLoop s = go s 0
  where
    go servers _ [] =
      let states = Map.toList $ Map.map snd servers
      in putStrLn $ "final states: " ++ show states
    go servers clock queue
      | any (\(t, _) -> t <= clock) queue = do
        putStrLn $ "clock: " ++ show clock
        let (time, msg):queue' = sortOn fst queue
            r = recipient msg
            (state, machine) = servers Map.! r
            run =
              if time <= clock
                then handleMessage msg
                else pure []
            res = runIdentity $ runNoLoggingT $ runStateT (runStateT run state) machine
        case res of
          ((msgs,  state'), machine') -> do
            let (_, rest) = partition isClientResponse msgs
            let servers' = Map.insert r (state', machine') servers
            print msg
            putStrLn $ show (_selfId state) ++ ": " ++ show machine'
            go servers' clock $
              sortOn fst (queue' ++ map (\m -> (clock, m)) rest)
    go servers clock queue = go servers (clock + 1) queue'
      where
        queue' = sortOn fst (queue ++ ticks)
        ticks = map ((,) clock . Tick) (Map.keys servers)

isClientResponse :: Message a b -> Bool
isClientResponse m = case m of
                       ClientResponse {} -> True
                       _                 -> False

recipient :: Message a b -> ServerId
recipient msg =
  case msg of
    Tick to                   -> to
    AppendEntriesReq _ to _   -> to
    (AppendEntriesRes _ to _) -> to
    (RequestVoteReq _ to _)   -> to
    (RequestVoteRes _ to _)   -> to
    (ClientRequest to _ _)    -> to

mkServer ::
     ServerId
  -> [ServerId]
  -> (Int, Int, Int)
  -> MonotonicCounter
  -> (Command -> StateMachineM ())
  -> (ServerState Command () StateMachineM, StateMachine)
mkServer serverId otherServerIds electionTimeout heartbeatTimeout apply =
  (serverState, StateMachine {value = 0})
  where
    serverState =
      mkServerState
        serverId
        otherServerIds
        electionTimeout
        heartbeatTimeout
        NoOp
        apply

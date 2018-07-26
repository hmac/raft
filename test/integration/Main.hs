import           Control.Monad.Logger
import           Control.Monad.State.Strict
import           Data.Functor.Identity
import qualified Data.HashMap.Strict        as Map
import           Data.List                  (partition, sortOn)

import           Raft
import           Raft.Lens                  hiding (apply)
import           Raft.Rpc
import           Raft.Server                hiding (apply)

data Command =
    NoOp
  | Set Int
  deriving (Eq, Show)
type Response = ()

newtype StateMachine = StateMachine { value :: Int }
  deriving (Eq, Show)

type StateMachineM = StateT StateMachine (NoLoggingT Identity)

apply :: Command -> StateMachineM ()
apply NoOp    = pure ()
apply (Set i) = put StateMachine { value = i }

main :: IO ()
main = do
  let s0 :: (ServerState Command () StateMachineM, StateMachine)
      s0 = mkServer 0 [1, 2] (30, 30, 0) 20 apply
      s1 = mkServer 1 [0, 2] (40, 40, 0) 20 apply
      s2 = mkServer 2 [0, 1] (50, 50, 0) 20 apply
      servers = Map.fromList [(0, s0), (1, s1), (2, s2)]
  testLoop servers mkClient

type Client = [(Integer, ServerId, Message Command Response)]

mkClient :: Client
mkClient = [(500, 0, CReq ClientReq { _requestPayload = Set 42, _clientRequestId = 0})
           , (1000, 0, CReq ClientReq { _requestPayload = Set 43, _clientRequestId = 1 })
           , (1500, 0, CReq ClientReq { _requestPayload = Set 7, _clientRequestId = 2 })
           , (1521, 1, Tick)
           , (1521, 2, Tick)] -- wait for the followers to apply their logs

testLoop ::
     Map.HashMap ServerId (ServerState Command () StateMachineM, StateMachine) -> Client -> IO ()
testLoop s = go s 0
  where
    go :: Map.HashMap ServerId (ServerState Command () StateMachineM, StateMachine) -> Integer -> Client -> IO ()
    go servers _ [] =
      let states = map (\(sid, m) -> (sid, value m)) $ Map.toList $ Map.map snd servers
      in putStrLn $ "final states: " ++ show states
    go servers clock queue | any (\(t, _, _) -> t <= clock) queue = do
      let (time, r, msg):queue' = sortOn (\(c, _, _) -> c) queue
          (state, machine) = servers Map.! r
          run = if time <= clock then handleMessage msg else pure []
          res = runIdentity $ runNoLoggingT $ runStateT (runStateT run state) machine
      case res of
        ((msgs,  state'), machine') -> do
          let (_, rest) = partition isClientResponse msgs
          let servers' = Map.insert r (state', machine') servers
          print (clock, state^.selfId, value machine', msg)
          go servers' clock $
            sortOn (\(c, _, _) -> c) (queue' ++ map (\m -> (clock, recipient m, m)) rest)
    go servers clock queue = go servers (clock + 1) queue'
      where
        queue' = sortOn (\(c, _, _) -> c) (queue ++ ticks)
        ticks = map (\sid -> (clock, sid, Tick)) (Map.keys servers)

isClientResponse :: Message a b -> Bool
isClientResponse m = case m of
                       CRes{} -> True
                       _      -> False

recipient :: Message a b -> ServerId
recipient msg =
  case msg of
    Tick    -> error "cannot determine recipient from Tick message"
    CReq r  -> error "cannot determine recipient from CReq message"
    AEReq r -> r^.to
    AERes r -> r^.to
    RVReq r -> r^.to
    RVRes r -> r^.to

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

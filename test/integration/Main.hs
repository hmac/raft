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

sid1 :: ServerId
sid1 = ServerId "1"

sid2 :: ServerId
sid2 = ServerId "2"

sid3 :: ServerId
sid3 = ServerId "3"

main :: IO ()
main = do
  let s1 = mkServer sid1 [sid2, sid3] (30, 30, 0) 20 apply
      s2 = mkServer sid2 [sid1, sid3] (40, 40, 0) 20 apply
      s3 = mkServer sid3 [sid1, sid2] (50, 50, 0) 20 apply
      servers = Map.fromList [(sid1, s1), (sid2, s2), (sid3, s3)]
  testLoop servers mkClient

type Client = [(Integer, ServerId, Message Command Response)]

mkClient :: Client
mkClient = [(500, sid1, CReq ClientReq { _requestPayload = Set 42, _clientRequestId = 0})
           , (1000, sid1, CReq ClientReq { _requestPayload = Set 43, _clientRequestId = 1 })
           , (1500, sid1, CReq ClientReq { _requestPayload = Set 7, _clientRequestId = 2 })
           , (1521, sid2, Tick)
           , (1521, sid3, Tick)] -- wait for the followers to apply their logs

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

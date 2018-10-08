import           Control.Monad.Logger
import           Control.Monad.State.Strict
import           Data.Functor.Identity
import qualified Data.HashMap.Strict        as Map
import           Data.List                  (find, partition, sortOn, intersperse)
import           Data.Maybe                 (fromJust, mapMaybe)
import           System.Random              (randomIO)

import           Raft
import Raft.Log (LogEntry)
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

type Node = (ServerState Command () StateMachineM, StateMachine)

apply :: Command -> StateMachineM ()
apply NoOp    = pure ()
apply (Set i) = put StateMachine { value = i }

sid1 :: ServerId
sid1 = ServerId "1"

sid2 :: ServerId
sid2 = ServerId "2"

sid3 :: ServerId
sid3 = ServerId "3"

type ClientMessage = (Integer, ServerId, Message Command Response)

main :: IO ()
main = do
  let servers = Map.fromList [(sid1, mkServer sid1 [sid2, sid3] (3, 3, 0) 2 apply)
                            , (sid2, mkServer sid2 [sid1, sid3] (4, 4, 0) 2 apply)
                            , (sid3, mkServer sid3 [sid1, sid2] (5, 5, 0) 2 apply)]
  testLoop servers (Queue clientMessages)

clientMessages :: [ClientMessage]
clientMessages = [(15, sid1, CReq ClientReq { _requestPayload = Set 42, _clientRequestId = 0})
                , (20, sid1, CReq ClientReq { _requestPayload = Set 43, _clientRequestId = 1 })
                , (30, sid1, CReq ClientReq { _requestPayload = Set 7, _clientRequestId = 2 })
                , (35, sid2, Tick)
                , (35, sid3, Tick)] -- wait for the followers to apply their logs

-- A queue of client messages, ordered by time
newtype Queue = Queue [ClientMessage]
  deriving (Eq, Show)

-- Push a new message on to the queue
push :: Queue -> ClientMessage -> Queue
push (Queue q) m = Queue $ sortOn (\(c, _, _) -> c) (m : q)

-- Pop the next message from the queue
pop :: Queue -> (ClientMessage, Queue)
pop (Queue (m : q)) = (m, Queue q)

testLoop :: Map.HashMap ServerId Node -> Queue -> IO ()
testLoop s = go s 0
  where
    -- no more client messages
    go servers _ (Queue []) =
      let states = map (\(sid, m) -> (sid, value m)) $ Map.toList $ Map.map snd servers
      in putStrLn $ "final states: " ++ show states
    -- client messages that are due to be sent
    go servers clock queue =
      let ((time, sid, msg), queue') = pop queue
       in if time > clock
             then let ticks = map (\sid -> (clock, sid, Tick)) (Map.keys servers)
                      queue' = foldl push queue ticks
                  in do
                    putStrLn $ show clock ++ ":" ++ pShow servers
                    go servers (clock + 1) queue'
             else
              let
                (msgs, (state', machine')) = sendMessage msg (servers Map.! sid)
               in do
                 putStrLn $ show clock ++ ":" ++ pShow servers
                 dropMessages <- randomIO :: IO Bool
                 let dropMessages = False
                 let (clientResponses, rest) = if dropMessages then ([], []) else partition isClientResponse msgs
                     redirects = mapMaybe handleClientRedirects clientResponses
                     servers' = Map.insert sid (state', machine') servers
                     queue'' = foldl push queue' $ map (\m -> (clock, recipient m, m)) rest ++ redirects
                 go servers' clock queue''

sendMessage :: Message Command () -> Node -> ([Message Command ()], Node)
sendMessage msg (s, m) =
  let ((msgs, state'), machine') =
        runIdentity $
        runNoLoggingT $ flip runStateT m $ flip runStateT s $ handleMessage msg
  in (msgs, (state', machine'))

isClientResponse :: Message a b -> Bool
isClientResponse m =
  case m of
    CRes {} -> True
    _ -> False

handleClientRedirects ::
     Message Command Response
  -> Maybe (Integer, ServerId, Message Command Response)
handleClientRedirects (CRes ClientResFailure {_leader = Just l, _responseId = i}) =
  Just
    (1, l, CReq $ ClientReq {_clientRequestId = i, _requestPayload = payload})
  where
    payload = request ^. requestPayload
    (CReq request) =
      fromJust $ find (\(CReq req) -> req ^. clientRequestId == i) clientReqs
    clientReqs = filter isClientRequest clientMessages_
    isClientRequest (CReq _) = True
    isClientRequest _ = False
    clientMessages_ = map (\(_, _, x) -> x) clientMessages
handleClientRedirects _ = Nothing

pShow :: Map.HashMap ServerId Node -> String
pShow hmap =
  let f = fmap pShowAll (Map.toList hmap)
      pShowAll (sid, (state, machine)) =
        unServerId sid ++ pShowMachine machine ++ " " ++ pShowState state
      pShowState :: ServerState Command () StateMachineM -> String
      pShowState state =
        let roleS =
              case state ^. role of
                Leader -> "L"
                _ -> "F"
            log =
              (mconcat . intersperse "|") $ fmap pShowEntry (state ^. entryLog)
        in roleS ++ " " ++ log
      pShowEntry :: LogEntry Command -> String
      pShowEntry e = pShowCommand (e ^. command)
      pShowCommand c =
        case c of
          NoOp -> "∅"
          Set n -> "->" ++ show n
      pShowMachine m = "=" ++ show (value m)
  in (unwords . intersperse " ") f

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
  -> Node
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

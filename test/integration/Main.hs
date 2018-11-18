import           Control.Monad.Logger
import           Control.Monad.State.Strict
import           Data.Functor.Identity
import qualified Data.HashMap.Strict        as Map
import           Data.List                  (find, intersperse, partition,
                                             sortOn)
import           Data.Maybe                 (fromJust, mapMaybe)
import           Data.Word
import           System.Random              (randomRIO)

import           Raft
import           Raft.Lens                  hiding (apply)
import           Raft.Log                   (LogEntry, LogPayload (..),
                                             ServerId (..))
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
sid1 = ServerId "alice"

sid2 :: ServerId
sid2 = ServerId "bob"

sid3 :: ServerId
sid3 = ServerId "charlie"

type ClientMessage = (Integer, ServerId, Message Command Response)

main :: IO ()
main = do
  let servers = Map.fromList [(sid1, mkServer sid1 [sid2, sid3] (3, 3, 0) 2 apply)
                            , (sid2, mkServer sid2 [sid1, sid3] (4, 4, 0) 2 apply)
                            , (sid3, mkServer sid3 [sid1, sid2] (5, 5, 0) 2 apply)]
      clockEnd = 1000
      ticks = concatMap (\sid -> generateTicks sid clockEnd) [sid1, sid2, sid3]
      msgs = foldl push (Queue clientMessages) ticks
      lossyFilter :: Integer -> Integer -> Integer -> IO Bool
      lossyFilter min max threshold = do
        rInt <- randomRIO (min, max)
        pure $ rInt < threshold
  putStrLn "Testing a happy path"
  testLoop servers (pure False) msgs
  (flip mapM_) [0, 1, 2, 5, 10, 20, 50, 80, 90] $ \c -> do
    putStrLn $ "Testing a network with " ++ show c ++ "% packet loss"
    testLoop servers (lossyFilter 0 100 c) msgs

clientMessages :: [ClientMessage]
clientMessages = [(15, sid1, CReq ClientReq { _requestPayload = Set 3, _clientRequestId = 0})
                , (20, sid1, CReq ClientReq { _requestPayload = Set 2, _clientRequestId = 1 })
                , (30, sid1, CReq ClientReq { _requestPayload = Set 1, _clientRequestId = 2 })
                 ]

generateTicks :: ServerId -> Integer -> [ClientMessage]
generateTicks sid end = map (\t -> (t, sid, Tick)) [0..end]

-- A queue of client messages, ordered by time
newtype Queue = Queue [ClientMessage]
  deriving (Eq, Show)

-- Push a new message on to the queue
push :: Queue -> ClientMessage -> Queue
push (Queue q) m = Queue $ sortOn (\(c, _, _) -> c) (m : q)

-- Pop the next message from the queue
pop :: Queue -> (ClientMessage, Queue)
pop (Queue (m : q)) = (m, Queue q)

isEmpty :: Queue -> Bool
isEmpty (Queue l ) = null l

type Clock = Integer

testLoop :: Map.HashMap ServerId Node -> IO Bool -> Queue -> IO ()
testLoop s filter = go s 0
  where
    -- no more client messages
    go servers _ (Queue []) =
      let states = map (\(sid, m) -> (sid, value m)) $ Map.toList $ Map.map snd servers
      in putStrLn $ "final states: " ++ show states
    -- client messages that are due to be sent
    go servers clock queue =
      let ((time, sid, msg), queue') = pop queue
       in if time > clock
             then go servers (clock + 1) queue
             else do
               (servers', queue') <- runCycle servers filter clock queue
               -- putStrLn $ show clock ++ " " ++ pShow servers'
               go servers' clock queue'

runCycle :: Map.HashMap ServerId Node -> IO Bool -> Clock -> Queue -> IO (Map.HashMap ServerId Node, Queue)
runCycle servers filter clock queue | isEmpty queue = pure (servers, queue)
runCycle servers filter clock queue = do
  let ((time, sid, msg), queue') = pop queue
  if time > clock
     then pure (servers, queue)
     else let
            (msgs, (state', machine')) = sendMessage msg (servers Map.! sid)
           in do
             dropMessages <- filter
             let (clientResponses, rest) = if dropMessages then ([], []) else partition isClientResponse msgs
                 redirects = mapMaybe handleClientRedirects clientResponses
                 servers' = Map.insert sid (state', machine') servers
                 queue'' = foldl push queue' $ map (\m -> (clock, recipient m, m)) rest ++ redirects
             pure (servers', queue'')

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
    _       -> False

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
    isClientRequest _        = False
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
                _      -> "F"
            log =
              (mconcat . intersperse "|") $ fmap pShowEntry (state ^. entryLog)
        in roleS ++ " " ++ log
      pShowEntry :: LogEntry Command -> String
      pShowEntry e = pShowPayload (e ^. payload)
      pShowPayload c =
        case c of
          LogCommand NoOp    -> "∅"
          LogCommand (Set n) -> "->" ++ show n
          _                  -> "?"
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
        1
        electionTimeout
        heartbeatTimeout
        [NoOp]
        apply

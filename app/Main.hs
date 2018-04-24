{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}
module Main where

import           Raft
import           Raft.Log
import           Raft.Server

import           Timer                            (milliSeconds, periodically)

import           Control.Concurrent               (threadDelay)
import           Control.Distributed.Process
import           Control.Distributed.Process.Node
import           Control.Monad                    (forever)
import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import           Data.Binary                      (Binary)
import           Data.Foldable                    (foldl')
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (fromJust)
import           Data.Typeable                    (Typeable)
import           GHC.Generics                     (Generic)
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)

replyBack :: (ProcessId, Raft.Message Int) -> Process ()
replyBack (sender, msg) = send sender msg

logMessage :: Raft.Message Int -> Process ()
logMessage msg = say $ "handling " ++ show msg

main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  _ <- runProcess node $ do
    (snd, rcv) <- newChan :: Process (SendPort (Raft.Message Command), ReceivePort (Raft.Message Command))

    s0 <- spawnServer 0 [1, 2] snd
    s1 <- spawnServer 1 [0, 2] snd
    s2 <- spawnServer 2 [0, 1] snd

    let phonebook = [(0, s0), (1, s1), (2, s2)]

    sendTick s0 0
    sendTick s0 0
    sendTick s0 0
    sendTick s0 0

    spawnClient snd 0

    forever $ do
      m <- receiveChanTimeout 1000000 rcv
      case m of
        Nothing  -> die "nothing came back!"
        Just msg -> do
          case lookup (messageRecipient msg) phonebook of
            Just pid -> do
              send pid msg
            Nothing  -> die "could not look up server in phonebook"
  pure ()

sendTick :: ProcessId -> ServerId -> Process ()
sendTick pid sid = let tick :: Raft.Message Command
                       tick = Tick sid
                    in send pid tick

data Command = NoOp | Set Int deriving (Eq, Show, Generic, Typeable)

deriving instance Typeable Command
instance Binary Command

newtype StateMachine = StateMachine { value :: Int } deriving (Eq, Show)
type StateMachineM = StateT StateMachine Maybe

apply :: Command -> StateMachineM ()
apply NoOp    = pure ()
apply (Set n) = modify' $ \s -> s { value = n }

spawnServer :: ServerId -> [ServerId] -> SendPort (Raft.Message Command) -> Process ProcessId
spawnServer self others proxy = spawnLocal $ do
  spawnClock proxy self
  go newServer newStateMachine
  where (newServer, newStateMachine) = mkServer self others
        go s m = do
          msg <- expect
          say (show msg)
          let (msgs, s', m') = processMessage s m msg
          mapM_ (sendChan proxy) msgs
          say (show m')
          go s' m'

spawnClock :: SendPort (Raft.Message Command) -> ServerId -> Process ProcessId
spawnClock chan sid = periodically (milliSeconds 500) $ do
  sendChan chan (Tick sid)

spawnClient :: SendPort (Raft.Message Command) -> ServerId -> Process ProcessId
spawnClient chan sid = spawnLocal (go 0)
  where go n = do
          liftIO $ threadDelay 1000000
          sendChan chan (ClientRequest sid (Set n))
          go (n + 1)

processMessage :: ServerState Command -> StateMachine -> Raft.Message Command -> ([Raft.Message Command], ServerState Command, StateMachine)
processMessage s m msg = do
  let res = runStateT (runStateT (runWriterT (Raft.handleMessage apply msg)) s) m
  case res of
    Just (((_, msgs), s'), m') -> (msgs, s', m')
    Nothing                    -> error "received nothing!"

messageRecipient :: Raft.Message Command -> ServerId
messageRecipient (AppendEntriesReq _ to _) = to
messageRecipient (AppendEntriesRes _ to _) = to
messageRecipient (RequestVoteReq _ to _)   = to
messageRecipient (RequestVoteRes _ to _)   = to
messageRecipient (Tick to)                 = to
messageRecipient (ClientRequest to _)      = to

mkServer :: ServerId -> [ServerId] -> (ServerState Command, StateMachine)
mkServer self others = (serverState, StateMachine { value = 0 })
  where t0 = Term { unTerm = 0 }
        initialMap :: Map.Map ServerId Int
        initialMap = foldl' (\m sid -> Map.insert sid 0 m) Map.empty others
        serverState = ServerState { _selfId = self
                                  , _role = Follower
                                  , _serverIds = others
                                  , _serverTerm = t0
                                  , _votedFor = Nothing
                                  , _entryLog = [LogEntry { _Index = 0, _Term = t0, _Command = NoOp }]
                                  , _commitIndex = 0
                                  , _lastApplied = 0
                                  , _tock = 0
                                  , _electionTimeout = 3
                                  , _nextIndex = initialMap
                                  , _matchIndex = initialMap
                                  , _votesReceived = 0 }


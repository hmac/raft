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
    (sendPort, recvPort) <- newChan :: Process (SendPort (Raft.Message Command), ReceivePort (Raft.Message Command))

    s0 <- spawnServer 0 [1, 2] sendPort 20 5
    s1 <- spawnServer 1 [0, 2] sendPort 30 5
    s2 <- spawnServer 2 [0, 1] sendPort 40 5
    _ <- spawnClient sendPort 0

    let phonebook = [(0, s0), (1, s1), (2, s2)]

    forever $ do
      m <- receiveChanTimeout 1000000 recvPort
      case m of
        Nothing  -> die "nothing came back!"
        Just msg ->
          case lookup (messageRecipient msg) phonebook of
            Just pid -> send pid msg
            Nothing  -> die "could not look up server in phonebook"
  pure ()

data Command = NoOp | Set Int deriving (Eq, Show, Generic, Typeable)

deriving instance Typeable Command
instance Binary Command

newtype StateMachine = StateMachine { value :: Int } deriving (Eq, Show)
type StateMachineM = StateT StateMachine Maybe

apply :: Command -> StateMachineM ()
apply NoOp    = pure ()
apply (Set n) = modify' $ \s -> s { value = n }

spawnServer :: ServerId -> [ServerId] -> SendPort (Raft.Message Command) -> Int -> Int -> Process ProcessId
spawnServer self others proxy electionTimeout heartbeatTimeout = spawnLocal $ do
  _ <- spawnClock proxy self
  go newServer newStateMachine
  where (newServer, newStateMachine) = mkServer self others electionTimeout heartbeatTimeout
        go s m = do
          msg <- expect
          say (show msg)
          let (msgs, s', m') = processMessage s m msg
          mapM_ (sendChan proxy) msgs
          say (show m')
          go s' m'

spawnClock :: SendPort (Raft.Message Command) -> ServerId -> Process ProcessId
spawnClock chan sid = periodically (milliSeconds 500) $ do
  say $ "sending Tick " ++ show sid
  sendChan chan (Tick sid)

spawnClient :: SendPort (Raft.Message Command) -> ServerId -> Process ProcessId
spawnClient chan sid = spawnLocal $ liftIO (threadDelay 5) >> go 1
  where go n = do
          liftIO $ threadDelay 2000000 -- 2 seconds
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

mkServer :: ServerId -> [ServerId] -> Int -> Int -> (ServerState Command, StateMachine)
mkServer self others electionTimeout heartbeatTimeout = (serverState, StateMachine { value = 0 })
  where initialMap :: Map.Map ServerId Int
        initialMap = foldl' (\m sid -> Map.insert sid 0 m) Map.empty others
        serverState = ServerState { _selfId = self
                                  , _role = Follower
                                  , _serverIds = others
                                  , _serverTerm = 0
                                  , _votedFor = Nothing
                                  , _entryLog = [LogEntry { _Index = 0, _Term = 0, _Command = NoOp }]
                                  , _commitIndex = 0
                                  , _lastApplied = 0
                                  , _electionTimer = 0
                                  , _heartbeatTimer = 0
                                  , _electionTimeout = electionTimeout
                                  , _heartbeatTimeout = heartbeatTimeout
                                  , _nextIndex = initialMap
                                  , _matchIndex = initialMap
                                  , _votesReceived = 0 }


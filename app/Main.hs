{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StandaloneDeriving #-}
module Main where

import           Raft
import           Raft.Log                         (RequestId (..))
import           Raft.Server

import           Timer                            (milliSeconds, periodically)

import           Control.Concurrent               (threadDelay)
import           Control.Distributed.Process
import           Control.Distributed.Process.Node
import           Control.Monad                    (forever)
import           Control.Monad.Log
import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import           Data.Binary                      (Binary)
import           Data.Foldable                    (foldl')
import qualified Data.Map.Strict                  as Map
import qualified Data.Text                        as T
import qualified Data.Text.IO                     (putStrLn)
import           Data.Typeable                    (Typeable)
import           GHC.Generics                     (Generic)
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)

main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  _ <- runProcess node $ do
    (sendPort, recvPort) <- newChan :: Process (SendPort (Raft.Message Command), ReceivePort (Raft.Message Command))

    s0 <- spawnServer 0 [1, 2] sendPort 10 5
    s1 <- spawnServer 1 [0, 2] sendPort 20 6
    s2 <- spawnServer 2 [0, 1] sendPort 30 7
    client <- spawnClient sendPort 0

    link s0
    link s1
    link s2
    link client

    let phonebook = [(0, s0), (1, s1), (2, s2), (3, client)]

    forever $ do
      m <- receiveChanTimeout 1000000 recvPort
      case m of
        Nothing  -> die ("nothing came back!" :: String)
        Just msg ->
          case lookup (messageRecipient msg) phonebook of
            Just pid -> send pid msg
            Nothing  -> die ("could not look up server in phonebook" :: String)
  pure ()

data Command = NoOp | Set Int deriving (Eq, Show, Generic, Typeable)

deriving instance Typeable Command
instance Binary Command

newtype StateMachine = StateMachine { value :: Int } deriving (Eq, Show)
type StateMachineT m = StateT StateMachine m

apply :: Monad m => Command -> StateMachineT m ()
apply NoOp    = pure ()
apply (Set n) = modify' $ \s -> s { value = n }

spawnServer ::
     ServerId
  -> [ServerId]
  -> SendPort (Raft.Message Command)
  -> MonotonicCounter
  -> MonotonicCounter
  -> Process ProcessId
spawnServer self others proxy electionTimeout heartbeatTimeout =
  spawnLocal $ do
    _ <- spawnClock proxy self
    say $ "I am " ++ show self
    go newServer newStateMachine
  where
    (newServer, newStateMachine) =
      mkServer self others electionTimeout heartbeatTimeout
    go s m = do
      msg <- expect
      (msgs, logs, s', m') <- liftIO $ processMessage s m msg
      mapM_ (say . T.unpack) logs
      mapM_ (sendChan proxy) msgs
      go s' m'

spawnClock :: SendPort (Raft.Message Command) -> ServerId -> Process ProcessId
spawnClock chan sid = periodically (milliSeconds 100) $ do
  sendChan chan (Tick sid)

spawnClient :: SendPort (Raft.Message Command) -> ServerId -> Process ProcessId
spawnClient chan sid = spawnLocal $ liftIO (threadDelay 5) >> go 1
  where
    go n = do
      liftIO $ threadDelay 2000000 -- 2 seconds
      sendChan chan (ClientRequest sid (RequestId (toInteger n)) (Set n))
      msg <- expect
      handleResponse msg
      go (n + 1)
    handleResponse :: Raft.Message Command -> Process ()
    handleResponse (ClientResponse sid reqId cmd success) =
      if success
        then say (show cmd)
        else say $ "command failed: " ++ show cmd

processMessage ::
     ServerState Command
  -> StateMachine
  -> Raft.Message Command
  -> IO ([Raft.Message Command], [T.Text], ServerState Command, StateMachine)
processMessage s m msg = do
  let writer = Raft.handleMessage (apply :: Command -> StateMachineT IO ()) msg
  result <- runStateT (runStateT (runPureLoggingT writer) s) m
      -- machine = runLoggingT logger (lift . T.putStrLn)
      -- result = runStateT machine m
  case result of
    (((msgs, logs), s'), m') -> pure (msgs, logs, s', m')

messageRecipient :: Raft.Message Command -> ServerId
messageRecipient (AppendEntriesReq _ to _) = to
messageRecipient (AppendEntriesRes _ to _) = to
messageRecipient (RequestVoteReq _ to _)   = to
messageRecipient (RequestVoteRes _ to _)   = to
messageRecipient (Tick to)                 = to
messageRecipient (ClientRequest to _ _)    = to
messageRecipient ClientResponse {}         = 3 -- client hardcoded to 3

mkServer ::
     ServerId
  -> [ServerId]
  -> MonotonicCounter
  -> MonotonicCounter
  -> (ServerState Command, StateMachine)
mkServer self others electionTimeout heartbeatTimeout =
  (serverState, StateMachine {value = 0})
  where
    serverState =
      mkServerState self others electionTimeout heartbeatTimeout NoOp

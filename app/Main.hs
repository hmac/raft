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
import           Control.Monad.Log
import           Control.Monad.State.Strict
import           Data.Binary                      (Binary)
import           Data.Foldable                    (foldl')
import qualified Data.HashMap.Strict              as Map
import           Data.List                        (partition)
import qualified Data.Text                        as T
import           Data.Typeable                    (Typeable)
import           GHC.Generics                     (Generic)
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)

main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  _ <- runProcess node $ do
    s0 <- server 0 [1, 2] 20 15
    s1 <- server 1 [0, 2] 25 16
    s2 <- server 2 [0, 1] 30 17
    client <- spawnClient

    link s0
    link s1
    link s2
    link client

    register "0" s0
    register "1" s1
    register "2" s2
    register "client" client

    expect
  pure ()

data Command = NoOp | Set Int deriving (Eq, Show, Generic, Typeable)

deriving instance Typeable Command
instance Binary Command

newtype StateMachine = StateMachine { value :: Int } deriving (Eq, Show)
type StateMachineT m = StateT StateMachine m

apply :: Monad m => Command -> StateMachineT m ()
apply NoOp    = pure ()
apply (Set n) = modify' $ \s -> s { value = n }

-- server receives three types of message:
-- - clock ticks from its clock (via a channel)
-- - RPCs from other servers (via a mailbox message)
-- - requests from a client (via the same mechanism)
server ::
     ServerId
  -> [ServerId]
  -> MonotonicCounter
  -> MonotonicCounter
  -> Process ProcessId
server self others eTimeout hTimeout = spawnLocal $ do
  (clockPid, clockRecv) <- spawnClock
  link clockPid
  say $ "I am " ++ show self
  go clockRecv Map.empty newServer newStateMachine
  where
    (newServer, newStateMachine) = mkServer self others eTimeout hTimeout
    go ::
         ReceivePort ()
      -> Map.HashMap RequestId ProcessId
      -> ServerState Command
      -> StateMachine
      -> Process ()
    go clock reqs s m = do
      (s', m', reqs') <-
        receiveWait
          [ match (handleRpc s m reqs)
          , match (handleClientReq s m reqs)
          , matchChan clock (handleClockTick s m reqs)
          ]
      go clock reqs' s' m'
    handleRpc s m reqs r = do
      (msgs, logs, s', m') <- liftIO $ processMessage s m r
      let (clientResponses, rest) = partition isClientResponse msgs
          isClientResponse ClientResponse {} = True
          isClientResponse _                 = False
      mapM_ (say . T.unpack) logs
      mapM_ (\msg -> nsend ((show . unServerId . messageRecipient) msg) msg) rest
      forM_ clientResponses $ \res@(ClientResponse _ reqId _ _) ->
        case Map.lookup reqId reqs of
          Just pid -> do say ("sending " ++ show res ++ " to client"); send pid res
          Nothing  -> pure ()
      mapM_ (nsend "client") clientResponses
      let reqs' = foldl' (\reqMap (ClientResponse _ reqId _ _) -> Map.delete reqId reqMap) reqs clientResponses
      pure (s', m', reqs')
    handleClockTick s m reqs _ = handleRpc s m reqs (Tick 0)
    handleClientReq s m reqs r = do
      let reqs' = case message r of
                    (ClientRequest _ reqId _) -> Map.insert reqId (reqPid r) reqs
                    _ -> reqs
      handleRpc s m reqs' (message r)


spawnClock :: Process (ProcessId, ReceivePort ())
spawnClock = do
  (sendPort, recvPort) <- newChan
  clock_ <- periodically (milliSeconds 100) $ sendChan sendPort ()
  pure (clock_, recvPort)

data Req = Req { reqPid :: ProcessId, message :: Raft.Message Command } deriving (Generic)
deriving instance Typeable Req
instance Binary Req

-- the client, for now, will send all requests to server "0"
spawnClient :: Process ProcessId
spawnClient = spawnLocal $ say "I am client" >> liftIO (threadDelay 5) >> go 1
  where
    go n = do
      liftIO $ threadDelay 2000000 -- 2 seconds
      self <- getSelfPid
      nsend "0" Req { reqPid = self, message = ClientRequest 0 (RequestId (toInteger n)) (Set n) }
      msg <- expect
      handleResponse msg
      go (n + 1)
    handleResponse :: Raft.Message Command -> Process ()
    handleResponse (ClientResponse _ _ cmd success) =
      if success
        then say $ "command succeeded: " ++ show cmd
        else say $ "command failed: " ++ show cmd
    handleResponse _ = die ("client received bad response (not client res)" :: String)

processMessage ::
     ServerState Command
  -> StateMachine
  -> Raft.Message Command
  -> IO ([Raft.Message Command], [T.Text], ServerState Command, StateMachine)
processMessage s m msg = do
  let writer = Raft.handleMessage (apply :: Command -> StateMachineT IO ()) msg
  result <- runStateT (runStateT (runPureLoggingT writer) s) m
  case result of
    (((msgs, logs), s'), m') -> pure (msgs, logs, s', m')

messageRecipient :: Raft.Message Command -> ServerId
messageRecipient (AppendEntriesReq _ to _) = to
messageRecipient (AppendEntriesRes _ to _) = to
messageRecipient (RequestVoteReq _ to _)   = to
messageRecipient (RequestVoteRes _ to _)   = to
messageRecipient (Tick to)                 = to
messageRecipient (ClientRequest to _ _)    = to
messageRecipient ClientResponse {}         = error "client is not server"

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

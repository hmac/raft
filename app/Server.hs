{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}

module Server (runServer) where

import           Control.Concurrent            (ThreadId, forkIO, threadDelay)
import           Control.Concurrent.STM.TChan  (TChan, newTChan, readTChan,
                                                writeTChan)
import           Control.Concurrent.STM.TMChan (TMChan, closeTMChan, newTMChan,
                                                readTMChan, writeTMChan)
import           Control.Concurrent.STM.TVar   (TVar, modifyTVar', newTVar,
                                                readTVar, readTVarIO, writeTVar)
import           Control.Monad.STM             (STM, atomically, retry)

import           Control.Lens                  (set)
import           Control.Monad.Logger
import           Control.Monad.State.Strict    hiding (state)
import           Data.List                     (find)
import           Data.Map.Strict               (Map)
import qualified Data.Map.Strict               as Map
import qualified Data.Text                     as T
import           Network.HTTP.Client           (Manager, defaultManagerSettings,
                                                newManager)
import           Network.Wai.Handler.Warp      (run)
import           Raft.Lens                     hiding (apply)
import           Servant
import           Servant.Client
import           System.Random

import qualified Raft                          (Message (..), handleMessage)
import           Raft.Log                      (RequestId (..), ServerId (..))
import qualified Raft.Rpc                      as Rpc
import           Raft.Server                   (MonotonicCounter (..),
                                                ServerState (..), mkServerState)

import           Api
import           Config

type StateMachineM = StateMachineT (LoggingT IO)
type RaftServer = ServerState Command CommandResponse (StateMachineT (WriterLoggingT STM))

data Config = Config { state    :: TVar (RaftServer, StateMachine)
                     , queue    :: TChan Message
                     , apply_   :: Command -> StateMachineM CommandResponse
                     , requests :: TVar (Map RequestId (TMChan (Either Rpc.AddServerRes (Rpc.ClientRes CommandResponse))))
                     }

logState :: Config -> LoggingT IO ()
logState Config { state } = do
  liftIO $ threadDelay 2000000
  (ServerState { _role, _serverTerm, _nextIndex, _matchIndex }, m) <- liftIO $ readTVarIO state
  (logDebugN . T.pack . show) (_role, _serverTerm, _nextIndex, m)

-- Apply a Raft message to the state
processMessage :: Config -> Message -> LoggingT IO ()
processMessage Config { state, queue } msg = do
  case msg of
    Raft.Tick -> pure ()
    m         -> (logInfoN . T.pack . show) m
  logs <- liftIO . atomically $ do
    (s, m) <- readTVar state
    (((msgs, s'), m'), logs) <- runWriterLoggingT (handleMessage_ s m msg)
    writeTVar state (s', m')
    mapM_ (writeTChan queue) msgs
    pure logs
  mapM_ (uncurry4 monadLoggerLog) logs
  where
    handleMessage_ :: RaftServer -> StateMachine -> Message -> WriterLoggingT STM (([Message], RaftServer), StateMachine)
    handleMessage_ server machine msg = runStateT (runStateT (Raft.handleMessage msg) server) machine
    uncurry4 :: (a -> b -> c -> d -> e) -> (a, b, c, d) -> e
    uncurry4 f (w, x, y, z) = f w x y z

processTick :: Config -> LoggingT IO ()
processTick config = processMessage config Raft.Tick

-- A server for our API
server :: Config -> Server RaftAPI
server config =
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveClientRequest config :<|>
  serveAddServer config

serveGeneric :: RaftMessage a => Config -> a -> Handler ()
serveGeneric config req = liftIO $ runLogger $ processMessage config (toRaftMessage req)

-- TODO: merge with serveClientRequest
serveAddServer :: Config -> Rpc.AddServerReq -> Handler Rpc.AddServerRes
serveAddServer config req = liftIO $ runLogger $ do
  let reqId = req^.requestId
      reqMapVar = requests config
      ServerId serverAddr = req^.newServer

  -- Normalise the server address
  serverUrl <- (ServerId . showBaseUrl) <$> parseBaseUrl serverAddr

  -- Create a channel for the response and insert it into the map
  chan <- liftIO . atomically $ do
    c <- newTMChan
    modifyTVar' reqMapVar (Map.insert reqId c)
    pure c

  logInfoN "Processing client request"
  processMessage config (toRaftMessage (set newServer serverUrl req))

  -- Wait for the response to sent through the channel
  logInfoN "Waiting for response to request"
  resp <- liftIO . atomically $ readTMChan chan
  case resp of
    Just (Left r) -> do
      logInfoN "Response found"
      pure r
    _ -> error "No response found"

serveClientRequest :: Config -> Rpc.ClientReq Command -> Handler (Rpc.ClientRes CommandResponse)
serveClientRequest config req = liftIO $ runLogger $ do
  let reqId = req^.clientRequestId
      reqMapVar = requests config

  -- Create a channel for the response and insert it into the map
  chan <- liftIO . atomically $ do
    c <- newTMChan
    modifyTVar' reqMapVar (Map.insert reqId c)
    pure c

  logInfoN "Processing client request"
  processMessage config (toRaftMessage req)

  -- Wait for the response to sent through the channel
  logInfoN "Waiting for response to request"
  resp <- liftIO . atomically $ readTMChan chan
  case resp of
    Just (Right r) -> do
      logInfoN "Response found"
      pure r
    _ -> error "No response found"

app :: Config -> Application
app config = serve raftAPI (server config)

runServer :: String -> ClusterConfig -> IO ()
runServer selfAddr config = do
  self <- parseBaseUrl selfAddr
  others <- map (ServerId . showBaseUrl) . filter (/= self) <$> mapM (parseBaseUrl . address) (nodes config)
  seed <- getStdRandom random
  (serverState, queue, reqMap) <- atomically $ do
    -- Raft recommends a 150-300ms range for election timeouts
    s <- newTVar $ mkServer ((ServerId . showBaseUrl) self) ((fromInteger . toInteger) (minNodes config)) (150, 300, seed) 20
    q <- newTChan
    m <- newTVar Map.empty
    pure (s, q, m)

  let config = Config { state = serverState, queue = queue, apply_ = apply, requests = reqMap }

  -- Logger
  _ <- forkForever $ runLogger (logState config)

  -- Clock
  _ <- forkForever $ do
    threadDelay 1000 -- 1ms
    runLogger (processTick config)

  -- HTTP connection manager
  manager <- newManager defaultManagerSettings

  -- Outbound message dispatcher
  _ <- forkForever $ runLogger (deliverMessages config manager)

  -- Inbound HTTP handler
  run (baseUrlPort self) (app config)

runLogger :: LoggingT IO a -> IO a
runLogger = runStderrLoggingT

forkForever :: IO () -> IO ThreadId
forkForever = forkIO . forever

deliverMessages :: Config -> Manager -> LoggingT IO ()
deliverMessages config manager = do
  m <- (liftIO . atomically) $ readTChan (queue config)
  case m of
    Raft.CRes r -> sendClientResponse config r
    Raft.ASRes r -> sendAddServerResponse config r
    _ -> do
      url <- (parseBaseUrl . unServerId . rpcTo) m
      let env = ClientEnv { manager = manager, baseUrl = url, cookieJar = Nothing }
      sendRpc m env config

sendClientResponse :: Config -> Rpc.ClientRes CommandResponse -> LoggingT IO ()
sendClientResponse config r = do
  let reqId = r^.responseId
      reqMapVar = requests config
  logDebugN "Processing client response"
  reqs <- liftIO $ readTVarIO reqMapVar
  case Map.lookup reqId reqs of
    Just chan -> liftIO . atomically $ writeTMChan chan (Right r)
    Nothing   -> logInfoN "No response channel found - ignoring response"

-- TODO: merge with sendClientResponse
sendAddServerResponse :: Config -> Rpc.AddServerRes -> LoggingT IO ()
sendAddServerResponse config r = do
  let reqId = r^.requestId
      reqMapVar = requests config
  logDebugN "Processing add-server response"
  reqs <- liftIO $ readTVarIO reqMapVar
  case Map.lookup reqId reqs of
    Just chan -> liftIO . atomically $ writeTMChan chan (Left r)
    Nothing   -> logInfoN "No response channel found - ignoring response"

sendRpc :: Message -> ClientEnv -> Config -> LoggingT IO ()
sendRpc msg env Config { queue } = do
  let
    (name, rpc) =
        case msg of
          Raft.RVReq r -> ("RequestVoteReq", sendRequestVoteReq r)
          Raft.AEReq r -> ("AppendEntriesReq", sendAppendEntriesReq r)
          Raft.RVRes r -> ("RequestVoteRes", sendRequestVoteRes r)
          Raft.AERes r -> ("AppendEntriesRes", sendAppendEntriesRes r)
          r            -> error $ "Unexpected rpc: " ++ show r
  res <- liftIO $ runClientM rpc env
  case res of
    Left err -> do
      -- We could re-enqueue the message for delivery, but for these RPCs it doesn't
      -- really matter, as they'll be resent periodically anyway
      --
      -- logDebugN $ T.concat ["Error sending ", name, "RPC"]
      -- liftIO . atomically $ writeTChan queue msg
      pure ()
    Right _  -> pure ()

mkServer ::
  Monad m =>
     ServerId
  -> Int
  -> (Int, Int, Int)
  -> MonotonicCounter
  -> (ServerState Command CommandResponse (StateMachineT m), StateMachine)
mkServer self minVotes electionTimeout heartbeatTimeout =
  (serverState, StateMachine mempty)
  where
    -- We start with two no-op logs, so that we can easily replicate logs to new new
    -- nodes. This is a bit of a hack until I figure out how AppendEntries should behave
    -- when you have only one entry in your log.
    serverState =
      mkServerState self [] minVotes electionTimeout heartbeatTimeout [NoOp, NoOp] apply

rpcTo :: Message -> ServerId
rpcTo msg = case msg of
  Raft.AEReq r -> r^.to
  Raft.AERes r -> r^.to
  Raft.RVReq r -> r^.to
  Raft.RVRes r -> r^.to

{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}

module Server (runServer) where

import           Control.Concurrent           (ThreadId, forkIO, threadDelay)
import           Control.Concurrent.STM.TChan (TChan, newTChan, readTChan,
                                               writeTChan)
import           Control.Concurrent.STM.TVar  (TVar, newTVar, readTVar,
                                               readTVarIO, writeTVar)
import           Control.Monad.STM            (STM, atomically, retry)

import           Control.Monad.Logger
import           Control.Monad.State.Strict hiding (state)
import           Data.List                  (find)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import qualified Data.Text                  as T
import           Data.Time.Clock            (getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime,
                                             iso8601DateFormat)
import           Network.HTTP.Client        (Manager, defaultManagerSettings,
                                             newManager)
import           Network.Wai.Handler.Warp   (run)
import           Raft.Lens                  hiding (apply)
import           Servant
import           Servant.Client
import           System.Environment         (getArgs)
import           System.Random

import qualified Raft                       (Message (..), handleMessage)
import           Raft.Log                   (RequestId (..))
import qualified Raft.Rpc                   as Rpc
import           Raft.Server                (MonotonicCounter (..), ServerId,
                                             ServerId (..), ServerState (..),
                                             mkServerState)

import           Api
import           Config

type StateMachineM = StateMachineT (LoggingT IO)
type RaftServer = ServerState Command CommandResponse (StateMachineT (WriterLoggingT STM))

data Config = Config { state    :: TVar (RaftServer, StateMachine)
                     , queue    :: TChan Message
                     , apply_   :: Command -> StateMachineM CommandResponse
                     , requests :: TVar (Map RequestId Message)
                     }

logState :: Config -> LoggingT IO ()
logState Config { state } = do
  liftIO $ threadDelay 2000000
  (ServerState { _role, _serverTerm, _nextIndex, _matchIndex }, m) <- liftIO $ readTVarIO state
  (logInfoN . T.pack . show) (_role, _serverTerm, _nextIndex, m)

-- Apply a Raft message to the state
processMessage :: Config -> Message -> LoggingT IO ()
processMessage Config { state, queue } msg = do
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
  serveClientRequest config

serveGeneric :: RaftMessage a => Config -> a -> Handler ()
serveGeneric config req = liftIO $ runLogger $ processMessage config (toRaftMessage req)

serveClientRequest :: Config -> Rpc.ClientReq Command -> Handler (Rpc.ClientRes CommandResponse)
serveClientRequest config req = liftIO $ runLogger $ do
  let reqId = req^.clientRequestId
      reqMapVar = requests config
  logInfoN "Processing client request"
  processMessage config (toRaftMessage req)
  logInfoN "Waiting for response to request"
  -- Check the map to see if the response has been placed in it. If it hasn't, retry.
  resp <- liftIO . atomically $ do
    reqMap <- readTVar reqMapVar
    case Map.lookup reqId reqMap of
      Just resp -> do
        writeTVar reqMapVar (Map.delete reqId reqMap)
        pure resp
      _ -> retry
  logInfoN "Response found"
  case fromRaftMessage resp of
    Nothing -> error "could not decode client response"
    Just r  -> pure r

app :: Config -> Application
app config = serve raftAPI (server config)

runServer :: String -> ClusterConfig -> IO ()
runServer selfName config = do
  let (selfId, others) = identifySelf selfName config
  selfUrl <- parseBaseUrl (unServerId selfId)
  seed <- getStdRandom random
  (serverState, queue, reqMap) <- atomically $ do
    -- Raft recommends a 150-300ms range for election timeouts
    s <- newTVar $ mkServer selfId others (150, 300, seed) 20
    q <- newTChan
    m <- newTVar Map.empty
    pure (s, q, m)
  let config = Config { state = serverState, queue = queue, apply_ = apply, requests = reqMap }
  _ <- forkForever $ runLogger (logState config)
  _ <- forkForever $ do
    threadDelay 1000 -- 1ms
    runLogger (processTick config)
  manager <- newManager defaultManagerSettings
  _ <- forkForever $ runLogger (deliverMessages config manager)
  run (baseUrlPort selfUrl) (app config)

runLogger :: LoggingT IO a -> IO a
runLogger = runStderrLoggingT

forkForever :: IO () -> IO ThreadId
forkForever = forkIO . forever

deliverMessages :: Config -> Manager -> LoggingT IO ()
deliverMessages config manager = do
  m <- (liftIO . atomically) $ readTChan (queue config)
  case m of
    Raft.CRes r -> sendClientResponse config r
    _ -> do
      url <- (parseBaseUrl . unServerId . rpcTo) m
      let env = ClientEnv { manager = manager, baseUrl = url, cookieJar = Nothing }
      sendRpc m env config

sendClientResponse :: Config -> Rpc.ClientRes CommandResponse -> LoggingT IO ()
sendClientResponse config r = do
  -- insert the response into the request map, using the original request ID
  let reqId = r^.responseId
      reqMapVar = requests config
  logDebugN "Processing client response"
  liftIO . atomically $ do
    reqs <- readTVar reqMapVar
    writeTVar reqMapVar (Map.insert reqId (toRaftMessage r) reqs)

-- TODO: if RPC cannot be delivered, enqueue it for retry
sendRpc :: Message -> ClientEnv -> Config -> LoggingT IO ()
sendRpc rpc env config =
  case rpc of
    Raft.RVReq r -> do
      let rpc = sendRequestVoteReq r
      res <- run rpc env
      case res of
        Left err -> logDebugN "Error sending RequestVoteReq RPC"
        Right _  -> pure ()
    Raft.AEReq r -> do
      let rpc = sendAppendEntriesReq r
      res <- run rpc env
      case res of
        Left err -> pure ()
        -- Left err -> logDebugN "Error sending AppendEntriesReq RPC"
        Right () -> pure ()
    Raft.RVRes r -> do
      let rpc = sendRequestVoteRes r
      res <- run rpc env
      case res of
        Left err -> logDebugN "Error sending RequestVoteRes RPC"
        Right _  -> pure ()
    Raft.AERes r -> do
      let rpc = sendAppendEntriesRes r
      res <- run rpc env
      case res of
        Left err -> logDebugN "Error sending AppendEntriesRes RPC"
        Right () -> pure ()
    r -> error $ "Unexpected rpc: " ++ show r
  where run rpc env = liftIO $ runClientM rpc env

identifySelf :: String -> ClusterConfig -> (ServerId, [ServerId])
identifySelf selfName (ClusterConfig nodes) =
  let mself = find ((== selfName) . name) nodes
  in case mself of
    Nothing -> error $ "Unrecognised node name: " ++ selfName
    Just self ->
      let selfId = ServerId (address self)
          others = map (ServerId . address) $ filter ((/= selfName) . name) nodes
       in (selfId, others)

mkServer ::
  Monad m =>
     ServerId
  -> [ServerId]
  -> (Int, Int, Int)
  -> MonotonicCounter
  -> (ServerState Command CommandResponse (StateMachineT m), StateMachine)
mkServer self others electionTimeout heartbeatTimeout =
  (serverState, StateMachine mempty)
  where
    serverState =
      mkServerState self others electionTimeout heartbeatTimeout NoOp apply

rpcTo :: Message -> ServerId
rpcTo msg = case msg of
  Raft.AEReq r -> r^.to
  Raft.AERes r -> r^.to
  Raft.RVReq r -> r^.to
  Raft.RVRes r -> r^.to

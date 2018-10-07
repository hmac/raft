{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}

module Server (runServer) where

import           Control.Concurrent (Chan, MVar, ThreadId, newEmptyMVar, putMVar,
                                     readMVar, takeMVar, threadDelay, writeList2Chan,
                                     modifyMVar_, newMVar, newChan, forkIO, readChan)
import Control.Concurrent.STM.TMVar (TMVar, newTMVar, takeTMVar, putTMVar, readTMVar)
import Control.Concurrent.STM.TVar (TVar, newTVar, writeTVar, readTVar)
import Control.Concurrent.STM.TChan (TChan, newTChan, writeTChan, readTChan)
import Control.Monad.STM (STM, atomically)
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
import Config

type StateMachineM = StateMachineT (LoggingT IO)
type RaftServer = ServerState Command CommandResponse (StateMachineT (WriterLoggingT STM))

data Config = Config { state    :: TVar (RaftServer, StateMachine)
                     , queue    :: TChan Message
                     , apply_   :: Command -> StateMachineM CommandResponse
                     , requests :: MVar (Map RequestId (MVar Message))
                     }

logState :: Config -> LoggingT IO ()
logState Config { state } = do
  liftIO $ threadDelay 2000000
  (ServerState { _role, _serverTerm, _nextIndex, _matchIndex }, m) <- (liftIO . atomically) $ readTVar state
  (logInfoN . T.pack . show) (_role, _serverTerm, _nextIndex, m)

-- Apply a Raft message to the state
processMessage :: Config -> Message -> LoggingT IO ()
processMessage Config { state, queue } msg = do
  logs <- liftIO . atomically $ do
    (s, m) <- readTVar state
    ((msgs, s', m'), logs) <- runWriterLoggingT (handleMessage_ s m msg)
    writeTVar state (s', m')
    mapM_ (writeTChan queue) msgs
    pure logs
  mapM_ (\(loc, src, lvl, m) -> monadLoggerLog loc src lvl m) logs
  where
    handleMessage_ :: RaftServer -> StateMachine -> Message -> WriterLoggingT STM ([Message], RaftServer, StateMachine)
    handleMessage_ server machine msg = do
      ((msgs, server'), machine') <- runStateT (runStateT (Raft.handleMessage msg) server) machine
      pure (msgs, server', machine')

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
  -- insert this request into the request map
  var <- liftIO newEmptyMVar
  liftIO $ modifyMVar_ reqMapVar (pure . Map.insert reqId var)
  logInfoN "Processing client request"
  processMessage config (toRaftMessage req)
  logInfoN "Waiting for response to request"
  resp <- liftIO $ readMVar var -- we'll block here until the response is ready
  -- now we have the response, clear it from the request map
  logInfoN "Response found"
  liftIO $ modifyMVar_ reqMapVar (pure . Map.delete reqId)
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
  (serverState, queue) <- atomically $ do
    -- Raft recommends a 150-300ms range for election timeouts
    s <- newTVar $ mkServer selfId others (150, 300, seed) 20
    q <- newTChan
    pure (s, q)
  reqMap <- newMVar Map.empty
  let config = Config { state = serverState, queue = queue, apply_ = apply, requests = reqMap }
  _ <- forkForever $  runLogger (logState config)
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
  -- we need to find the originating request and place it in the
  -- corresponding MVar in config.requests
  let reqId = r^.responseId
  logDebugN "Processing client response"
  reqs <- liftIO $ readMVar (requests config)
  case Map.lookup reqId reqs of
    -- assume that the request was made to a different node
    Nothing     -> logInfoN $ T.pack $ "Ignoring client request [" ++ show (unRequestId reqId) ++ "] - not present in map"
    Just resVar -> liftIO $ putMVar resVar (toRaftMessage r)

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

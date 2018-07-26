{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Main where

import           Control.Concurrent
import           Control.Monad.Logger
import           Control.Monad.State.Strict
import           Data.Aeson
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import qualified Data.Text                  as T (pack)
import           GHC.Generics               hiding (to)
import           Network.HTTP.Client        (Manager, defaultManagerSettings,
                                             newManager)
import           Network.Wai.Handler.Warp   (run)
import qualified Raft                       (Message (..))
import           Raft.Lens                  hiding (apply)
import           Raft.Log                   (LogEntry, LogIndex, RequestId,
                                             Term, unRequestId)
import qualified Raft.Rpc                   as Rpc
import           Raft.Server                (MonotonicCounter (..), ServerId,
                                             ServerId (..), ServerState,
                                             mkServerState)
import           Servant
import           Servant.Client
import qualified Server                     as S (Config (..), logState,
                                                  processMessage, processTick)
import           System.Environment         (getArgs)
import           System.Random

-- State machine
newtype StateMachine = StateMachine { value :: Int } deriving (Eq, Show)
type StateMachineT m = StateT StateMachine m

-- A command set for the state machine
-- TODO: could we combine these into a single Free Monad?
data Command = NoOp | Get | Set Int deriving (Eq, Show, Generic, FromJSON, ToJSON)
data CommandResponse = CRRead Int | CRUnit deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- This is how Raft will apply changes to our state machine
apply :: Monad m => Command -> StateMachineT m CommandResponse
apply NoOp    = pure CRUnit
apply Get     = CRRead <$> gets value
apply (Set n) = modify' (\s -> s { value = n }) >> pure (CRRead n)

type Message = Raft.Message Command CommandResponse

-- This lets us convert the individual API types to/from the single Raft Message type
class (RaftMessage a) where
  toRaftMessage :: a -> Message
  fromRaftMessage :: Message -> Maybe a

instance RaftMessage (Rpc.AppendEntriesReq Command) where
  toRaftMessage = Raft.AEReq
  fromRaftMessage (Raft.AEReq r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage Rpc.AppendEntriesResponse where
  toRaftMessage = Raft.AERes
  fromRaftMessage (Raft.AERes r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage (Rpc.RequestVote Command) where
  toRaftMessage = Raft.RVReq
  fromRaftMessage (Raft.RVReq r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage Rpc.RequestVoteResponse where
  toRaftMessage = Raft.RVRes
  fromRaftMessage (Raft.RVRes r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage (Rpc.ClientReq Command) where
  toRaftMessage = Raft.CReq
  fromRaftMessage (Raft.CReq r) = Just r
  fromRaftMessage _             = Nothing

instance RaftMessage (Rpc.ClientResponse CommandResponse) where
  toRaftMessage = Raft.CRes
  fromRaftMessage (Raft.CRes r) = Just r
  fromRaftMessage _             = Nothing

-- Required additional To/FromJSON instances
instance ToJSON ServerId
instance FromJSON ServerId
instance ToJSON Term
instance FromJSON Term
instance ToJSON RequestId
instance FromJSON RequestId
instance ToJSON a => ToJSON (LogEntry a)
instance FromJSON a => FromJSON (LogEntry a)
instance ToJSON a => ToJSON (Rpc.AppendEntriesReq a)
instance FromJSON a => FromJSON (Rpc.AppendEntriesReq a)
instance ToJSON Rpc.AppendEntriesResponse
instance FromJSON Rpc.AppendEntriesResponse
instance ToJSON a => ToJSON (Rpc.RequestVote a)
instance FromJSON a => FromJSON (Rpc.RequestVote a)
instance ToJSON Rpc.RequestVoteResponse
instance FromJSON Rpc.RequestVoteResponse
instance ToJSON a => ToJSON (Rpc.ClientReq a)
instance FromJSON a => FromJSON (Rpc.ClientReq a)
instance ToJSON b => ToJSON (Rpc.ClientResponse b)
instance FromJSON b => FromJSON (Rpc.ClientResponse b)

-- Our API
type RaftAPI = "AppendEntriesRequest" :> ReqBody '[JSON] (Rpc.AppendEntriesReq Command) :> Post '[JSON] ()
          :<|> "AppendEntriesResponse" :> ReqBody '[JSON] Rpc.AppendEntriesResponse :> Post '[JSON] ()
          :<|> "RequestVoteRequest" :> ReqBody '[JSON] (Rpc.RequestVote Command) :> Post '[JSON] ()
          :<|> "RequestVoteResponse" :> ReqBody '[JSON] Rpc.RequestVoteResponse :> Post '[JSON] ()
          :<|> "Client" :> ReqBody '[JSON] (Rpc.ClientReq Command) :> Post '[JSON] (Rpc.ClientResponse CommandResponse)

-- A server for our API
server :: Config -> Server RaftAPI
server config =
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveClientRequest config

serveGeneric :: RaftMessage a => Config -> a -> Handler ()
serveGeneric config req = liftIO $ runLogger $ S.processMessage config (toRaftMessage req)

serveClientRequest :: Config -> Rpc.ClientReq Command -> Handler (Rpc.ClientResponse CommandResponse)
serveClientRequest config req = liftIO $ runLogger $ do
  let reqId = req^.clientRequestId
      reqMapVar = S.requests config
  -- insert this request into the request map
  var <- liftIO newEmptyMVar
  liftIO $ modifyMVar_ reqMapVar (pure . Map.insert reqId var)
  logInfoN "Processing client request"
  S.processMessage config (toRaftMessage req)
  logInfoN "Waiting for response to request"
  resp <- liftIO $ readMVar var -- we'll block here until the response is ready
  -- now we have the response, clear it from the request map
  logInfoN "Response found"
  liftIO $ modifyMVar_ reqMapVar (pure . Map.delete reqId)
  case fromRaftMessage resp of
    Nothing -> error "could not decode client response"
    Just r  -> pure r

raftAPI :: Proxy RaftAPI
raftAPI = Proxy

app :: Config -> Application
app config = serve raftAPI (server config)

-- A client for our API
sendAppendEntriesReq :: Rpc.AppendEntriesReq Command -> ClientM ()
sendAppendEntriesRes :: Rpc.AppendEntriesResponse -> ClientM ()
sendRequestVoteReq :: Rpc.RequestVote Command -> ClientM ()
sendRequestVoteRes :: Rpc.RequestVoteResponse -> ClientM ()
sendClientRequest :: Rpc.ClientReq Command -> ClientM (Rpc.ClientResponse CommandResponse)
(sendAppendEntriesReq :<|> sendAppendEntriesRes :<|> sendRequestVoteReq :<|> sendRequestVoteRes :<|> sendClientRequest) =
  client raftAPI

-- The container for our server's persistent state
type Config = S.Config Command CommandResponse StateMachine

-- TODO: load the log from persistent storage and pass to mkServer
main :: IO ()
main = do
  [selfId] <- getArgs
  let self = ServerId (read selfId)
      url = fromJust $ Map.lookup self serverAddrs
      others = filter (/= self) (Map.keys serverAddrs)
  seed <- getStdRandom random
  serverState <- newMVar $ mkServer self others (150, 300, seed) 20 -- Raft recommends a 150-300ms range for election timeouts
  queue <- newChan
  reqMap <- newMVar Map.empty
  let config = S.Config { S.state = serverState, S.queue = queue, S.apply = apply, S.requests = reqMap }
  _ <- forkForever $  runLogger (S.logState config)
  _ <- forkForever $ do
    threadDelay 1000 -- 1ms
    runLogger (S.processTick config)
  manager <- newManager defaultManagerSettings
  _ <- forkForever $ runLogger (deliverMessages config manager)
  run (baseUrlPort url) (app config)

runLogger :: LoggingT IO a -> IO a
runLogger = runStderrLoggingT

forkForever :: IO () -> IO ThreadId
forkForever = forkIO . forever

deliverMessages :: Config -> Manager -> LoggingT IO ()
deliverMessages config manager = do
  m <- liftIO $ readChan (S.queue config)
  let url = fromJust $ Map.lookup (rpcTo m) serverAddrs
      env = ClientEnv manager url
  sendRpc m env config

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
    Raft.CRes r -> do
      -- if we get a client response, we need to find the request that it
      -- originated from and place it in the corresponding MVar in
      -- config.requests
      let reqId = r^.responseId
      logDebugN "Processing client response"
      reqs <- liftIO $ readMVar (S.requests config)
      case Map.lookup reqId reqs of
        -- assume that the request was made to a different node
        Nothing     -> logInfoN $ T.pack $ "Ignoring client request [" ++ show (unRequestId reqId) ++ "] - not present in map"
        Just resVar -> liftIO $ putMVar resVar (toRaftMessage r)
    r -> error $ "Unexpected rpc: " ++ show r
  where run rpc env = liftIO $ runClientM rpc env

serverAddrs :: Map.Map ServerId BaseUrl
serverAddrs = Map.fromList [(1, BaseUrl Http "localhost" 10501 "")
                          , (2, BaseUrl Http "localhost" 10502 "")
                          , (3, BaseUrl Http "localhost" 10503 "")]

mkServer ::
  Monad m =>
     ServerId
  -> [ServerId]
  -> (Int, Int, Int)
  -> MonotonicCounter
  -> (ServerState Command CommandResponse (StateMachineT m), StateMachine)
mkServer self others electionTimeout heartbeatTimeout =
  (serverState, StateMachine {value = 0})
  where
    serverState =
      mkServerState self others electionTimeout heartbeatTimeout NoOp apply

rpcTo :: Message -> ServerId
rpcTo msg = case msg of
  Raft.AEReq r -> r^.to
  Raft.AERes r -> r^.to
  Raft.RVReq r -> r^.to
  Raft.RVRes r -> r^.to

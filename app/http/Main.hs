{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Main where

import           Control.Concurrent
import           Control.Monad.State.Strict
import           Data.Aeson
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import qualified Data.Text                  as T (pack)
import           GHC.Generics
import           Network.HTTP.Client        (Manager, defaultManagerSettings,
                                             newManager)
import           Network.Wai.Handler.Warp   (run)
import qualified Raft                       (Message (..))
import           Raft.Log                   (LogEntry, RequestId, Term,
                                             unRequestId)
import           Raft.Rpc                   (AppendEntries, RequestVote)
import           Raft.Server                (MonotonicCounter (..), ServerId,
                                             ServerId (..), ServerState,
                                             mkServerState)
import           Servant
import           Servant.Client
import qualified Server                     as S (Config (..), printLog,
                                                  processMessage, runServer)
import           System.Environment         (getArgs)
import           System.Random

-- State machine
newtype StateMachine = StateMachine { value :: Int } deriving (Eq, Show)
type StateMachineT m = StateT StateMachine m

-- A command set for the state machine
data Command = NoOp | Get | Set Int deriving (Eq, Show, Generic, FromJSON, ToJSON)
data CommandResponse = CRRead Int | CRUnit deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- This is how Raft will apply changes to our state machine
apply :: Monad m => Command -> StateMachineT m CommandResponse
apply NoOp    = pure CRUnit
apply Get     = CRRead <$> gets value
apply (Set n) = modify' (\s -> s { value = n }) >> pure CRUnit

type Message = Raft.Message Command CommandResponse

-- The request and response types for our API
data AppendEntriesReq = AppendEntriesReq { aeReqFrom    :: ServerId
                                         , aeReqTo      :: ServerId
                                         , aeReqPayload :: AppendEntries Command
                                         } deriving (Eq, Show, Generic, FromJSON, ToJSON)
data AppendEntriesRes = AppendEntriesRes { aeResFrom    :: ServerId
                                         , aeResTo      :: ServerId
                                         , aeResPayload :: (Term, Bool)
                                         } deriving (Eq, Show, Generic, FromJSON, ToJSON)
data RequestVoteReq = RequestVoteReq { rvReqFrom    :: ServerId
                                     , rvReqTo      :: ServerId
                                     , rvReqPayload :: RequestVote Command
                                     } deriving (Eq, Show, Generic, FromJSON, ToJSON)
data RequestVoteRes = RequestVoteRes { rvResFrom    :: ServerId
                                     , rvResTo      :: ServerId
                                     , rvResPayload :: (Term, Bool)
                                     } deriving (Eq, Show, Generic, FromJSON, ToJSON)
data ClientReq = ClientReq { cReqTo      :: ServerId
                           , cReqId      :: RequestId
                           , cReqPayload :: Command
                           } deriving (Eq, Show, Generic, FromJSON, ToJSON)
data ClientRes = ClientRes { cResFrom    :: ServerId
                           , cResId      :: RequestId
                           , cResPayload :: CommandResponse
                           } deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- This lets us convert the individual API types to/from the single Raft Message type
class (RaftMessage a) where
  toRaftMessage :: a -> Message
  fromRaftMessage :: Message -> Maybe a

instance RaftMessage AppendEntriesReq where
  toRaftMessage AppendEntriesReq { aeReqFrom, aeReqTo, aeReqPayload } =
    Raft.AppendEntriesReq aeReqFrom aeReqTo aeReqPayload
  fromRaftMessage (Raft.AppendEntriesReq from to payload) =
    Just $ AppendEntriesReq from to payload
  fromRaftMessage _ = Nothing

instance RaftMessage AppendEntriesRes where
  toRaftMessage AppendEntriesRes { aeResFrom, aeResTo, aeResPayload } =
    Raft.AppendEntriesRes aeResFrom aeResTo aeResPayload
  fromRaftMessage (Raft.AppendEntriesRes from to payload) =
    Just $ AppendEntriesRes from to payload
  fromRaftMessage _ = Nothing

instance RaftMessage RequestVoteReq where
  toRaftMessage RequestVoteReq { rvReqFrom, rvReqTo, rvReqPayload } =
    Raft.RequestVoteReq rvReqFrom rvReqTo rvReqPayload
  fromRaftMessage (Raft.RequestVoteReq from to payload) =
    Just $ RequestVoteReq from to payload
  fromRaftMessage _ = Nothing

instance RaftMessage RequestVoteRes where
  toRaftMessage RequestVoteRes { rvResTo, rvResFrom, rvResPayload } =
    Raft.RequestVoteRes rvResTo rvResFrom rvResPayload
  fromRaftMessage (Raft.RequestVoteRes from to payload) =
    Just $ RequestVoteRes from to payload
  fromRaftMessage _ = Nothing

instance RaftMessage ClientReq where
  toRaftMessage ClientReq { cReqId, cReqTo, cReqPayload } =
    Raft.ClientRequest cReqTo cReqId cReqPayload
  fromRaftMessage (Raft.ClientRequest to reqId payload) =
    Just $ ClientReq to reqId payload
  fromRaftMessage _ = Nothing

instance RaftMessage ClientRes where
  toRaftMessage ClientRes { cResId, cResFrom, cResPayload } =
    Raft.ClientResponse cResFrom cResId (Right cResPayload)
  fromRaftMessage (Raft.ClientResponse to reqId response) =
    case response of
      Left err -> Nothing
      Right r  -> Just $ ClientRes to reqId r
  fromRaftMessage _ = Nothing

-- Required additional To/FromJSON instances
instance ToJSON ServerId
instance FromJSON ServerId
instance ToJSON Term
instance FromJSON Term
instance ToJSON RequestId
instance FromJSON RequestId
instance ToJSON a => ToJSON (LogEntry a)
instance FromJSON a => FromJSON (LogEntry a)
instance ToJSON a => ToJSON (AppendEntries a)
instance FromJSON a => FromJSON (AppendEntries a)
instance ToJSON a => ToJSON (RequestVote a)
instance FromJSON a => FromJSON (RequestVote a)

-- Our API
type RaftAPI = "AppendEntriesRequest" :> ReqBody '[JSON] AppendEntriesReq :> Post '[JSON] ()
          :<|> "AppendEntriesResponse" :> ReqBody '[JSON] AppendEntriesRes :> Post '[JSON] ()
          :<|> "RequestVoteRequest" :> ReqBody '[JSON] RequestVoteReq :> Post '[JSON] ()
          :<|> "RequestVoteResponse" :> ReqBody '[JSON] RequestVoteRes :> Post '[JSON] ()
          :<|> "Client" :> ReqBody '[JSON] ClientReq :> Post '[JSON] ClientRes

-- A server for our API
server :: Config -> Server RaftAPI
server config =
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveGeneric config :<|>
  serveClientRequest config

serveGeneric :: RaftMessage a => Config -> a -> Handler ()
serveGeneric config req = liftIO $ S.processMessage config (toRaftMessage req)

serveClientRequest :: Config -> ClientReq -> Handler ClientRes
serveClientRequest config req = liftIO $ do
  let reqId = cReqId req
      reqMapVar = S.requests config
  -- insert this request into the request map
  var <- newEmptyMVar
  modifyMVar_ reqMapVar (pure . Map.insert reqId var)
  S.printLog "Processing client request"
  S.processMessage config (toRaftMessage req)
  S.printLog "Waiting for response to request"
  resp <- readMVar var -- we'll block here until the response is ready
  -- now we have the response, clear it from the request map
  S.printLog "Response found"
  modifyMVar_ reqMapVar (pure . Map.delete reqId)
  case fromRaftMessage resp of
    Nothing -> error "could not decode client response"
    Just r  -> pure r

raftAPI :: Proxy RaftAPI
raftAPI = Proxy

app :: Config -> Application
app config = serve raftAPI (server config)

-- A client for our API
sendAppendEntriesReq :: AppendEntriesReq -> ClientM ()
sendAppendEntriesRes :: AppendEntriesRes -> ClientM ()
sendRequestVoteReq :: RequestVoteReq -> ClientM ()
sendRequestVoteRes :: RequestVoteRes -> ClientM ()
sendClientRequest :: ClientReq -> ClientM ClientRes
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
  _ <- S.runServer config
  manager <- newManager defaultManagerSettings
  _ <- forkIO (deliverMessages config manager)
  run (baseUrlPort url) (app config)

deliverMessages :: Config -> Manager -> IO ()
deliverMessages config manager = forever $ do
  m <- readChan (S.queue config)
  let url = fromJust $ Map.lookup (rpcTo m) serverAddrs
      env = ClientEnv manager url
  sendRpc m env config

-- TODO: if RPC cannot be delivered, enqueue it for retry
sendRpc :: Message -> ClientEnv -> Config -> IO ()
sendRpc rpc env config =
  case rpc of
    r@Raft.RequestVoteReq{} -> do
      let rpc = (sendRequestVoteReq . fromJust . fromRaftMessage) r
      res <- runClientM rpc env
      case res of
        Left err -> putStrLn "Error sending RequestVoteReq RPC"
        Right _  -> pure ()
    r@Raft.AppendEntriesReq{} -> do
      let rpc = (sendAppendEntriesReq . fromJust . fromRaftMessage) r
      res <- runClientM rpc env
      case res of
        Left err -> putStrLn "Error sending AppendEntriesReq RPC"
        Right () -> pure ()
    r@Raft.RequestVoteRes{} -> do
      let rpc = (sendRequestVoteRes . fromJust . fromRaftMessage) r
      res <- runClientM rpc env
      case res of
        Left err -> putStrLn "Error sending RequestVoteRes RPC"
        Right _  -> pure ()
    r@Raft.AppendEntriesRes{} -> do
      let rpc = (sendAppendEntriesRes . fromJust . fromRaftMessage) r
      res <- runClientM rpc env
      case res of
        Left err -> putStrLn "Error sending AppendEntriesRes RPC"
        Right () -> pure ()
    r@(Raft.ClientResponse _ reqId _) -> do
      -- if we get a client response, we need to find the request that it
      -- originated from and place it in the corresponding MVar in
      -- config.requests
      S.printLog "Processing client response"
      reqs <- readMVar (S.requests config)
      case Map.lookup reqId reqs of
        Nothing     -> do
          -- assume that the request was made to a different node
          S.printLog $ T.pack $ "Ignoring client request [" ++ show (unRequestId reqId) ++ "] - not present in map"
        Just resVar -> putMVar resVar r
    r -> error $ "Unexpected rpc: " ++ show r

serverAddrs :: Map.Map ServerId BaseUrl
serverAddrs = Map.fromList [(1, BaseUrl Http "localhost" 10501 "")
                          , (2, BaseUrl Http "localhost" 10502 "")
                          , (3, BaseUrl Http "localhost" 10503 "")]

mkServer ::
     ServerId
  -> [ServerId]
  -> (Int, Int, Int)
  -> MonotonicCounter
  -> (ServerState Command, StateMachine)
mkServer self others electionTimeout heartbeatTimeout =
  (serverState, StateMachine {value = 0})
  where
    serverState =
      mkServerState self others electionTimeout heartbeatTimeout NoOp

rpcTo :: Message -> ServerId
rpcTo (Raft.AppendEntriesReq _ to _) = to
rpcTo (Raft.AppendEntriesRes _ to _) = to
rpcTo (Raft.RequestVoteReq _ to _)   = to
rpcTo (Raft.RequestVoteRes _ to _)   = to

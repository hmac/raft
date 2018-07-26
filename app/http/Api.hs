{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE TypeOperators     #-}

module Api where

import           Control.Monad.State.Strict
import           Data.Aeson                 (FromJSON, ToJSON)
import           GHC.Generics
import           Servant
import           Servant.Client             (client)

import qualified Raft                       (Message (..))
import           Raft.Log                   (LogEntry, LogIndex, RequestId,
                                             Term, unRequestId)
import qualified Raft.Rpc                   as Rpc
import           Raft.Server                (MonotonicCounter (..), ServerId,
                                             ServerId (..), ServerState,
                                             mkServerState)

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

instance RaftMessage Rpc.AppendEntriesRes where
  toRaftMessage = Raft.AERes
  fromRaftMessage (Raft.AERes r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage Rpc.RequestVoteReq where
  toRaftMessage = Raft.RVReq
  fromRaftMessage (Raft.RVReq r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage Rpc.RequestVoteRes where
  toRaftMessage = Raft.RVRes
  fromRaftMessage (Raft.RVRes r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage (Rpc.ClientReq Command) where
  toRaftMessage = Raft.CReq
  fromRaftMessage (Raft.CReq r) = Just r
  fromRaftMessage _             = Nothing

instance RaftMessage (Rpc.ClientRes CommandResponse) where
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
instance ToJSON Rpc.AppendEntriesRes
instance FromJSON Rpc.AppendEntriesRes
instance ToJSON Rpc.RequestVoteReq
instance FromJSON Rpc.RequestVoteReq
instance ToJSON Rpc.RequestVoteRes
instance FromJSON Rpc.RequestVoteRes
instance ToJSON a => ToJSON (Rpc.ClientReq a)
instance FromJSON a => FromJSON (Rpc.ClientReq a)
instance ToJSON b => ToJSON (Rpc.ClientRes b)
instance FromJSON b => FromJSON (Rpc.ClientRes b)

-- Our API
type RaftAPI = "AppendEntriesRequest" :> ReqBody '[JSON] (Rpc.AppendEntriesReq Command) :> Post '[JSON] ()
          :<|> "AppendEntriesRes" :> ReqBody '[JSON] Rpc.AppendEntriesRes :> Post '[JSON] ()
          :<|> "RequestVoteRequest" :> ReqBody '[JSON] Rpc.RequestVoteReq :> Post '[JSON] ()
          :<|> "RequestVoteRes" :> ReqBody '[JSON] Rpc.RequestVoteRes :> Post '[JSON] ()
          :<|> "Client" :> ReqBody '[JSON] (Rpc.ClientReq Command) :> Post '[JSON] (Rpc.ClientRes CommandResponse)

raftAPI :: Proxy RaftAPI
raftAPI = Proxy

-- A client for our API
(sendAppendEntriesReq :<|> sendAppendEntriesRes :<|> sendRequestVoteReq :<|> sendRequestVoteRes :<|> sendClientRequest) =
  client raftAPI

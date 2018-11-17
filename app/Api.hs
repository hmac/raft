{-# OPTIONS_GHC -Wno-missing-signatures #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE TypeOperators     #-}

module Api where

import           Control.Monad.State.Strict
import           Data.Aeson                 (FromJSON, ToJSON)
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HM
import           GHC.Generics
import           Servant
import           Servant.Client             (client)

import qualified Raft                       (Message (..))
import qualified Raft.Rpc                   as Rpc

-- State machine
newtype StateMachine = StateMachine (HashMap String String) deriving (Eq, Show)
type StateMachineT m = StateT StateMachine m

-- A command set for the state machine
-- TODO: could we combine these into a single Free Monad?
data Command
  = NoOp
  | Get String
  | Set String String
  deriving (Eq, Show, Generic, FromJSON, ToJSON)
data CommandResponse
  = CRRead (Maybe String)
  | CRUnit
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- This is how Raft will apply changes to our state machine
apply :: Monad m => Command -> StateMachineT m CommandResponse
apply NoOp = pure CRUnit
apply (Get key) = do
  StateMachine m <- get
  (pure . CRRead) $ HM.lookup key m
apply (Set k v) = do
  modify' $ \(StateMachine m) -> StateMachine (HM.insert k v m)
  (pure . CRRead) $ Just v

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

instance RaftMessage Rpc.AddServerReq where
  toRaftMessage = Raft.ASReq
  fromRaftMessage (Raft.ASReq r) = Just r
  fromRaftMessage _              = Nothing

instance RaftMessage Rpc.AddServerRes where
  toRaftMessage = Raft.ASRes
  fromRaftMessage (Raft.ASRes r) = Just r
  fromRaftMessage _              = Nothing

-- Our API
type RaftAPI = "AppendEntriesRequest" :> ReqBody '[JSON] (Rpc.AppendEntriesReq Command) :> Post '[JSON] ()
          :<|> "AppendEntriesRes" :> ReqBody '[JSON] Rpc.AppendEntriesRes :> Post '[JSON] ()
          :<|> "RequestVoteRequest" :> ReqBody '[JSON] Rpc.RequestVoteReq :> Post '[JSON] ()
          :<|> "RequestVoteRes" :> ReqBody '[JSON] Rpc.RequestVoteRes :> Post '[JSON] ()
          :<|> "Client" :> ReqBody '[JSON] (Rpc.ClientReq Command) :> Post '[JSON] (Rpc.ClientRes CommandResponse)
          :<|> "AddServer" :> ReqBody '[JSON] Rpc.AddServerReq :> Post '[JSON] Rpc.AddServerRes

raftAPI :: Proxy RaftAPI
raftAPI = Proxy

-- A client for our API
(sendAppendEntriesReq :<|> sendAppendEntriesRes :<|> sendRequestVoteReq :<|> sendRequestVoteRes :<|> sendClientRequest :<|> sendAddServer) =
  client raftAPI

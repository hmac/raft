{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Raft.Rpc (
  AppendEntriesReq(..)
, AppendEntriesRes(..)
, RequestVoteReq(..)
, RequestVoteRes(..)
, ClientReq(..)
, ClientResponse(..))
where

import           Control.Lens
import           Data.Binary  (Binary)
import qualified Data.Text    as T
import           GHC.Generics (Generic)
import           Raft.Log
import           Raft.Server

data AppendEntriesReq a = AppendEntriesReq
  -- ID of sender
  { _appendEntriesReqFrom         :: ServerId
  -- ID of receiver
  , _appendEntriesReqTo           :: ServerId
  -- leader's term
  , _appendEntriesReqLeaderTerm   :: Term
  -- index of log entry immediately preceding new ones
  , _appendEntriesReqPrevLogIndex :: LogIndex
  -- term of prevLogIndex entry
  , _appendEntriesReqPrevLogTerm  :: Term
  -- log entries to store (empty for heartbeat)
  , _appendEntriesReqEntries      :: [LogEntry a]
  -- leader's commitIndex
  , _appendEntriesReqLeaderCommit :: LogIndex
  } deriving (Generic)

instance Binary a => Binary (AppendEntriesReq a)
deriving instance (Show a) => Show (AppendEntriesReq a)
deriving instance (Eq a) => Eq (AppendEntriesReq a)

data AppendEntriesRes = AppendEntriesRes
  -- ID of sender
  { _appendEntriesResFrom     :: ServerId
  -- ID of receiver
  , _appendEntriesResTo       :: ServerId
  -- the responding server's term
  , _appendEntriesResTerm     :: Term
  -- whether the AppendEntries RPC was successful
  , _appendEntriesResSuccess  :: Bool
  -- index of the latest entry in the responding server's log
  , _appendEntriesResLogIndex :: LogIndex
  } deriving (Generic, Eq, Show)

instance Binary AppendEntriesRes

data RequestVoteReq = RequestVoteReq
  -- ID of sender
  { _requestVoteReqFrom          :: ServerId
  -- ID of receiver
  , _requestVoteReqTo            :: ServerId
  -- candidate's term
  , _requestVoteReqCandidateTerm :: Term
  -- index of candidate's last log entry
  , _requestVoteReqLastLogIndex  :: LogIndex
  -- term of candidate's last log entry
  , _requestVoteReqLastLogTerm   :: Term
  } deriving (Generic, Eq, Show)

instance Binary RequestVoteReq

data RequestVoteRes = RequestVoteRes
  -- ID of sender
  { _from               :: ServerId
  -- ID of receiver
  , _to                 :: ServerId
  -- the responding server's term
  , _voterTerm          :: Term
  -- whether the vote was granted
  , _requestVoteSuccess :: Bool
  } deriving (Generic, Eq, Show)

instance Binary RequestVoteRes

data ClientReq a = ClientReq
  { _requestPayload  :: a
  , _clientRequestId :: RequestId
  } deriving (Generic)

instance Binary a => Binary (ClientReq a)
deriving instance (Show a) => Show (ClientReq a)
deriving instance (Eq a) => Eq (ClientReq a)

-- TODO: rename to ClientRes
data ClientResponse b = ClientResponse
  { _responsePayload :: Either T.Text b
  , _responseId      :: RequestId
  } deriving (Generic)

instance Binary b => Binary (ClientResponse b)
deriving instance (Show b) => Show (ClientResponse b)
deriving instance (Eq b) => Eq (ClientResponse b)

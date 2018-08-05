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
, ClientRes(..))
where

import           Control.Lens
import           Data.Binary  (Binary)
import qualified Data.Text    as T
import           GHC.Generics (Generic)
import           Raft.Log
import           Raft.Server

data AppendEntriesReq a = AppendEntriesReq
  -- ID of sender
  { _from         :: ServerId
  -- ID of receiver
  , _to           :: ServerId
  -- leader's term
  , _leaderTerm   :: Term
  -- index of log entry immediately preceding new ones
  , _prevLogIndex :: LogIndex
  -- term of prevLogIndex entry
  , _prevLogTerm  :: Term
  -- log entries to store (empty for heartbeat)
  , _entries      :: [LogEntry a]
  -- leader's commitIndex
  , _leaderCommit :: LogIndex
  } deriving (Generic)

instance Binary a => Binary (AppendEntriesReq a)
deriving instance (Show a) => Show (AppendEntriesReq a)
deriving instance (Eq a) => Eq (AppendEntriesReq a)

data AppendEntriesRes = AppendEntriesRes
  -- ID of sender
  { _from     :: ServerId
  -- ID of receiver
  , _to       :: ServerId
  -- the responding server's term
  , _term     :: Term
  -- whether the AppendEntries RPC was successful
  , _success  :: Bool
  -- index of the latest entry in the responding server's log
  , _logIndex :: LogIndex
  } deriving (Generic, Eq, Show)

instance Binary AppendEntriesRes

data RequestVoteReq = RequestVoteReq
  -- ID of sender
  { _from          :: ServerId
  -- ID of receiver
  , _to            :: ServerId
  -- candidate's term
  , _candidateTerm :: Term
  -- index of candidate's last log entry
  , _lastLogIndex  :: LogIndex
  -- term of candidate's last log entry
  , _lastLogTerm   :: Term
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

data ClientRes b
  = ClientResSuccess { _responsePayload :: Either T.Text b
                     , _responseId      :: RequestId }
  | ClientResFailure { _responseError :: T.Text
                     , _responseId    :: RequestId
                     , _leader        :: Maybe ServerId }
  deriving (Generic)

instance Binary b => Binary (ClientRes b)
deriving instance (Show b) => Show (ClientRes b)
deriving instance (Eq b) => Eq (ClientRes b)

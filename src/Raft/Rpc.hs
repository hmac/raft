{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Raft.Rpc (
  AppendEntriesReq(..)
, AppendEntriesResponse(..)
, RequestVote(..)
, RequestVoteResponse(..)
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

-- TODO: rename to AppendEntriesRes
data AppendEntriesResponse = AppendEntriesResponse
  -- ID of sender
  { _appendEntriesResponseFrom     :: ServerId
  -- ID of receiver
  , _appendEntriesResponseTo       :: ServerId
  -- the responding server's term
  , _appendEntriesResponseTerm     :: Term
  -- whether the AppendEntries RPC was successful
  , _appendEntriesResponseSuccess  :: Bool
  -- index of the latest entry in the responding server's log
  , _appendEntriesResponseLogIndex :: LogIndex
  } deriving (Generic, Eq, Show)

instance Binary AppendEntriesResponse

-- TODO: rename to RequestVoteReq
-- TODO: remove type parameter - not needed?
data RequestVote a = RequestVote
  -- ID of sender
  { _requestVoteFrom          :: ServerId
  -- ID of receiver
  , _requestVoteTo            :: ServerId
  -- candidate's term
  , _requestVoteCandidateTerm :: Term
  -- index of candidate's last log entry
  , _requestVoteLastLogIndex  :: LogIndex
  -- term of candidate's last log entry
  , _requestVoteLastLogTerm   :: Term
  } deriving (Generic)

instance Binary (RequestVote a)
deriving instance (Show a) => Show (RequestVote a)
deriving instance (Eq a) => Eq (RequestVote a)

-- TODO: rename to RequestVoteRes
data RequestVoteResponse = RequestVoteResponse
  -- ID of sender
  { _from               :: ServerId
  -- ID of receiver
  , _to                 :: ServerId
  -- the responding server's term
  , _voterTerm          :: Term
  -- whether the vote was granted
  , _requestVoteSuccess :: Bool
  } deriving (Generic, Eq, Show)

instance Binary RequestVoteResponse

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

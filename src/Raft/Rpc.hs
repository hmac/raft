{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}

module Raft.Rpc where

import           Control.Lens
import           Data.Binary  (Binary)
import           GHC.Generics (Generic)
import           Raft.Log
import           Raft.Server

data AppendEntries a = AppendEntries
  -- leader's term
  { _LeaderTerm   :: Term
  -- so follower can redirect clients
  , _LeaderId     :: ServerId
  -- index of log entry immediately preceding new ones
  , _PrevLogIndex :: LogIndex
  -- term of prevLogIndex entry
  , _PrevLogTerm  :: Term
  -- log entries to store (empty for heartbeat)
  , _Entries      :: [LogEntry a]
  -- leader's commitIndex
  , _LeaderCommit :: LogIndex
  } deriving (Generic)

instance Binary a => Binary (AppendEntries a)
deriving instance (Show a) => Show (AppendEntries a)

makeLenses ''AppendEntries

data RequestVote a = RequestVote
  -- candidate's term
  { _CandidateTerm :: Term
  -- candidate requesting vote
  , _CandidateId   :: ServerId
  -- index of candidate's last log entry
  , _LastLogIndex  :: LogIndex
  -- term of candidate's last log entry
  , _LastLogTerm   :: Term
  } deriving (Generic)

instance Binary (RequestVote a)
deriving instance (Show a) => Show (RequestVote a)

makeLenses ''RequestVote

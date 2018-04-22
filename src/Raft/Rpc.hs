{-# LANGUAGE StandaloneDeriving #-}

module Raft.Rpc where

import           Raft.Log
import           Raft.Server

data AppendEntries a = AppendEntries
  -- leader's term
  { aeTerm         :: Term
  -- so follower can redirect clients
  , aeLeaderId     :: ServerId
  -- index of log entry immediately preceding new ones
  , aePrevLogIndex :: LogIndex
  -- term of prevLogIndex entry
  , aePrevLogTerm  :: Term
  -- log entries to store (empty for heartbeat)
  , aeEntries      :: [LogEntry a]
  -- leader's commitIndex
  , aeLeaderCommit :: LogIndex
  }

deriving instance (Show a) => Show (AppendEntries a)

data RequestVote a = RequestVote
  -- candidate's term
  { rvTerm         :: Term
  -- candidate requesting vote
  , rvCandidateId  :: ServerId
  -- index of candidate's last log entry
  , rvLastLogIndex :: LogIndex
  -- term of candidate's last log entry
  , rvLastLogTerm  :: Term
  }

deriving instance (Show a) => Show (RequestVote a)

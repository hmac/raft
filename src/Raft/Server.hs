{-# LANGUAGE StandaloneDeriving #-}

module Raft.Server where

import           Data.Map.Strict as Map
import           Raft.Log

-- Server IDs start at 0 and increase monotonically
type ServerId = Int
type Tock = Int

data Role = Follower | Candidate | Leader deriving (Eq, Show)

data ServerState a = ServerState
  {
  -- the server's ID
  sId                :: ServerId
  -- all other server IDs (TODO: this needs to be stored in the state machine)
  , sServerIds       :: [ServerId]
  -- latest term server has seen (initialised to 0, increases monotonically)
  , sCurrentTerm     :: Term
  -- Candidate ID that received vote in current term (or Nothing)
  , sVotedFor        :: Maybe ServerId
  -- log entries (first index is 1)
  , sLog             :: Log a
  -- index of highest log entry known to be committed (initialised to 0,
  -- increases monotonically)
  , sCommitIndex     :: LogIndex
  -- index of highest log entry applied to state machine (initialised to 0,
  -- increases monotonically)
  , sLastApplied     :: LogIndex
  -- an arbitrary counter used for timeouts (initialised to 0, increases
  -- monotonically)
  , sTock            :: Tock
  -- value of sTock at which server becomes candidate
  , sElectionTimeout :: Tock
  -- current role
  , sRole            :: Role
  -- [LEADER] for each server, index of the next log entry to send to that server
  -- (initialised to last log index + 1)
  , sNextIndex       :: Map.Map ServerId LogIndex
  -- [LEADER] for each server, index of the highest log entry known to be replicated on
  -- server (initialised to 0, increases monotonically)
  , sMatchIndex      :: Map.Map ServerId LogIndex
  -- [CANDIDATE] the number of votes received (initialised to 0, increases
  -- monotonically)
  , sVotesReceived   :: Int
  }

deriving instance (Show a) => Show (ServerState a)

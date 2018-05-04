{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}

module Raft.Server where

import           Control.Lens
import           Data.Foldable   (foldl')
import qualified Data.Map.Strict as Map
import           Raft.Log

-- Server IDs start at 0 and increase monotonically
type ServerId = Int
type Tock = Int

data Role = Follower | Candidate | Leader deriving (Eq, Show)

data ServerState a = ServerState
  {
  -- the server's ID
  _selfId             :: ServerId
  -- all other server IDs (TODO: this needs to be stored in the state machine)
  , _serverIds        :: [ServerId]
  -- latest term server has seen (initialised to 0, increases monotonically)
  , _serverTerm       :: Term
  -- Candidate ID that received vote in current term (or Nothing)
  , _votedFor         :: Maybe ServerId
  -- log entries (first index is 1)
  , _entryLog         :: Log a
  -- index of highest log entry known to be committed (initialised to 0,
  -- increases monotonically)
  , _commitIndex      :: LogIndex
  -- index of highest log entry applied to state machine (initialised to 0,
  -- increases monotonically)
  , _lastApplied      :: LogIndex
  -- an arbitrary counter used for timeouts (initialised to 0, increases
  -- monotonically)
  , _electionTimer    :: Tock
  -- value of _electionTimer at which server becomes candidate
  , _electionTimeout  :: Tock
  -- an arbitrary counter used for hearbeats (initialised to 0, increases
  -- monotonically)
  , _heartbeatTimer   :: Tock
  -- value of _heartbeatTimer at which leader will send heartbeat RFCs
  , _heartbeatTimeout :: Tock
  -- current role
  , _role             :: Role
  -- [LEADER] for each server, index of the next log entry to send to that server
  -- (initialised to last log index + 1)
  , _nextIndex        :: Map.Map ServerId LogIndex
  -- [LEADER] for each server, index of the highest log entry known to be replicated on
  -- server (initialised to 0, increases monotonically)
  , _matchIndex       :: Map.Map ServerId LogIndex
  -- [CANDIDATE] the number of votes received (initialised to 0, increases
  -- monotonically)
  , _votesReceived    :: Int
  }

deriving instance (Show a) => Show (ServerState a)

makeLenses ''ServerState

mkServerState :: ServerId -> [ServerId] -> Tock -> Tock -> a -> ServerState a
mkServerState self others electionTimeout heartbeatTimeout firstCommand = s
  where s = ServerState { _selfId = self
                        , _serverIds = others
                        , _serverTerm = t0
                        , _votedFor = Nothing
                        , _entryLog = emptyLog
                        , _commitIndex = 0
                        , _lastApplied = 0
                        , _electionTimer = 0
                        , _electionTimeout = electionTimeout
                        , _heartbeatTimer = 0
                        , _heartbeatTimeout = heartbeatTimeout
                        , _role = Follower
                        , _nextIndex = initialMap
                        , _matchIndex = initialMap
                        , _votesReceived = 0 }
        t0 = Term { unTerm = 0 }
        emptyLog = [LogEntry { _Index = 0, _Term = t0, _Command = firstCommand }]
        initialMap = foldl' (\m sid -> Map.insert sid 0 m) Map.empty others

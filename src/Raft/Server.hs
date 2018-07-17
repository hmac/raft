{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}

module Raft.Server where

import           Control.Lens
import           Data.Binary         (Binary)
import           Data.Foldable       (foldl')
import           Data.Hashable       (Hashable)
import qualified Data.HashMap.Strict as Map
import           Data.Typeable       (Typeable)
import           GHC.Generics
import           System.Random

import           Raft.Log

-- Server IDs start at 0 and increase monotonically
newtype ServerId = ServerId
  { unServerId :: Int
  } deriving (Eq, Ord, Num, Show, Generic, Hashable, Typeable, Binary)

newtype MonotonicCounter = MonotonicCounter
  { unMonotonicCounter :: Integer
  } deriving (Eq, Ord, Num, Show)

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
  , _electionTimer    :: MonotonicCounter
  -- value of _electionTimer at which server becomes candidate
  , _electionTimeout  :: Timeout
  -- an arbitrary counter used for hearbeats (initialised to 0, increases
  -- monotonically)
  , _heartbeatTimer   :: MonotonicCounter
  -- value of _heartbeatTimer at which leader will send heartbeat RFCs
  , _heartbeatTimeout :: MonotonicCounter
  -- current role
  , _role             :: Role
  -- [LEADER] for each server, index of the next log entry to send to that server
  -- (initialised to last log index + 1)
  , _nextIndex        :: Map.HashMap ServerId LogIndex
  -- [LEADER] for each server, index of the highest log entry known to be replicated on
  -- server (initialised to 0, increases monotonically)
  , _matchIndex       :: Map.HashMap ServerId LogIndex
  -- [CANDIDATE] the number of votes received (initialised to 0, increases
  -- monotonically)
  , _votesReceived    :: Int
  }

deriving instance (Show a) => Show (ServerState a)

data Timeout = Timeout { low :: Int, high :: Int, gen :: StdGen } deriving (Show)

nextTimeout :: Timeout -> Timeout
nextTimeout t = let (_, gen') = randomR (low t, high t) (gen t)
                 in t { gen = gen' }

mkTimeout :: Int -> Int -> Int -> Timeout
mkTimeout l h seed = Timeout { low = l, high = h, gen = mkStdGen seed }

readTimeout :: Timeout -> MonotonicCounter
readTimeout t = MonotonicCounter (toInteger r)
  where r = fst $ randomR (low t, high t) (gen t)

makeLenses ''ServerState

mkServerState :: ServerId -> [ServerId] -> (Int, Int, Int) -> MonotonicCounter -> a -> ServerState a
mkServerState self others (electLow, electHigh, electSeed) hbTimeout firstCommand = s
  where s = ServerState { _selfId = self
                        , _serverIds = others
                        , _serverTerm = 0
                        , _votedFor = Nothing
                        , _entryLog = emptyLog
                        , _commitIndex = 0
                        , _lastApplied = 0
                        , _electionTimer = 0
                        , _electionTimeout = mkTimeout electLow electHigh electSeed
                        , _heartbeatTimer = 0
                        , _heartbeatTimeout = hbTimeout
                        , _role = Follower
                        , _nextIndex = initialMap
                        , _matchIndex = initialMap
                        , _votesReceived = 0 }
        emptyLog = [LogEntry { _Index = 0, _Term = 0, _Command = firstCommand, _RequestId = 0 }]
        initialMap = foldl' (\m sid -> Map.insert sid 0 m) Map.empty others

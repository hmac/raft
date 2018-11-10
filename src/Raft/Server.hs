{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

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

newtype MonotonicCounter = MonotonicCounter
  { unMonotonicCounter :: Integer
  } deriving (Eq, Ord, Num, Show)

data Role = Follower | Candidate | Leader deriving (Eq, Show)

data ServerState a b machineM = ServerState
  -- the server's ID
  { _selfId           :: ServerId
  -- all other server IDs (TODO: this needs to be stored in the state machine)
  , _serverIds        :: [ServerId]
  -- Who the server thinks is the current leader. This is only used for redirecting client
  -- requests and isn't guaranteed to be accurate.
  , _leaderId         :: Maybe ServerId
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
  -- The state machine function. This takes commands and applies them to the
  -- state machine via the machineM monad
  , _apply            :: a -> machineM b
  -- [LEADER] The current status of a new server addition, if one is being added.
  , _serverAddition   :: Maybe ServerAddition
  -- The minimum votes required for the node to declare itself leader
  -- We set this to 1 for the first node in the cluster, then 2 for every subsequent node.
  -- This prevents new joiners from forming their own 1-node cluster and refusing to join
  -- the existing one.
  , _minVotes         :: Int
  }

data ServerAddition = ServerAddition
  { _newServer    :: ServerId
  , _maxRounds    :: Int
  , _currentRound :: Int
  , _roundIndex   :: LogIndex
  , _roundTimer   :: MonotonicCounter
  , _requestId    :: RequestId
  }

data Timeout = Timeout { low :: Int, high :: Int, gen :: StdGen } deriving (Show)

instance Show (ServerState a b m) where
  show s = "ServerState { " ++
    "selfId = " ++ show (_selfId s) ++ ", " ++
    "serverId = " ++ show (_serverIds s) ++ ", " ++
    "votedFor = " ++ show (_votedFor s) ++ "}"

nextTimeout :: Timeout -> Timeout
nextTimeout t = let (_, gen') = randomR (low t, high t) (gen t)
                 in t { gen = gen' }

mkTimeout :: Int -> Int -> Int -> Timeout
mkTimeout l h seed = Timeout { low = l, high = h, gen = mkStdGen seed }

readTimeout :: Timeout -> MonotonicCounter
readTimeout t = MonotonicCounter (toInteger r)
  where r = fst $ randomR (low t, high t) (gen t)

mkServerState :: ServerId -> [ServerId] -> Int -> (Int, Int, Int) -> MonotonicCounter -> [a] -> (a -> m b) -> ServerState a b m
mkServerState self others minVotes (electLow, electHigh, electSeed) hbTimeout initialCommands apply = s
  where s = ServerState { _selfId = self
                        , _serverIds = others
                        , _leaderId = Nothing
                        , _serverTerm = 0
                        , _votedFor = Nothing
                        , _entryLog = initialLogs
                        , _commitIndex = 0
                        , _lastApplied = 0
                        , _electionTimer = 0
                        , _electionTimeout = mkTimeout electLow electHigh electSeed
                        , _heartbeatTimer = 0
                        , _heartbeatTimeout = hbTimeout
                        , _role = Follower
                        , _nextIndex = initialMap
                        , _matchIndex = initialMap
                        , _votesReceived = 0
                        , _apply = apply
                        , _serverAddition = Nothing
                        , _minVotes = minVotes
                        }
        initialLogs = map (\(cmd, i) -> LogEntry { _index = i, _term = 0, _payload = LogCommand cmd, _requestId = RequestId i }) (zip initialCommands [0..(toInteger (length initialCommands))])
        initialMap = foldl' (\m sid -> Map.insert sid 0 m) Map.empty others

{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE StandaloneDeriving         #-}

module Raft (handleMessage, Message(..), ServerT) where

import           Control.Lens                (at, use, (%=), (+=), (.=), (<+=),
                                              (?=), (^.))
import           Control.Monad.Log
import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import           Data.Binary                 (Binary)
import qualified Data.HashMap.Strict         as Map
import           Data.Maybe                  (fromJust, isNothing)
import           Data.Ratio                  ((%))
import qualified Data.Text                   as T
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)
import           Prelude                     hiding (log, (!!))
import           Safe                        (atMay)
import qualified Safe                        (at)

import           Raft.Log
import           Raft.Rpc
import           Raft.Server

-- alias Safe.at as !!
(!!) :: [a] -> Int -> a
(!!) = Safe.at

data Message a =
    AppendEntriesReq ServerId ServerId (AppendEntries a)
  | AppendEntriesRes ServerId ServerId (Term, Bool)
  | RequestVoteReq ServerId ServerId (RequestVote a)
  | RequestVoteRes ServerId ServerId (Term, Bool)
  | Tick ServerId
  | ClientRequest ServerId RequestId a
  | ClientResponse ServerId RequestId a Bool
  deriving (Generic)

deriving instance Typeable a => Typeable (Message a)
instance Binary a => Binary (Message a)

deriving instance Show a => Show (Message a)
deriving instance Eq a => Eq (Message a)

type ExtServerT a m = PureLoggingT [T.Text] (StateT (ServerState a) m)
type ServerT a m = WriterT [Message a] (ExtServerT a m)

-- The entrypoint to a Raft node
-- This function takes a Message and handles it, updating the node's state and
-- generating any messages to send in response.
-- This is the only function exported from this module
handleMessage ::
     MonadPlus m => (a -> m ()) -> Message a -> ExtServerT a m [Message a]
handleMessage apply m = snd <$> runWriterT go
  where
    go = checkForNewLeader m >> applyCommittedLogEntries apply >> handler
    handler =
      case m of
        Tick _                     -> handleTick apply
        AppendEntriesReq from to r -> handleAppendEntriesReq from to r
        AppendEntriesRes from to r -> handleAppendEntriesRes from to r apply
        RequestVoteReq from to r   -> handleRequestVoteReq from to r
        RequestVoteRes from to r   -> handleRequestVoteRes from to r
        ClientRequest _ reqId r    -> handleClientRequest reqId r

checkForNewLeader :: MonadPlus m => Message a -> ServerT a m ()
checkForNewLeader m =
  case m of
    AppendEntriesReq _ _ r      -> go (r^.leaderTerm)
    AppendEntriesRes _ _ (t, _) -> go t
    RequestVoteReq _ _ r        -> go (r^.candidateTerm)
    RequestVoteRes _ _ (t, _)   -> go t
    _                           -> pure ()
  where
    go :: MonadPlus m => Term -> ServerT a m ()
    go t = do
      currentTerm <- use serverTerm
      when (t > currentTerm) (convertToFollower t)

handleTick :: MonadPlus m => (a -> m ()) -> ServerT a m ()
handleTick apply = do
  -- if election timeout elapses without receiving AppendEntries RPC from current
  -- leader or granting vote to candidate, convert to candidate
  applyCommittedLogEntries apply
  electionTimer' <- electionTimer <+= 1
  heartbeatTimer' <- heartbeatTimer <+= 1
  role <- use role
  electTimeout <- use electionTimeout
  hbTimeout <- use heartbeatTimeout
  when (electionTimer' >= electTimeout && role /= Leader) convertToCandidate
  when (heartbeatTimer' >= hbTimeout && role == Leader) sendHeartbeats

handleAppendEntriesReq :: MonadPlus m => ServerId -> ServerId -> AppendEntries a -> ServerT a m ()
handleAppendEntriesReq from to r = do
  currentTerm <- use serverTerm
  success <- handleAppendEntries r
  electionTimer .= 0
  updatedTerm <- use serverTerm
  tell [AppendEntriesRes to from (updatedTerm, success)]

handleAppendEntriesRes :: MonadPlus m => ServerId -> ServerId -> (Term, Bool) -> (a -> m ()) -> ServerT a m ()
handleAppendEntriesRes from to (term, success) apply = do
  isLeader <- (== Leader) <$> use role
  guard isLeader
  -- N.B. need to "update nextIndex and matchIndex for follower"
  -- but not sure what to update it to.
  -- For now:
  -- update matchIndex[followerId] = nextIndex[followerId]
  -- increment nextIndex[followerId]
  next <- use $ nextIndex . at from
  match <- use $ matchIndex . at from
  case (next, match) of
    (Just n, Just m) -> do
      let (next', match') = if success then (n + 1, n) else (n - 1, m)
      nextIndex . at from ?= next'
      matchIndex . at from ?= match'
      checkCommitIndex
      applyCommittedLogEntries apply
      unless success (sendAppendEntries from next')
    _ -> error "expected nextIndex and matchIndex to have element!"

handleRequestVoteReq :: MonadPlus m => ServerId -> ServerId -> RequestVote a -> ServerT a m ()
handleRequestVoteReq from to r = do
  currentTerm <- gets _serverTerm
  voteGranted <- handleRequestVote r
  updatedTerm <- use serverTerm
  tell [RequestVoteRes to from (updatedTerm, voteGranted)]

handleRequestVoteRes :: MonadPlus m => ServerId -> ServerId -> (Term, Bool) -> ServerT a m ()
handleRequestVoteRes from to (term, voteGranted) = do
  currentTerm <- use serverTerm
  isCandidate <- (== Candidate) <$> use role
  guard isCandidate
  when voteGranted $ do
    votes <- (+1) <$> use votesReceived
    total <- (+ 1) . length <$> use serverIds
    votesReceived .= votes
    when (votes % total > 1 % 2) $ do
      logMessage [T.pack $ "obtained " ++ show (votes % total) ++ " majority"]
      convertToLeader

handleClientRequest :: MonadPlus m => RequestId -> a -> ServerT a m ()
handleClientRequest reqId c = do
  -- TODO: followers should redirect request to leader
  -- TODO: we should actually respond to the request
  role <- use role
  votedFor <- use votedFor
  self <- use selfId
  case (role, votedFor) of
    (Leader, _) -> do
      logMessage ["responding to client request"]
      log <- use entryLog
      currentTerm <- use serverTerm
      let nextIndex = toInteger $ length log
          entry = LogEntry { _Index = nextIndex
                           , _Term = currentTerm
                           , _Command = c
                           , _RequestId = reqId}
      entryLog %= \log -> log ++ [entry]
      -- broadcast this new entry to followers
      serverIds <- use serverIds
      mapM_ (`sendAppendEntries` nextIndex) serverIds
    (_, Just leader) -> do
      logMessage [T.pack $ "redirecting client request to leader " ++ show leader]
      tell [ClientRequest leader reqId c]
    (_, Nothing) -> do
      logMessage ["received client request but unable to identify leader: failing request"]
      tell [ClientResponse self reqId c False]
      pure ()

-- reply false if term < currentTerm
-- reply false if log doesn't contain an entry at prevLogIndex whose term
--   matches prevLogTerm
-- append entries to the log
-- if leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of
--   last new entry)
handleAppendEntries :: Monad m => AppendEntries a -> ServerT a m Bool
handleAppendEntries r = do
  log <- use entryLog
  currentCommitIndex <- use commitIndex
  currentTerm <- use serverTerm
  case validateAppendEntries currentTerm log r of
    (False, reason) -> logMessage [reason] >> pure False
    (True, _) -> do
      entryLog %= (\l -> appendEntries l (r^.entries))
      when (r^.leaderCommit > currentCommitIndex) $ do
        lastNewEntry <- last <$> use entryLog
        commitIndex .= min (r^.leaderCommit) (lastNewEntry^.index)
      logMessage ["AppendEntries approved"]
      pure True

-- TODO: this is a crap return type - improve it
validateAppendEntries :: Term -> Log a -> AppendEntries a -> (Bool, T.Text)
validateAppendEntries currentTerm log rpc =
  if rpc^.leaderTerm < currentTerm
     then (False, "AppendEntries denied: term < currentTerm")
     else case matchingLogEntry of
            Nothing -> (False, "AppendEntries denied: no entry found")
            Just _  -> (True, "AppendEntries approved")
  where matchingLogEntry = findEntry log (rpc^.prevLogIndex) (rpc^.prevLogTerm)

-- if an existing entry conflicts with a new one (same index, different terms),
--   delete the existing entry and all that follow it
-- append any new entries not already in the log
appendEntries :: Log a -> [LogEntry a] -> Log a
appendEntries log [] = log
appendEntries [] es  = es
appendEntries (l:ls) (e:es) = case compare (_Index l) (_Index e) of
                               LT -> l : appendEntries ls (e:es)
                               EQ -> if _Term l /= _Term e
                                        then e:es
                                        else l : appendEntries ls es
                               GT -> e:es

-- reply false if term < currentTerm
-- if votedFor is null or candidateId, and candidate's log is at least as
--   up-to-date as receiver's log, grant vote
handleRequestVote :: Monad m => RequestVote a -> ServerT a m Bool
handleRequestVote r = do
  s <- get
  let currentTerm = s ^. serverTerm
      matchingVote = s ^. votedFor == Just (r ^. candidateId)
      logUpToDate = upToDate (r^.lastLogIndex) (r^.lastLogTerm) (s^.entryLog)
  if _CandidateTerm r < currentTerm
     then do
       logMessage ["RequestVote denied: candidate term < current term"]
       pure False
     else case (isNothing (s^.votedFor) || matchingVote, logUpToDate) of
            (True, True) -> do
              votedFor .= Just (r ^. candidateId)
              pure True
            (False, _) -> do
              logMessage ["RequestVote denied: vote already granted to another candidate"]
              pure False
            (_, False) -> do
              logMessage ["RequestVote denied: candidate's log is not up to date"]
              pure False

-- Raft determines which of two logs is more up-to-date by comparing the index
-- and term of the last entries in the logs. If the logs have last entries with
-- different terms, then the log with the later term is more up-to-date.
-- If the logs end with the same term, then whichever log is longer is more
-- up-to-date.
upToDate :: LogIndex -> Term -> Log a -> Bool
upToDate candidateIndex candidateTerm log =
  case compare candidateTerm (lastEntry^.term) of
    GT -> True
    LT -> False
    EQ -> candidateIndex >= lastEntry^.index
  where lastEntry = last log

findEntry :: Log a -> LogIndex -> Term -> Maybe (LogEntry a)
findEntry l i t =
  case findByIndex l i of
    Nothing -> Nothing
    Just e ->
      if e ^. term == t
        then Just e
        else Nothing

findByIndex :: Log a -> LogIndex -> Maybe (LogEntry a)
findByIndex _ i | i < 0 = Nothing
findByIndex l i | i > toInteger (length l) = Nothing
findByIndex l i = Just $ l !! fromInteger i

-- `leaderTerm` is the updated term communicated via an RPC req/res
convertToFollower :: Monad m => Term -> ServerT a m ()
convertToFollower leaderTerm = do
  logMessage ["converting to follower"]
  role .= Follower
  serverTerm .= leaderTerm
  votesReceived .= 0

-- increment currentTerm
-- vote for self
-- reset election timer
-- send RequestVote RPCs to all other servers
convertToCandidate :: Monad m => ServerT a m ()
convertToCandidate = do
  logMessage ["converting to candidate"]
  newTerm <- (+1) <$> use serverTerm
  ownId <- use selfId
  lastLogEntry <- last <$> use entryLog
  servers <- use serverIds
  role .= Candidate
  serverTerm .= newTerm
  votedFor .= Just ownId
  electionTimer .= 0
  let rpc = RequestVote { _CandidateTerm = newTerm
                        , _CandidateId = ownId
                        , _LastLogIndex = lastLogEntry ^. index
                        , _LastLogTerm = lastLogEntry ^. term }
  tell $ map (\i -> RequestVoteReq ownId i rpc) servers

-- send initial empty AppendEntries RPCs (hearbeats) to each server
convertToLeader :: Monad m => ServerT a m ()
convertToLeader = do
  logMessage ["converting to leader"]
  role .= Leader
  sendHeartbeats

sendHeartbeats :: Monad m => ServerT a m ()
sendHeartbeats = do
  logMessage ["sending heartbeats"]
  servers <- use serverIds
  currentTerm <- use serverTerm
  selfId <- use selfId
  commitIndex <- use commitIndex
  log <- use entryLog
  let lastEntry = last log
      mkHeartbeat to = AppendEntriesReq selfId to AppendEntries { _LeaderTerm = currentTerm
                                                                , _LeaderId = selfId
                                                                , _PrevLogIndex = lastEntry ^. index
                                                                , _PrevLogTerm = lastEntry ^. term
                                                                , _Entries = []
                                                                , _LeaderCommit = commitIndex }
  tell $ map mkHeartbeat servers
  heartbeatTimer .= 0

sendAppendEntries :: Monad m => ServerId -> LogIndex -> ServerT a m ()
sendAppendEntries followerId logIndex = do
  currentTerm <- use serverTerm
  selfId <- use selfId
  log <- use entryLog
  commitIndex <- use commitIndex
  let entry = log !! fromInteger logIndex
      prevEntry = log !! fromInteger (logIndex - 1)
      ae = AppendEntries { _LeaderTerm = currentTerm
                         , _LeaderId = selfId
                         , _PrevLogIndex = prevEntry ^. index
                         , _PrevLogTerm = prevEntry ^. term
                         , _Entries = [entry]
                         , _LeaderCommit = commitIndex }
      req = AppendEntriesReq selfId followerId ae
  tell [req]
  heartbeatTimer .= 0

-- if there exists an N such that N > commitIndex, a majority of matchIndex[i]
--   >= N, and log[N].term == currentTerm: set commitIndex = N
-- For simplicity, we only check the case of N = commitIndex + 1
-- Changing this would probably bring a perf improvement
checkCommitIndex :: Monad m => ServerT a m ()
checkCommitIndex = do
  n <- (+1) <$> use commitIndex
  matchIndex <- use matchIndex
  currentTerm <- use serverTerm
  log <- use entryLog
  let upToDate = Map.size $ Map.filter (>= n) matchIndex
      majorityUpToDate = upToDate % Map.size matchIndex > 1 % 2
      entryAtN = atMay log (fromInteger n)
  case entryAtN of
    Nothing -> pure ()
    Just e -> when (majorityUpToDate && e^.term == currentTerm) $ do
              logMessage [T.pack $ "updating commitIndex to " ++ show n]
              commitIndex .= n

-- if commitIndex > lastApplied:
--   increment lastApplied
--   apply log[lastApplied] to state machine
--   broadcast "log applied" event (this is a form of client response)
applyCommittedLogEntries :: Monad m => (a -> m ()) -> ServerT a m ()
applyCommittedLogEntries apply = do
  lastAppliedIndex <- use lastApplied
  lastCommittedIndex <- use commitIndex
  log <- use entryLog
  self <- use selfId
  when (lastCommittedIndex > lastAppliedIndex) $ do
    lastApplied' <- lastApplied <+= 1
    let entry = fromJust $ findByIndex log lastApplied'
    logMessage [T.pack $ "applying entry " ++ show (entry^.index)]
    (lift . lift . lift) $ apply (_Command entry)
    tell [ClientResponse self (entry^.requestId) (entry^.command) True]

{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft where

import           Control.Lens                (at, use, (%=), (+=), (.=), (<+=),
                                              (?=), (^.))
import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import           Data.Binary                 (Binary)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (fromJust, isNothing)
import           Data.Ratio                  ((%))
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)
import           Prelude                     hiding (log)

import           Raft.Log
import           Raft.Rpc
import           Raft.Server

-- reply false if term < currentTerm
-- reply false if log doesn't contain an entry at prevLogIndex whose term
--   matches prevLogTerm
-- apply entries to the log
-- if leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of
--   last new entry)
handleAppendEntries :: Monad m => AppendEntries a -> ServerT a m (Bool, String)
handleAppendEntries r = do
  log <- use entryLog
  currentCommitIndex <- use commitIndex
  currentTerm <- use serverTerm
  if r ^. leaderTerm < currentTerm
     then pure (False, "term < currentTerm")
     else case findEntry log (r ^. prevLogIndex) (r ^. prevLogTerm) of
            Nothing -> pure (False, "no entry found")
            Just _ -> do
              entryLog %= (\l -> appendEntries l (r ^. entries))
              when (r ^. leaderCommit > currentCommitIndex) $ do
                log' <- use entryLog -- fetch the updated log
                commitIndex .= min (r ^. leaderCommit) (last log' ^. index)
              pure (True, "success")

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
     then pure False
     else if (isNothing (s ^. votedFor) || matchingVote) && logUpToDate
     then do
       votedFor .= Just (r ^. candidateId)
       pure True
     else
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
findEntry l i t = case findByIndex l i of
                            Nothing -> Nothing
                            Just e -> if e ^. term == t
                                         then Just e
                                         else Nothing

findByIndex :: Log a -> LogIndex -> Maybe (LogEntry a)
findByIndex _ i | i < 0 = Nothing
findByIndex l i | i > length l = Nothing
findByIndex l i = Just $ l !! i

-- `leaderTerm` is the updated term communicated via an RPC req/res
convertToFollower :: Monad m => Term -> ServerT a m ()
convertToFollower leaderTerm = do
  role .= Follower
  serverTerm .= leaderTerm
  votesReceived .= 0

-- increment currentTerm
-- vote for self
-- reset election timer
-- send RequestVote RPCs to all other servers
convertToCandidate :: Monad m => ServerT a m ()
convertToCandidate = do
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
  role .= Leader
  sendHeartbeats

sendHeartbeats :: Monad m => ServerT a m ()
sendHeartbeats = do
  servers <- use serverIds
  term <- use serverTerm
  selfId <- use selfId
  commitIndex <- use commitIndex
  tell $ map (\i -> mkHeartbeat selfId i term commitIndex) servers
    where mkHeartbeat from to term commitIndex =
            AppendEntriesReq from to AppendEntries
              { _LeaderTerm = term
              , _LeaderId = from
              -- TODO: this looks wrong - it shouldn't always be 0!
              , _PrevLogIndex = 0
              , _PrevLogTerm = 0
              , _Entries = []
              , _LeaderCommit = commitIndex }

sendAppendEntries :: Monad m => ServerId -> LogIndex -> ServerT a m ()
sendAppendEntries followerId logIndex = do
  currentTerm <- use serverTerm
  selfId <- use selfId
  log <- use entryLog
  commitIndex <- use commitIndex
  let entry = log !! logIndex
      prevEntry = log !! (logIndex - 1)
      ae = AppendEntries { _LeaderTerm = currentTerm
                         , _LeaderId = selfId
                         , _PrevLogIndex = prevEntry ^. index
                         , _PrevLogTerm = prevEntry ^. term
                         , _Entries = [entry]
                         , _LeaderCommit = commitIndex }
      req = AppendEntriesReq selfId followerId ae
  tell [req]

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
  when (majorityUpToDate && (log !! n) ^. term == currentTerm) $
    commitIndex .= n

-- if commitIndex > lastApplied:
--   increment lastApplied
--   apply log[lastApplied] to state machine
applyCommittedLogEntries :: Monad m => (a -> m ()) -> ServerT a m ()
applyCommittedLogEntries apply = do
  lastAppliedIndex <- use lastApplied
  lastCommittedIndex <- use commitIndex
  log <- use entryLog
  when (lastCommittedIndex > lastAppliedIndex) $ do
    lastApplied' <- lastApplied <+= 1
    let entry = fromJust $ findByIndex log lastApplied'
    (lift . lift) $ apply (_Command entry)

data Message a =
    AppendEntriesReq ServerId ServerId (AppendEntries a)
  | AppendEntriesRes ServerId ServerId (Term, Bool)
  | RequestVoteReq ServerId ServerId (RequestVote a)
  | RequestVoteRes ServerId ServerId (Term, Bool)
  | Tick ServerId
  | ClientRequest ServerId a
  deriving (Generic)

deriving instance Typeable a => Typeable (Message a)
instance Binary a => Binary (Message a)

deriving instance Show a => Show (Message a)
deriving instance Eq a => Eq (Message a)

type ServerT a m = WriterT [Message a] (StateT (ServerState a) m)

handleMessage :: MonadPlus m => (a -> m ()) -> Message a -> ServerT a m ()
-- if election timeout elapses without receiving AppendEntries RPC from current
-- leader or granting vote to candidate, convert to candidate
handleMessage apply (Tick _) = do
  applyCommittedLogEntries apply
  electionTimer' <- electionTimer <+= 1
  heartbeatTimer' <- heartbeatTimer <+= 1
  role <- use role
  electTimeout <- use electionTimeout
  hbTimeout <- use heartbeatTimeout
  when (electionTimer' >= electTimeout && role /= Leader) convertToCandidate
  when (heartbeatTimer' >= hbTimeout && role == Leader) sendHeartbeats
handleMessage _ (AppendEntriesReq from to r) = do
  currentTerm <- use serverTerm
  (success, reason) <- handleAppendEntries r
  electionTimer .= 0
  when (r ^. leaderTerm > currentTerm) $ convertToFollower (r ^. leaderTerm)
  updatedTerm <- use serverTerm
  tell [AppendEntriesRes to from (updatedTerm, success)]
handleMessage apply (AppendEntriesRes from to (term, success)) = do
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
handleMessage _ (RequestVoteReq from to r) = do
  currentTerm <- gets _serverTerm
  voteGranted <- handleRequestVote r
  when (r ^. candidateTerm > currentTerm) $ convertToFollower (r ^. candidateTerm)
  updatedTerm <- use serverTerm
  tell [RequestVoteRes to from (updatedTerm, voteGranted)]
handleMessage _ (RequestVoteRes from to (term, voteGranted)) = do
  currentTerm <- use serverTerm
  isCandidate <- (== Candidate) <$> use role
  guard isCandidate
  if term > currentTerm
     then convertToFollower term
     else when voteGranted $ do
       votes <- (+1) <$> use votesReceived
       total <- (+ 1) . length <$> use serverIds
       votesReceived .= votes
       when (votes % total > 1 % 2) convertToLeader
handleMessage _ (ClientRequest to c) = do
  -- TODO: followers should redirect request to leader
  -- TODO: we should actually respond to the request
  role <- use role
  votedFor <- use votedFor
  case (role, votedFor) of
    (Leader, _) -> do
      log <- use entryLog
      currentTerm <- use serverTerm
      let nextIndex = length log
          entry = LogEntry { _Index = nextIndex, _Term = currentTerm, _Command = c }
      entryLog %= \log -> log ++ [entry]
      -- broadcast this new entry to followers
      serverIds <- use serverIds
      mapM_ (`sendAppendEntries` nextIndex) serverIds
    (_, Just leader) -> tell [ClientRequest leader c]
    (_, Nothing) -> pure ()

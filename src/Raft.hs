{-# LANGUAGE StandaloneDeriving #-}

module Raft where

import           Control.Monad.State.Strict
import           Control.Monad.Writer.Strict
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (fromJust, isNothing)
import           Data.Ratio                  ((%))
import           Debug.Trace                 (trace)
import           Prelude                     hiding (log)

import           Raft.Log
import           Raft.Rpc
import           Raft.Server

handleAppendEntries :: Monad m => AppendEntries a -> ServerT a m (Bool, String)
handleAppendEntries r = do
  s <- get
  let log = sLog s
      commitIndex = sCommitIndex s
      currentTerm = sCurrentTerm s
  -- reply false if term < currentTerm
  if aeTerm r < currentTerm
     then pure (False, "term < currentTerm")
     -- reply false if log doesn't contain an entry at prevLogIndex whose term
     -- matches prevLogTerm
     else case findEntry log (aePrevLogIndex r) (aePrevLogTerm r) of
            Nothing -> pure (False, "no entry found")
            -- apply entries to the log
            -- if leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of
            -- last new entry)
            Just _ -> let log' = appendEntries log (aeEntries r)
                          commitIndex' = if aeLeaderCommit r > commitIndex
                                            then min (aeLeaderCommit r) (eIndex (last log'))
                                            else commitIndex
                      in do
                        put s { sLog = log', sCommitIndex = commitIndex' }
                        pure (True, "success")

-- - if an existing entry conflicts with a new one (same index, different terms),
--   delete the existing entry and all that follow it
-- - append any new entries not already in the log
appendEntries :: Log a -> [LogEntry a] -> Log a
appendEntries log [] = log
appendEntries [] es  = es
appendEntries (l:ls) (e:es) = case compare (eIndex l) (eIndex e) of
                               LT -> l : appendEntries ls (e:es)
                               EQ -> if eTerm l /= eTerm e
                                        then e:es
                                        else l : appendEntries ls es
                               GT -> e:es

handleRequestVote :: Monad m => RequestVote a -> ServerT a m Bool
handleRequestVote r = do
  s <- get
  let currentTerm = sCurrentTerm s
      votedFor = sVotedFor s
      commitIndex = sCommitIndex s
      matchingVote = votedFor == Just (rvCandidateId r)
      -- N.B. is this the right way to determine up-to-date?
      logUpToDate = rvLastLogIndex r >= commitIndex
  -- reply false if term < currentTerm
  if rvTerm r < currentTerm
     then pure False
     -- if votedFor is null or candidateId, and candidate's log is at least as
     -- up-to-date as receiver's log, grant vote
     else if (isNothing votedFor || matchingVote) && logUpToDate
     then put s { sVotedFor = Just (rvCandidateId r) } >> pure True
     else pure False


findEntry :: Log a -> LogIndex -> Term -> Maybe (LogEntry a)
findEntry l i t = case findByIndex l i of
                            Nothing -> Nothing
                            Just e -> if eTerm e == t
                                         then Just e
                                         else Nothing

findByIndex :: Log a -> LogIndex -> Maybe (LogEntry a)
findByIndex _ i | i < 0 = Nothing
findByIndex l i | i > length l = Nothing
findByIndex l i = Just $ l !! i

-- `term` is the updated term communicated via an RPC req/res
convertToFollower :: Monad m => Term -> ServerT a m ()
convertToFollower term =
  modify' $ \s -> s { sRole = Follower, sCurrentTerm = term, sVotesReceived = 0 }

convertToCandidate :: Monad m => ServerT a m ()
convertToCandidate = do
  newTerm <- incTerm <$> gets sCurrentTerm
  selfId <- gets sId
  lastLogEntry <- last <$> gets sLog
  serverIds <- gets sServerIds
  -- increment currentTerm
  -- vote for self
  -- reset election timer
  modify' $ \s -> s { sRole = Candidate
                    , sCurrentTerm = newTerm
                    , sVotedFor = Just selfId
                    , sTock = 0}
  -- send RequestVote RPCs to all other servers
  let rpc = RequestVote { rvTerm = newTerm
                          , rvCandidateId = selfId
                          , rvLastLogIndex = eIndex lastLogEntry
                          , rvLastLogTerm = eTerm lastLogEntry }
  tell $ map (\i -> RequestVoteReq selfId i rpc) serverIds

convertToLeader :: Monad m => ServerT a m ()
convertToLeader = do
  modify' $ \s -> s { sRole = Leader }
  sendHeartbeats

sendHeartbeats :: Monad m => ServerT a m ()
sendHeartbeats = do
  serverIds <- gets sServerIds
  term <- gets sCurrentTerm
  selfId <- gets sId
  commitIndex <- gets sCommitIndex
  tell $ map (\i -> mkHeartbeat selfId i term commitIndex) serverIds
    where mkHeartbeat from to term commitIndex =
            AppendEntriesReq from to AppendEntries
              { aeTerm = term
              , aeLeaderId = from
              , aePrevLogIndex = 0
              , aePrevLogTerm = Term { unTerm = 0 }
              , aeEntries = []
              , aeLeaderCommit = commitIndex }

sendAppendEntries :: Monad m => ServerId -> LogIndex -> ServerT a m ()
sendAppendEntries followerId logIndex = do
  term <- gets sCurrentTerm
  selfId <- gets sId
  log <- gets sLog
  commitIndex <- gets sCommitIndex
  let entry = log !! logIndex
      prevEntry = log !! (logIndex - 1)
      ae = AppendEntries { aeTerm = term
                         , aeLeaderId = selfId
                         , aePrevLogIndex = eIndex prevEntry
                         , aePrevLogTerm = eTerm prevEntry
                         , aeEntries = [entry]
                         , aeLeaderCommit = commitIndex }
      req = AppendEntriesReq selfId followerId ae
  tell [req]

-- if there exists an N such that N > commitIndex, a majority of matchIndex[i]
-- >= N, and log[N].term == currentTerm: set commitIndex = N
-- For simplicity, we only check the case of N = commitIndex + 1
-- Changing this would probably bring a perf improvement
checkCommitIndex :: Monad m => ServerT a m ()
checkCommitIndex = do
  n <- (+1) <$> gets sCommitIndex
  matchIndex <- gets sMatchIndex
  currentTerm <- gets sCurrentTerm
  log <- gets sLog
  let upToDate = Map.size $ Map.filter (>= n) matchIndex
      majorityUpToDate = upToDate % Map.size matchIndex > 1 % 2
  when (majorityUpToDate && eTerm (log !! n) == currentTerm) $
    modify' $ \s -> s { sCommitIndex = n }

applyCommittedLogEntries :: Monad m => (a -> m ()) -> ServerT a m ()
applyCommittedLogEntries apply = do
  lastApplied <- gets sLastApplied
  commitIndex <- gets sCommitIndex
  log <- gets sLog
  let entry = fromJust $ findByIndex log (lastApplied + 1)
  if commitIndex > lastApplied
     then do
       modify' $ \s -> s { sLastApplied = lastApplied + 1 }
       (lift . lift) $ apply (eCommand entry)
       pure ()
     else pure ()

data Message a =
    AppendEntriesReq ServerId ServerId (AppendEntries a)
  | AppendEntriesRes ServerId ServerId (Term, Bool)
  | RequestVoteReq ServerId ServerId (RequestVote a)
  | RequestVoteRes ServerId ServerId (Term, Bool)
  | Tick ServerId
  | ClientRequest ServerId a

deriving instance Show a => Show (Message a)

type ServerT a m = WriterT [Message a] (StateT (ServerState a) m)

handleMessage :: MonadPlus m => (a -> m ()) -> Message a -> ServerT a m ()
handleMessage apply (Tick _) = do
  modify' $ \s -> s { sTock = sTock s + 1 }
  role <- gets sRole
  applyCommittedLogEntries apply
  tock <- gets sTock
  timeout <- gets sElectionTimeout
  when (tock > timeout && role == Follower) convertToCandidate
handleMessage _ (AppendEntriesReq from to r) = do
  currentTerm <- gets sCurrentTerm
  (success, reason) <- handleAppendEntries r
  trace reason $ modify' (\s -> s { sTock = 0 })
  when (aeTerm r > currentTerm) $ convertToFollower (aeTerm r)
  updatedTerm <- gets sCurrentTerm
  tell [AppendEntriesRes to from (updatedTerm, success)]
handleMessage apply (AppendEntriesRes from to (term, success)) = do
  role <- gets sRole
  guard (role == Leader)
  nextIndex <- gets sNextIndex
  matchIndex <- gets sMatchIndex
  -- N.B. need to "update nextIndex and matchIndex for follower"
  -- but not sure what to update it to.
  -- For now:
  -- update matchIndex[followerId] = nextIndex[followerId]
  -- increment nextIndex[followerId]
  let next = nextIndex Map.! from
      match = matchIndex Map.! from
      (next', match') = if success then (next + 1, next)
                                   else (next - 1, match)
      nextIndex' = Map.insert from next' nextIndex
      matchIndex' = Map.insert from match' matchIndex
  modify' $ \s -> s { sNextIndex = nextIndex', sMatchIndex = matchIndex' }
  checkCommitIndex
  applyCommittedLogEntries apply
  unless success (sendAppendEntries from next')
handleMessage _ (RequestVoteReq from to r) = do
  currentTerm <- gets sCurrentTerm
  voteGranted <- handleRequestVote r
  when (rvTerm r > currentTerm) $ convertToFollower (rvTerm r)
  updatedTerm <- gets sCurrentTerm
  tell [RequestVoteRes to from (updatedTerm, voteGranted)]
handleMessage _ (RequestVoteRes from to (term, voteGranted)) = do
  currentTerm <- gets sCurrentTerm
  role <- gets sRole
  guard (role == Candidate)
  if term > currentTerm
     then convertToFollower term
     else when voteGranted $ do
            votes <- (+ 1) <$> gets sVotesReceived
            total <- (+ 1) . length <$> gets sServerIds
            modify' $ \s -> s { sVotesReceived = votes }
            when (votes % total > 1 % 2) convertToLeader
handleMessage _ (ClientRequest to c) = do
  -- TODO: followers should redirect request to leader
  -- TODO: we should actually respond to the request
  role <- gets sRole
  votedFor <- gets sVotedFor
  if role /= Leader
     then case votedFor of
            Nothing     -> pure ()
            Just leader -> tell [ClientRequest leader c]
     else do
       log <- gets sLog
       currentTerm <- gets sCurrentTerm
       let nextIndex = length log
           entry = LogEntry { eIndex = nextIndex, eTerm = currentTerm, eCommand = c }
       modify' $ \s -> s { sLog = log ++ [entry] }
       -- broadcast this new entry to followers
       serverIds <- gets sServerIds
       mapM_ (\i -> sendAppendEntries i nextIndex) serverIds

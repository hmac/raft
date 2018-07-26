{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft (handleMessage, Message(..), ServerT, ExtServerT) where

import           Control.Lens                (at, use, (%=), (.=), (<+=), (?=),
                                              (^.))
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

import           Control.Monad.Logger

import           Raft.Lens
import           Raft.Log
import           Raft.Rpc
import           Raft.Server

-- alias Safe.at as !!
(!!) :: [a] -> Int -> a
(!!) = Safe.at

data Message a b = AEReq (AppendEntries a)
                 | AERes AppendEntriesResponse
                 | RVReq (RequestVote a)
                 | RVRes RequestVoteResponse
                 | CReq (ClientReq a)
                 | CRes (ClientResponse b)
                 | Tick
                 deriving (Generic)

deriving instance (Typeable a, Typeable b) => Typeable (Message a b)
instance (Binary a, Binary b) => Binary (Message a b)

deriving instance (Show a, Show b) => Show (Message a b)
deriving instance (Eq a, Eq b) => Eq (Message a b)

type ExtServerT a b m = StateT (ServerState a b m) m
type ServerT a b m = WriterT [Message a b] (ExtServerT a b m)

-- The entrypoint to a Raft node
-- This function takes a Message and handles it, updating the node's state and
-- generating any messages to send in response.
handleMessage ::
     MonadLogger m => Message a b -> ExtServerT a b m [Message a b]
handleMessage m = snd <$> runWriterT go
  where
    go = applyCommittedLogEntries >> handler
    handler =
      case m of
        Tick    -> handleTick
        AEReq r -> handleAppendEntriesReq (r^.from) (r^.to) r -- we check for new term if AppendEntries succeeds
        AERes r -> checkForNewTerm (r^.term) >> handleAppendEntriesRes (r^.from) (r^.to) r
        RVReq r -> checkForNewTerm (r^.candidateTerm) >> handleRequestVoteReq (r^.from) (r^.to) r
        RVRes r -> checkForNewTerm (r^.voterTerm) >> handleRequestVoteRes (r^.from) (r^.to) r
        CReq r -> handleClientRequest r
        CRes r -> undefined -- what should we do here?

handleTick :: MonadLogger m => ServerT a b m ()
handleTick = do
  -- if election timeout elapses without receiving AppendEntries RPC from current
  -- leader or granting vote to candidate, convert to candidate
  applyCommittedLogEntries
  electionTimer' <- electionTimer <+= 1
  heartbeatTimer' <- heartbeatTimer <+= 1
  role <- use role
  electTimeout <- readTimeout <$> use electionTimeout
  hbTimeout <- use heartbeatTimeout
  when (electionTimer' >= electTimeout && role /= Leader) convertToCandidate
  when (heartbeatTimer' >= hbTimeout && role == Leader) sendHeartbeats

handleAppendEntriesReq :: MonadLogger m => ServerId -> ServerId -> AppendEntries a -> ServerT a b m ()
handleAppendEntriesReq from to r = do
  checkForNewTerm (r^.leaderTerm)
  success <- handleAppendEntries r
  electionTimer .= 0
  updatedTerm <- use serverTerm
  lastLog <- last <$> use entryLog
  tell [AERes AppendEntriesResponse { _appendEntriesResponseFrom = to
                                    , _appendEntriesResponseTo = from
                                    , _appendEntriesResponseTerm = updatedTerm
                                    , _appendEntriesResponseSuccess = success
                                    , _appendEntriesResponseLogIndex = lastLog^.index
                                    }]

checkForNewTerm :: MonadLogger m => Term -> ServerT a b m ()
checkForNewTerm rpcTerm = do
  currentTerm <- use serverTerm
  isCandidateOrLeader <- (/= Follower) <$> use role
  when (rpcTerm > currentTerm) $ do
    logInfoN $ T.pack $ "Received RPC with term " ++ (show . unTerm) rpcTerm ++ " > current term " ++ (show . unTerm) currentTerm
    serverTerm .= rpcTerm
    when isCandidateOrLeader convertToFollower

handleAppendEntriesRes :: MonadLogger m => ServerId -> ServerId -> AppendEntriesResponse -> ServerT a b m ()
handleAppendEntriesRes from to r = do
  isLeader <- (== Leader) <$> use role
  when isLeader $ do
    -- N.B. need to "update nextIndex and matchIndex for follower"
    -- but not sure what to update it to.
    -- For now:
    -- matchIndex[followerId] := nextIndex[followerId]
    -- nextIndex[followerId] := RPC.index + 1
    next <- use $ nextIndex . at from
    match <- use $ matchIndex . at from
    case (next, match) of
      (Just n, Just m) -> do
        let (next', match') = if r^.success then (r^.logIndex + 1, n) else (n - 1, m)
        nextIndex . at from ?= next'
        matchIndex . at from ?= match'
        checkCommitIndex
        applyCommittedLogEntries
        unless (r^.success) (sendAppendEntries from next')
      _ -> error "expected nextIndex and matchIndex to have element!"

handleRequestVoteReq :: MonadLogger m => ServerId -> ServerId -> RequestVote a -> ServerT a b m ()
handleRequestVoteReq from to r = do
  logInfoN (T.pack $ "Received RequestVoteReq from " ++ show from)
  voteGranted <- handleRequestVote r
  updatedTerm <- use serverTerm
  logInfoN (T.pack $ "Sending RequestVoteRes from " ++ show from ++ " to " ++ show to)
  tell [RVRes RequestVoteResponse { _from = to
                                  , _to = from
                                  , _voterTerm = updatedTerm
                                  , _requestVoteSuccess = voteGranted
                                  } ]

handleRequestVoteRes :: MonadLogger m => ServerId -> ServerId -> RequestVoteResponse -> ServerT a b m ()
handleRequestVoteRes from to r = do
  let voteGranted = r^.requestVoteSuccess
  isCandidate <- (== Candidate) <$> use role
  unless isCandidate $ logInfoN (T.pack $ "Ignoring RequestVoteRes from " ++ show from ++ ": not candidate")
  logInfoN (T.pack $ "Received RequestVoteRes from " ++ show from ++ ", to " ++ show to ++ ", vote granted: " ++ show voteGranted)
  when (isCandidate && voteGranted) $ do
    votes <- (+1) <$> use votesReceived
    total <- (+ 1) . length <$> use serverIds
    votesReceived .= votes
    logInfoN (T.pack $ "received " ++ show votes ++ " votes")
    when (votes % total > 1 % 2) $ do
      logInfoN (T.pack $ "obtained " ++ show (votes % total) ++ " majority")
      convertToLeader

handleClientRequest :: MonadLogger m => ClientReq a -> ServerT a b m ()
handleClientRequest r = do
  let c = r^.requestPayload
      reqId = r^.clientRequestId
  role <- use role
  votedFor <- use votedFor
  self <- use selfId
  case (role, votedFor) of
    (Leader, _) -> do
      logInfoN "responding to client request"
      log <- use entryLog
      currentTerm <- use serverTerm
      let nextIndex = toInteger $ length log
          entry = LogEntry { _logEntryIndex = nextIndex
                           , _logEntryTerm = currentTerm
                           , _logEntryCommand = c
                           , _logEntryRequestId = reqId}
      entryLog %= \log -> log ++ [entry]
      -- broadcast this new entry to followers
      serverIds <- use serverIds
      mapM_ (`sendAppendEntries` nextIndex) serverIds
    (_, Just leader) -> do
      -- TODO: redirect request to leader
      -- either:
      --  - forward it to leader verbatim
      --  - send error response to client with address of leader, let client
      --    make the request again
      pure ()
    (_, Nothing) -> do
      logInfoN "received client request but unable to identify leader: failing request"
      tell [CRes ClientResponse { _responsePayload = Left "invalid request: node is not leader"
                                , _responseId = reqId
                                } ]
      pure ()

-- reply false if term < currentTerm
-- reply false if log doesn't contain an entry at prevLogIndex whose term
--   matches prevLogTerm
-- append entries to the log
-- if leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of
--   last new entry)
handleAppendEntries :: MonadLogger m => AppendEntries a -> ServerT a b m Bool
handleAppendEntries r = do
  log <- use entryLog
  currentCommitIndex <- use commitIndex
  currentTerm <- use serverTerm
  let (valid, reason) = validateAppendEntries currentTerm log r
  case valid of
    False -> logInfoN reason >> pure False
    True -> do
      unless (null (r^.entries)) $ logDebugN $ T.pack $ "Appending entries to log: " ++ show (map (^.index) (r^.entries))
      entryLog %= (\l -> appendEntries l (r^.entries))
      when (r^.leaderCommit > currentCommitIndex) $ do
        lastNewEntry <- last <$> use entryLog
        commitIndex .= min (r^.leaderCommit) (lastNewEntry^.index)
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
appendEntries (l:ls) (e:es) = case compare (l^.index) (e^.index) of
                               LT -> l : appendEntries ls (e:es)
                               EQ -> if l^.term /= e^.term
                                        then e:es
                                        else l : appendEntries ls es
                               GT -> e:es

-- reply false if term < currentTerm
-- if votedFor is null or candidateId (rpc.from), and candidate's log is at least as
--   up-to-date as receiver's log, grant vote
handleRequestVote :: MonadLogger m => RequestVote a -> ServerT a b m Bool
handleRequestVote r = do
  s <- get
  let currentTerm = s ^. serverTerm
      matchingVote = s ^. votedFor == Just (r ^. from)
      logUpToDate = upToDate (r^.lastLogIndex) (r^.lastLogTerm) (s^.entryLog)
  if r^.candidateTerm < currentTerm
     then do
       logInfoN "RequestVote denied: candidate term < current term"
       pure False
     else case (isNothing (s^.votedFor) || matchingVote, logUpToDate) of
            (True, True) -> do
              votedFor .= Just (r ^. from)
              logInfoN "RequestVote granted"
              pure True
            (False, _) -> do
              logInfoN (T.pack $ "RequestVote denied: vote already granted to " ++ show (s^.votedFor))
              pure False
            (_, False) -> do
              logInfoN "RequestVote denied: candidate's log is not up to date"
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
findByIndex l i | i >= toInteger (length l) = Nothing
findByIndex l i = Just $ l !! fromInteger i

-- `leaderTerm` is the updated term communicated via an RPC req/res
convertToFollower :: MonadLogger m => ServerT a b m ()
convertToFollower = do
  logInfoN "converting to follower"
  role .= Follower
  votesReceived .= 0
  votedFor .= Nothing

-- increment currentTerm
-- vote for self
-- reset election timer
-- randomise election timeout
-- send RequestVote RPCs to all other servers
convertToCandidate :: MonadLogger m => ServerT a b m ()
convertToCandidate = do
  logInfoN "converting to candidate"
  newTerm <- (+1) <$> use serverTerm
  ownId <- use selfId
  lastLogEntry <- last <$> use entryLog
  servers <- use serverIds
  role .= Candidate
  serverTerm .= newTerm
  votedFor .= Just ownId
  votesReceived .= 1
  electionTimer .= 0
  electionTimeout %= nextTimeout
  let rpc sid = RequestVote { _requestVoteFrom = ownId
                            , _requestVoteTo = sid
                            , _requestVoteCandidateTerm = newTerm
                            , _requestVoteLastLogIndex = lastLogEntry ^. index
                            , _requestVoteLastLogTerm = lastLogEntry ^. term }
  mapM_ (\i -> logInfoN (T.pack $ "Sending RequestVoteReq from self (" ++ show ownId ++ ") to " ++ show i)) servers
  tell $ map (RVReq . rpc) servers

-- send initial empty AppendEntries RPCs (hearbeats) to each server
convertToLeader :: MonadLogger m => ServerT a b m ()
convertToLeader = do
  logInfoN "converting to leader"
  role .= Leader

  -- When a leader first comes to power, it initializes all nextIndex values
  -- to the index just after the last one in its log.
  -- Initialize all matchIndex values to 0
  latestLogIndex <- (^.index) . last <$> use entryLog
  sids <- use serverIds
  nextIndex .= mkNextIndex latestLogIndex sids
  matchIndex .= mkMatchIndex sids

  sendHeartbeats
  where mkNextIndex :: LogIndex -> [ServerId] -> Map.HashMap ServerId LogIndex
        mkNextIndex logIndex = foldl (\m sid -> Map.insert sid (logIndex + 1) m) Map.empty
        mkMatchIndex :: [ServerId] -> Map.HashMap ServerId LogIndex
        mkMatchIndex = foldl (\m sid -> Map.insert sid 0 m) Map.empty

sendHeartbeats :: MonadLogger m => ServerT a b m ()
sendHeartbeats = do
  -- logInfoN ["sending heartbeats"]
  servers <- use serverIds
  currentTerm <- use serverTerm
  selfId <- use selfId
  commitIndex <- use commitIndex
  log <- use entryLog
  let lastEntry = last log
      mkHeartbeat to = AEReq AppendEntries { _appendEntriesLeaderTerm = currentTerm
                                           , _appendEntriesFrom = selfId
                                           , _appendEntriesTo = to
                                           , _appendEntriesPrevLogIndex = lastEntry ^. index
                                           , _appendEntriesPrevLogTerm = lastEntry ^. term
                                           , _appendEntriesEntries = []
                                           , _appendEntriesLeaderCommit = commitIndex }
  tell $ map mkHeartbeat servers
  heartbeatTimer .= 0

sendAppendEntries :: MonadLogger m => ServerId -> LogIndex -> ServerT a b m ()
sendAppendEntries followerId logIndex = do
  currentTerm <- use serverTerm
  selfId <- use selfId
  log <- use entryLog
  commitIndex <- use commitIndex
  let entry = log !! fromInteger logIndex
      prevEntry = log !! fromInteger (logIndex - 1)
      req = AEReq AppendEntries { _appendEntriesLeaderTerm = currentTerm
                               , _appendEntriesFrom = selfId
                               , _appendEntriesTo = followerId
                               , _appendEntriesPrevLogIndex = prevEntry ^. index
                               , _appendEntriesPrevLogTerm = prevEntry ^. term
                               , _appendEntriesEntries = [entry]
                               , _appendEntriesLeaderCommit = commitIndex }
  tell [req]
  heartbeatTimer .= 0

-- if there exists an N such that N > commitIndex, a majority of matchIndex[i]
--   >= N, and log[N].term == currentTerm: set commitIndex = N
-- For simplicity, we only check the case of N = commitIndex + 1
-- Changing this might bring a perf improvement
checkCommitIndex :: MonadLogger m => ServerT a b m ()
checkCommitIndex = do
  n <- (+1) <$> use commitIndex
  matchIndex <- use matchIndex
  currentTerm <- use serverTerm
  log <- use entryLog
  -- matchIndex currently doesn't include the current server, so we also check
  -- if we are up to date, and include that accordingly
  let selfUpToDate = if length log >= fromInteger n then 1 else 0
      upToDate = selfUpToDate + Map.size (Map.filter (>= n) matchIndex)
      total = Map.size matchIndex + 1
      majorityUpToDate = (upToDate % total) > (1 % 2)
      entryAtN = atMay log (fromInteger n)
  case entryAtN of
    Nothing -> pure ()
    Just e -> when (majorityUpToDate && e^.term == currentTerm) $ do
              logInfoN (T.pack $ "updating commitIndex to " ++ show n)
              commitIndex .= n

-- if commitIndex > lastApplied:
--   increment lastApplied
--   apply log[lastApplied] to state machine
--   broadcast "log applied" event (this is a form of client response)
applyCommittedLogEntries :: MonadLogger m => ServerT a b m ()
applyCommittedLogEntries = do
  apply <- use apply
  lastAppliedIndex <- use lastApplied
  lastCommittedIndex <- use commitIndex
  log <- use entryLog
  self <- use selfId
  pure ()
  when (lastCommittedIndex > lastAppliedIndex) $ do
    lastApplied' <- lastApplied <+= 1
    let entry = fromJust $ findByIndex log lastApplied'
    logInfoN (T.pack $ "applying entry " ++ show (entry^.index))
    res <- (lift . lift) $ apply (entry^.command)
    tell [CRes ClientResponse { _responsePayload = Right res
                              , _responseId = entry^.requestId
                              }]

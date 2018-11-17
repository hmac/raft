{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE StandaloneDeriving    #-}

module Raft (handleMessage, Message(..), ServerT, ExtServerT) where

import           Control.Lens                (at, over, use, (%=), (.=), (<+=),
                                              (?=), (^.))
import           Control.Monad.State.Strict  hiding (state)
import           Control.Monad.Writer.Strict
import           Data.Binary                 (Binary)
import           Data.HashMap.Strict         (HashMap)
import qualified Data.HashMap.Strict         as Map
import           Data.Maybe                  (fromJust, isNothing)
import           Data.Ratio                  ((%))
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)
import           Prelude                     hiding (log)
import           Safe                        (atMay, headMay)
import qualified Safe                        (at)

import           Control.Monad.Logger

import           Raft.Lens
import           Raft.Log
import           Raft.Rpc
import           Raft.Server

-- Convenience function for when your writer monoid is List
tell1 :: MonadWriter [a] m => a -> m ()
tell1 a = tell [a]

data Message a b
  = AEReq (AppendEntriesReq a)
  | AERes AppendEntriesRes
  | RVReq RequestVoteReq
  | RVRes RequestVoteRes
  | CReq (ClientReq a)
  | CRes (ClientRes b)
  | ASReq AddServerReq
  | ASRes AddServerRes
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
        AEReq r -> checkForNewTerm (r^.leaderTerm) >> handleAppendEntriesReq (r^.from) (r^.to) r
        AERes r -> checkForNewTerm (r^.term) >> handleAppendEntriesRes (r^.from) (r^.to) r
        RVReq r -> checkForNewTerm (r^.candidateTerm) >> handleRequestVoteReq (r^.from) (r^.to) r
        RVRes r -> checkForNewTerm (r^.voterTerm) >> handleRequestVoteRes (r^.from) (r^.to) r
        CReq r -> handleClientRequest r
        CRes _ -> undefined -- what should we do here?
        ASReq r -> handleAddServerReq (r^.requestId) (r^.newServer)
        ASRes _ -> undefined -- and here?

handleTick :: MonadLogger m => ServerT a b m ()
handleTick = do
  -- if election timeout elapses without receiving AppendEntriesReq RPC from current
  -- leader or granting vote to candidate, convert to candidate
  applyCommittedLogEntries
  electionTimer' <- electionTimer <+= 1
  heartbeatTimer' <- heartbeatTimer <+= 1
  r <- use role
  electTimeout <- readTimeout <$> use electionTimeout
  hbTimeout <- use heartbeatTimeout
  when (electionTimer' >= electTimeout && r /= Leader) convertToCandidate
  when (heartbeatTimer' >= hbTimeout && r == Leader) sendHeartbeats
  -- Increment server addition timer, if present
  serverAddition %= fmap (over roundTimer (+1))

handleAppendEntriesReq :: MonadLogger m => ServerId -> ServerId -> AppendEntriesReq a -> ServerT a b m ()
handleAppendEntriesReq fromAddr toAddr r = do
  successful <- handleAppendEntries r
  electionTimer .= 0
  updatedTerm <- use serverTerm
  lastLog <- last <$> use entryLog
  tell1 $ AERes AppendEntriesRes { _from = toAddr
                                 , _to = fromAddr
                                 , _term = updatedTerm
                                 , _success = successful
                                 , _logIndex = lastLog^.index }

checkForNewTerm :: MonadLogger m => Term -> ServerT a b m ()
checkForNewTerm rpcTerm = do
  currentTerm <- use serverTerm
  notFollower <- (/= Follower) <$> use role
  when (rpcTerm > currentTerm) $ do
    logInfoN $ T.pack $ "Received RPC with term " ++ (show . unTerm) rpcTerm ++ " > current term " ++ (show . unTerm) currentTerm
    serverTerm .= rpcTerm
    when notFollower convertToFollower

handleAppendEntriesRes :: MonadLogger m => ServerId -> ServerId -> AppendEntriesRes -> ServerT a b m ()
handleAppendEntriesRes fromAddr toAddr r = do
  isLeader <- (== Leader) <$> use role
  when isLeader $ do
    -- If this RPC is from a server that we're trying to add to the cluster, treat it
    -- differently
    addition <- use serverAddition
    case addition of
      Just add -> if add^.newServer == fromAddr
                     then handleCatchupAppendEntriesRes fromAddr toAddr r add
                     else handleNormalAppendEntriesRes fromAddr toAddr r
      Nothing -> handleNormalAppendEntriesRes fromAddr toAddr r

handleNormalAppendEntriesRes :: MonadLogger m => ServerId -> ServerId -> AppendEntriesRes -> ServerT a b m ()
handleNormalAppendEntriesRes fromAddr _toAddr r = do
  -- update nextIndex and matchIndex for follower
  -- the follower has told us what its most recent log entry is,
  -- so we set matchIndex equal to that and nextIndex to the index after that.
  -- matchIndex[followerId] := RPC.index
  -- nextIndex[followerId] := RPC.index + 1
  next <- use $ nextIndex . at fromAddr
  match <- use $ matchIndex . at fromAddr
  case (next, match) of
    (Just _, Just _) -> do
      nextIndex . at fromAddr ?= r^.logIndex + 1
      matchIndex . at fromAddr ?= r^.logIndex
      checkCommitIndex
      applyCommittedLogEntries
      unless (r^.success) $ sendAppendEntries fromAddr (r^.logIndex + 1)
    _ -> error "expected nextIndex and matchIndex to have element!"

handleCatchupAppendEntriesRes :: MonadLogger m => ServerId -> ServerId -> AppendEntriesRes -> ServerAddition -> ServerT a b m ()
handleCatchupAppendEntriesRes fromAddr toAddr r addition = do
  logInfoN "Handling AppendEntries from new server that is catching up"
  -- update nextIndex and matchIndex
  nextIndex . at fromAddr ?= r^.logIndex + 1
  matchIndex . at fromAddr ?= r^.logIndex

  -- check if max rounds reached
  eTimeout <- readTimeout <$> use electionTimeout
  if addition^.currentRound > addition^.maxRounds
  then do
    logInfoN "Max rounds exhausted"
    serverAddition .= Nothing
    nextIndex %= Map.delete fromAddr
    matchIndex %= Map.delete fromAddr
    tell1 $ ASRes AddServerRes { _leaderHint = Just toAddr, _status = AddServerTimeout, _requestId = addition^.requestId }
  else do
    -- check for round completion
    if addition^.roundIndex == r^.logIndex
    then do
      -- if completed round lasted less than election timeout, complete addition by
      -- adding the server to the cluster (this involves creating a configuration log
      -- entry and appending it to the log).
      if addition^.roundTimer < eTimeout
      then do
        logInfoN "New server has caught up - adding it to the cluster"
        logInfoN "NOTE: Cluster configuration changes not yet supported, so actually doing nothing here"
        pure ()
      else do
        -- start new round
        -- TODO: use a lens for this
        mostRecentLogIndex <- (^.index) . head <$> use entryLog
        serverAddition ?= ServerAddition { _newServer = addition^.newServer
                                         , _maxRounds = addition^.maxRounds
                                         , _requestId = addition^.requestId
                                         , _currentRound = addition^.currentRound + 1
                                         , _roundIndex = mostRecentLogIndex
                                         , _roundTimer = 0
                                         }
        sendAppendEntries fromAddr (r^.logIndex + 1)
    else
      -- (roundTimer . addition) += 1
      sendAppendEntries fromAddr (r^.logIndex + 1)


handleRequestVoteReq :: MonadLogger m => ServerId -> ServerId -> RequestVoteReq -> ServerT a b m ()
handleRequestVoteReq fromAddr toAddr r = do
  logInfoN (T.pack $ "Received RequestVoteReq from " ++ show fromAddr)
  voteGranted <- handleRequestVote r
  updatedTerm <- use serverTerm
  logInfoN (T.pack $ "Sending RequestVoteRes from " ++ show fromAddr ++ " to " ++ show toAddr)
  tell1 $ RVRes RequestVoteRes { _from = toAddr , _to = fromAddr , _voterTerm = updatedTerm , _requestVoteSuccess = voteGranted }

handleRequestVoteRes :: MonadLogger m => ServerId -> ServerId -> RequestVoteRes -> ServerT a b m ()
handleRequestVoteRes fromAddr toAddr r = do
  let voteGranted = r^.requestVoteSuccess
  isCandidate <- (== Candidate) <$> use role
  unless isCandidate $ logInfoN (T.pack $ "Ignoring RequestVoteRes from " ++ show fromAddr ++ ": not candidate")
  logInfoN (T.pack $ "Received RequestVoteRes from " ++ show fromAddr ++ ", to " ++ show toAddr ++ ", vote granted: " ++ show voteGranted)
  when (isCandidate && voteGranted) $ do
    votes <- (+1) <$> use votesReceived
    votesReceived .= votes
    logInfoN (T.pack $ "received " ++ show votes ++ " votes")
    minimumVotes <- use minVotes
    checkForElectionVictory minimumVotes

checkForElectionVictory :: MonadLogger m => Int -> ServerT a b m ()
checkForElectionVictory minNumberOfVotes = do
  votes <- use votesReceived
  total <- (+ 1) . length <$> use serverIds
  when ((votes % total > 1 % 2) && (votes >= minNumberOfVotes)) $ do
    logInfoN (T.pack $ "obtained " ++ show (votes % total) ++ " majority")
    convertToLeader

handleClientRequest :: MonadLogger m => ClientReq a -> ServerT a b m ()
handleClientRequest r = do
  let c = r^.requestPayload
      reqId = r^.clientRequestId
  currentRole <- use role
  leaderAddr <- use leaderId
  case (currentRole, leaderAddr) of
    (Leader, _) -> do
      logInfoN "responding to client request"
      log <- use entryLog
      currentTerm <- use serverTerm
      let nextLogIndex = toInteger $ length log
          entry = LogEntry { _index = nextLogIndex , _term = currentTerm , _payload = LogCommand c , _requestId = reqId}
      entryLog %= \l -> l ++ [entry]
      -- broadcast this new entry to followers
      sids <- use serverIds
      mapM_ (`sendAppendEntries` nextLogIndex) sids
      -- Shortcut for when we're the only node in the cluster
      checkCommitIndex
      applyCommittedLogEntries
    (_, mLeader) -> do
      tell1 $ CRes
        ClientResFailure { _responseError = "Node is not leader"
                         , _responseId = reqId
                         , _leader = mLeader }
      pure ()

-- reply false if term < currentTerm
-- reply false if log doesn't contain an entry at prevLogIndex whose term
--   matches prevLogTerm
-- append entries to the log
-- if leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of
--   last new entry)
handleAppendEntries :: MonadLogger m => AppendEntriesReq a -> ServerT a b m Bool
handleAppendEntries r = do
  log <- use entryLog
  currentCommitIndex <- use commitIndex
  currentTerm <- use serverTerm
  case validateAppendEntries currentTerm log r of
    Left failureReason -> logInfoN failureReason >> pure False
    Right () -> do
      -- Append new entries to log
      unless (null (r^.entries)) $ logDebugN $ T.pack $ "Appending entries to log: " ++ show (map (^.index) (r^.entries))
      entryLog %= (\l -> appendEntries l (r^.entries))

      -- Update commit index
      when (r^.leaderCommit > currentCommitIndex) $ do
        lastNewEntry <- last <$> use entryLog
        commitIndex .= min (r^.leaderCommit) (lastNewEntry^.index)

      -- Update knowledge of leader
      leaderId .= Just (r^.from)
      pure True

validateAppendEntries :: Term -> Log a -> AppendEntriesReq a -> Either Text ()
validateAppendEntries currentTerm log rpc =
  if rpc^.leaderTerm < currentTerm
     then Left "AppendEntries denied: term < currentTerm"
     else case matchingLogEntry of
            Nothing -> Left "AppendEntries denied: no entry found"
            Just _  -> Right ()
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
handleRequestVote :: MonadLogger m => RequestVoteReq -> ServerT a b m Bool
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

handleAddServerReq :: MonadLogger m => RequestId -> ServerId -> ServerT a b m ()
handleAddServerReq reqId newServerAddr = do
  isLeader <- (== Leader) <$> use role
  if isLeader
  then do
    -- Set up ServerAddition
    mostRecentLogIndex <- (\x -> x - 1) . toInteger . length <$> use entryLog
    serverAddition .= Just ServerAddition
      { _newServer = newServerAddr
      , _maxRounds = 10
      , _currentRound = 1
      , _roundIndex = mostRecentLogIndex
      , _roundTimer = 0
      , _requestId = reqId
      }

    -- Add server to nextIndex and matchIndex
    nextIndex %= (Map.insert newServerAddr 0)
    matchIndex %= (Map.insert newServerAddr 0)

    -- Send single AppendEntriesReq to server
    sendAppendEntries newServerAddr mostRecentLogIndex
  else do
    l <- use leaderId
    tell1 $ ASRes AddServerRes { _status = AddServerNotLeader, _leaderHint = l, _requestId = reqId }
    pure ()

-- Raft determines which of two logs is more up-to-date by comparing the index
-- and term of the last entries in the logs. If the logs have last entries with
-- different terms, then the log with the later term is more up-to-date.
-- If the logs end with the same term, then whichever log is longer is more
-- up-to-date.
upToDate :: LogIndex -> Term -> Log a -> Bool
upToDate logAIndex logATerm logB =
  case compare logATerm (lastEntry^.term) of
    GT -> True
    LT -> False
    EQ -> logAIndex >= lastEntry^.index
  where lastEntry = last logB

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
findByIndex l i = Just $ l `Safe.at` fromInteger i

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
  let rpc sid = RequestVoteReq { _from = ownId
                               , _to = sid
                               , _candidateTerm = newTerm
                               , _lastLogIndex = lastLogEntry ^. index
                               , _lastLogTerm = lastLogEntry ^. term }
  mapM_ (\i -> logInfoN (T.pack $ "Sending RequestVoteReq from self (" ++ show ownId ++ ") to " ++ show i)) servers
  tell $ map (RVReq . rpc) servers
  -- Shortcut for when we're the only node in the cluster
  minimumVotes <- use minVotes
  checkForElectionVictory minimumVotes

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
  where mkNextIndex :: LogIndex -> [ServerId] -> HashMap ServerId LogIndex
        mkNextIndex i = foldl (\m sid -> Map.insert sid (i + 1) m) Map.empty
        mkMatchIndex :: [ServerId] -> HashMap ServerId LogIndex
        mkMatchIndex = foldl (\m sid -> Map.insert sid 0 m) Map.empty

sendHeartbeats :: MonadLogger m => ServerT a b m ()
sendHeartbeats = do
  servers <- use serverIds
  log <- use entryLog
  state <- get
  let lastEntry = last log
      mkHeartbeat toAddr = AEReq $ mkAppendEntries state toAddr lastEntry []
  tell $ map mkHeartbeat servers
  heartbeatTimer .= 0

sendAppendEntries :: MonadLogger m => ServerId -> LogIndex -> ServerT a b m ()
sendAppendEntries followerId nextLogIndex = do
  logInfoN $ T.unwords ["Sending AppendEntries to", (T.pack . show) followerId, "for log", (T.pack . show) nextLogIndex]
  log <- use entryLog
  state <- get
  let entry = log `Safe.at` fromInteger nextLogIndex
      prevEntry = log `Safe.at` fromInteger (nextLogIndex - 1)
      req = AEReq $ mkAppendEntries state followerId prevEntry [entry]
  tell1 req
  heartbeatTimer .= 0

-- if there exists an N such that N > commitIndex, a majority of matchIndex[i]
--   >= N, and log[N].term == currentTerm: set commitIndex = N
-- Previously we would check the case of N = commitIndex + 1
-- This works provided that the log at index N was created in the current term -
-- if it was created in a previous term then we will not update commitIndex and we'll get
-- stuck at this point forever.
-- Instead, we find the smallest N such that log[N].term == currentTerm, and use that.
-- If we've not created any log entries this term, then there's nothing we can do anyway.
checkCommitIndex :: MonadLogger m => ServerT a b m ()
checkCommitIndex = do
  log <- use entryLog
  currentTerm <- use serverTerm
  matchIndex_ <- use matchIndex
  cIndex <- use commitIndex
  let entrym = headMay $ filter ((> cIndex) . (^.index)) $ filter ((== currentTerm) . (^.term)) log
  case fmap (^.index) entrym of
    Nothing -> pure ()
    Just n -> do
      -- matchIndex currently doesn't include the current server, so we also check
      -- if we are up to date, and include that accordingly
      let selfUpToDate = if length log >= fromInteger n then 1 else 0
          numServersUpToDate = selfUpToDate + Map.size (Map.filter (>= n) matchIndex_)
          total = Map.size matchIndex_ + 1
          majorityUpToDate = (numServersUpToDate % total) > (1 % 2)
          entryAtN = atMay log (fromInteger n)
      case entryAtN of
        Nothing -> pure ()
        Just e -> when (majorityUpToDate && e^.term == currentTerm) $ do
                    logInfoN (T.pack $ "updating commitIndex to " ++ show n)
                    commitIndex .= n

-- if commitIndex > lastApplied:
--   increment lastApplied
--   if log[lastApplied] holds a state machine command:
--     apply log[lastApplied] to state machine
--   broadcast "log applied" event (this is a form of client response)
applyCommittedLogEntries :: MonadLogger m => ServerT a b m ()
applyCommittedLogEntries = do
  applyFn <- use apply
  lastAppliedIndex <- use lastApplied
  lastCommittedIndex <- use commitIndex
  log <- use entryLog
  when (lastCommittedIndex > lastAppliedIndex) $ do
    lastApplied' <- lastApplied <+= 1
    let entry = fromJust $ findByIndex log lastApplied'
    case entry^.payload of
      LogConfig _ -> do
        logInfoN (T.pack $ "committing config change from entry " ++ show (entry^.index))
      LogCommand cmd -> do
        logInfoN (T.pack $ "applying entry " ++ show (entry^.index))
        res <- (lift . lift) $ applyFn cmd
        tell1 $ CRes
          ClientResSuccess {_responsePayload = Right res, _responseId = entry^.requestId}

mkAppendEntries :: ServerState a b m -> ServerId -> LogEntry a -> [LogEntry a] -> AppendEntriesReq a
mkAppendEntries s toAddr prevEntry newEntries =
  AppendEntriesReq { _from = s^.selfId
                   , _to = toAddr
                   , _leaderTerm = s^.serverTerm
                   , _prevLogIndex = prevEntry^.index
                   , _prevLogTerm = prevEntry^.term
                   , _entries = newEntries
                   , _leaderCommit = s^.commitIndex
                   }

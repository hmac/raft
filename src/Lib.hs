module Lib
    ( someFunc
    ) where

import           Data.Maybe
import           Prelude    hiding (log)

someFunc :: IO ()
someFunc = putStrLn "someFunc"

data LogEntry a = LogEntry
  { eIndex   :: LogIndex
  , eTerm    :: Term
  , eCommand :: a
  }

newtype Term = Term { unTerm :: Int } deriving (Eq, Ord)

-- needs to be 1-indexed - maybe use something other than a list?
type Log a = [LogEntry a]
type LogIndex = Int
type ServerId = Int

data ServerState a = ServerState
  -- latest term server has seen (initialised to 0, increases monotonically)
  { sCurrentTerm :: Term
  -- Candidate ID that received vote in current term (or None)
  , sVotedFor    :: Maybe ServerId
  -- log entries (first index is 1)
  , sLog         :: Log a
  -- index of highest log entry known to be committed (initialised to 0,
  -- increases monotonically)
  , sCommitIndex :: LogIndex
  -- index of highest log entry applied to state machine (initialised to 0,
  -- increases monotonically)
  , sLastApplied :: LogIndex
  }

data LeaderState = LeaderState
  -- for each server, index of the next log entry to send to that server
  -- (initialised to last log index + 1)
  { lNextIndex  :: [LogIndex]
  -- for each server, index of the highest log entry known to be replicated on
  -- server (initialised to 0, increases monotonically)
  , lMatchIndex :: [LogIndex]
  }

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

data RpcReq a = RpcAppendEntries (AppendEntries a) | RpcRequestVote (RequestVote a)
data RpcRes = RpcRes Term Bool

handleRpc :: ServerState a -> RpcReq a -> (ServerState a, RpcRes)
handleRpc s (RpcAppendEntries r) = let (success, s') = handleAppendEntries s r
                                    in (s', RpcRes (sCurrentTerm s') success)
handleRpc s (RpcRequestVote r)   = let (voteGranted, s') = handleRequestVote s r
                                    in (s', RpcRes (sCurrentTerm s') voteGranted)

handleAppendEntries :: ServerState a -> AppendEntries a -> (Bool, ServerState a)
-- reply false if term < currentTerm
handleAppendEntries s r | aeTerm r < sCurrentTerm s = (False, s)
-- reply false if log doesn't contain an entry at prevLogIndex whose term
-- matches prevLogTerm
handleAppendEntries s r | isNothing (findEntry (sLog s) (aePrevLogIndex r) (aePrevLogTerm r)) = (False, s)
-- apply entries to the log
-- if leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of
-- last new entry)
handleAppendEntries s r =
  let log' = appendEntries (sLog s) (aeEntries r)
      commitIndex' = if aeLeaderCommit r > sCommitIndex s
                        then min (aeLeaderCommit r) (eIndex (last log'))
                        else sCommitIndex s
      s' = s { sLog = log', sCommitIndex = commitIndex' }
  in (True, s')

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

handleRequestVote :: ServerState a -> RequestVote a -> (Bool, ServerState a)
-- reply false if term < currentTerm
handleRequestVote s r | rvTerm r < sCurrentTerm s = (False, s)
-- if votedFor is null or candidateId, and candidate's log is at least as
-- up-to-date as receiver's log, grant vote
handleRequestVote s r = if (isNothing (sVotedFor s) || matchingVote) && logUpToDate
                           then (True, s { sVotedFor = Just (rvCandidateId r) })
                           else (False, s)
                             where matchingVote = sVotedFor s == Just (rvCandidateId r)
                                   -- N.B. is this the right way to determine up-to-date?
                                   logUpToDate = rvLastLogIndex r >= sCommitIndex s


findEntry :: Log a -> LogIndex -> Term -> Maybe (LogEntry a)
findEntry l i t = case findByIndex l i of
                            Nothing -> Nothing
                            Just e -> if eTerm e == t
                                         then Just e
                                         else Nothing

findByIndex :: Log a -> LogIndex -> Maybe (LogEntry a)
findByIndex l i | i < 0 = Nothing
findByIndex l i | i > length l = Nothing
findByIndex l i = Just $ l !! (i - 1)

data Message a =
    RecvRpc (RpcReq a)
  | SendRpc RpcRes
  | Tick
  | Apply (LogEntry a)

handleEvent :: ServerState a -> Message a -> (ServerState a, [Message a])
handleEvent s (RecvRpc rpc) = let (s', res) = handleRpc s rpc
                               in (s', [SendRpc res])
handleEvent s (SendRpc rpc) = (s, [SendRpc rpc])
handleEvent s Tick = let lastApplied = sLastApplied s
                         lastApplied' = lastApplied + 1
                         commitIndex = sCommitIndex s
                         log = sLog s
                         entry = fromJust $ findByIndex log lastApplied'
                      in if commitIndex > lastApplied
                            then (s { sLastApplied = lastApplied' }, [Apply entry])
                            else (s, [])

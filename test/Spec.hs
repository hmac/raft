import           Lib

data Command = NoOp deriving (Eq, Show)

main :: IO ()
main = do
  let t0 = Term { unTerm = 0 }
      s1 = mkServer 5
      s2 = mkServer 5
      entry = LogEntry { eIndex = 1, eTerm = t0, eCommand = NoOp }
      a = AppendEntries
        { aeTerm = t0
        , aeLeaderId = 1
        , aePrevLogIndex = 0
        , aePrevLogTerm = t0
        , aeEntries = [entry]
        , aeLeaderCommit = 0
        }
      m1 = RecvRpc (AppendEntriesReq a)
      (s1', msgs) = handleMessage s1 m1
  putStrLn "server state:"
  print s1'
  putStrLn "message:"
  print m1
  putStrLn "response:"
  mapM_ print msgs
  putStrLn "new state:"
  print s1'
  putStrLn "sending response to m2"
  let (s2', msgs2) = handleMessage s2 (head msgs)
  putStrLn "response:"
  mapM_ print msgs2
  putStrLn "new state:"
  print s2'
  putStrLn "tests finished"

mkServer :: Int -> ServerState Command
mkServer electionTimeout = ServerState
  { sCurrentTerm = t0
  , sVotedFor = Nothing
  , sLog = [LogEntry { eIndex = 0, eTerm = t0, eCommand = NoOp }]
  , sCommitIndex = 0
  , sLastApplied = 0
  , sTock = 0
  , sElectionTimeout = electionTimeout
  }
    where t0 = Term { unTerm = 0 }

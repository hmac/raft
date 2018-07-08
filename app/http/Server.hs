{-# LANGUAGE NamedFieldPuns #-}
module Server where

import           Control.Concurrent
import           Control.Monad              (forever)
import           Control.Monad.Log          (runPureLoggingT)
import           Control.Monad.State.Strict hiding (state)
import           Data.Map.Strict            (Map)
import qualified Data.Text                  as T
import           Data.Time.Clock            (getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime,
                                             iso8601DateFormat)
import           Raft
import           Raft.Log                   (RequestId)
import           Raft.Server                (ServerState (..))

data Config a b machine = Config { state :: MVar (ServerState a, machine)
                                 , queue :: Chan (Message a b)
                                 , apply :: a -> StateT machine IO b
                                 , requests :: MVar (Map RequestId (MVar (Message a b)))
                                 }
-- server receives three types of message:
-- - clock ticks from its clock (via a channel)
-- - RPCs from other servers (via a mailbox message)
-- - requests from a client (via the same mechanism)
runServer :: (Show a, Show machine) => Config a b machine -> IO ThreadId
runServer config = forkIO $ do
  _ <- forkIO $ forever (logState config)
  forever $ do
    threadDelay 1000 -- 1ms
    processMessage config (Tick 0)

logState :: (Show a, Show machine) => Config a b machine -> IO ()
logState Config { state } = do
  threadDelay 2000000
  (ServerState { _role, _serverTerm, _electionTimer, _electionTimeout }, m) <- readMVar state
  print (_role, _serverTerm, _electionTimer, _electionTimeout, m)

-- Apply a Raft message to the state
-- Prints out any logs generated
processMessage :: Config a b machine -> Message a b -> IO ()
processMessage Config { state, queue, apply } msg = do
  (s, m) <- takeMVar state
  let writer = handleMessage apply msg
  result <- runStateT (runStateT (runPureLoggingT writer) s) m
  case result of
    (((msgs, logs), s'), m') -> do
      mapM_ printLog logs
      writeList2Chan queue msgs
      putMVar state (s', m')

printLog :: T.Text -> IO ()
printLog msg = do
  time <- getCurrentTime
  let format = iso8601DateFormat (Just "%H:%M:%S:%Q")
      timestamp = formatTime defaultTimeLocale format time
  putStrLn $ timestamp ++ " " ++ show msg

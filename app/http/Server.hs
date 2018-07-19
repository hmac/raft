{-# LANGUAGE NamedFieldPuns #-}
module Server where

import           Control.Concurrent
import           Control.Monad              (forever)
import           Control.Monad.Logger
import           Control.Monad.State.Strict hiding (state)
import           Data.Map.Strict            (Map)
import qualified Data.Text                  as T
import           Data.Time.Clock            (getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime,
                                             iso8601DateFormat)
import           Raft
import           Raft.Log                   (RequestId)
import           Raft.Server                (ServerState (..), readTimeout,
                                             unMonotonicCounter)

data Config a b machine = Config { state :: MVar (ServerState a, machine)
                                 , queue :: Chan (Message a b)
                                 , apply :: a -> StateT machine (LoggingT IO) b
                                 , requests :: MVar (Map RequestId (MVar (Message a b)))
                                 }

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
  print (_role, _serverTerm, unMonotonicCounter _electionTimer, (unMonotonicCounter . readTimeout) _electionTimeout, m)

-- Apply a Raft message to the state
-- Prints out any logs generated
processMessage :: Config a b machine -> Message a b -> IO ()
processMessage Config { state, queue, apply } msg = do
  (s, m) <- takeMVar state
  (msgs, server', machine') <- runStderrLoggingT (handleMessage_ s m msg apply)
  putMVar state (server', machine')
  writeList2Chan queue msgs

handleMessage_ :: ServerState a -> machine -> Message a b -> (a -> StateT machine (LoggingT IO) b) -> LoggingT IO ([Message a b], ServerState a, machine)
handleMessage_ server machine msg apply = do
  ((msgs, server'), machine') <- runStateT (runStateT (handleMessage apply msg) server) machine
  pure (msgs, server', machine')

printLog :: T.Text -> IO ()
printLog msg = do
  time <- getCurrentTime
  let format = iso8601DateFormat (Just "%H:%M:%S:%Q")
      timestamp = formatTime defaultTimeLocale format time
  putStrLn $ timestamp ++ " " ++ show msg

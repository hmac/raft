{-# LANGUAGE NamedFieldPuns    #-}
module Client where

import           Data.Maybe          (fromMaybe)
import qualified Data.Text.IO        as T (putStrLn)
import           Network.HTTP.Client (Manager, defaultManagerSettings,
                                      newManager)
import           Servant
import           Servant.Client
import           System.Random
import Data.List (find)

import           Api
import           Config
import           Raft.Log            (RequestId (RequestId))
import           Raft.Rpc            (ClientReq (..), ClientRes (..))
import           Raft.Server         (ServerId (..))

runClient :: String -> Command -> IO ()
runClient nodeUrl cmd = do
  reqId <- RequestId <$> randomIO
  let req = ClientReq { _requestPayload = cmd, _clientRequestId = reqId }
  manager <- newManager defaultManagerSettings
  url <- parseBaseUrl nodeUrl
  let env = ClientEnv { manager = manager, baseUrl = url, cookieJar = Nothing }
  res <- runClientM (sendClientRequest req) env
  case res of
    Left (ConnectionError e)                        -> T.putStrLn e
    Left err                                        -> print err
    Right ClientResSuccess { _responsePayload = p } -> print p
    Right ClientResFailure { _responseError = err, _leader = ml } -> do
      T.putStrLn err
      case ml of
        Just (ServerId l) -> do
          putStrLn $ "Leader discovered: " ++ l ++ " - retrying request"
          runClient l cmd
        Nothing -> pure ()

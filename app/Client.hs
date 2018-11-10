{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
module Client where

import           Data.List           (find)
import           Data.Maybe          (fromMaybe)
import qualified Data.Text.IO        as T (putStrLn)
import           Network.HTTP.Client (Manager, defaultManagerSettings,
                                      newManager)
import           Servant
import           Servant.Client
import           System.Random

import qualified Api
import           Config
import           Raft.Log            (RequestId (RequestId), ServerId (..))
import           Raft.Rpc            (AddServerReq (..), AddServerRes (..),
                                      AddServerStatus (..), ClientReq (..),
                                      ClientRes (..))

data Command
  = ApiCommand Api.Command
  | AddServer ServerId

runClient :: String -> Command -> IO ()
runClient nodeUrl cmd = do
  manager <- newManager defaultManagerSettings
  url <- parseBaseUrl nodeUrl
  let env = ClientEnv { manager = manager, baseUrl = url, cookieJar = Nothing }
  case cmd of
    ApiCommand c  -> runApiCommand env c
    AddServer sid -> runAddServer env sid

runApiCommand :: ClientEnv -> Api.Command -> IO ()
runApiCommand env cmd = do
  reqId <- RequestId <$> randomIO
  let req = ClientReq { _requestPayload = cmd, _clientRequestId = reqId }
  res <- runClientM (Api.sendClientRequest req) env
  case res of
    Left (ConnectionError e)                        -> T.putStrLn e
    Left err                                        -> print err
    Right ClientResSuccess { _responsePayload = p } -> print p
    Right ClientResFailure { _responseError = err, _leader = ml } -> do
      T.putStrLn err
      case ml of
        Just (ServerId l) -> do
          putStrLn $ "Leader discovered: " ++ l ++ " - retrying request"
          runClient l (ApiCommand cmd)
        Nothing -> pure ()

runAddServer :: ClientEnv -> ServerId -> IO ()
runAddServer env serverId = do
  reqId <- RequestId <$> randomIO
  let req = AddServerReq { _newServer = serverId, _requestId = reqId }
  res <- runClientM (Api.sendAddServer req) env
  case res of
    Left (ConnectionError e)                        -> T.putStrLn e
    Left err                                        -> print err
    Right AddServerRes { _status = s, _leaderHint = ml } ->
      case s of
        AddServerOk -> print s
        AddServerTimeout -> print s
        AddServerNotLeader -> do
          print s
          case ml of
            Just (ServerId l) -> do
              putStrLn $ "Leader discovered: " ++ l ++ " - retrying request"
              runClient l (AddServer serverId)
            Nothing -> pure ()

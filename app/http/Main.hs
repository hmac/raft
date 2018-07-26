module Main where

import           Client
import           Server
import           System.Environment (getArgs)

main = do
  args <- getArgs
  case args of
    "server" : rest -> runServer rest
    "client" : rest -> runClient rest
    _               -> error "Invalid role. Must be one of server, client."

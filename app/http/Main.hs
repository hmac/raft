module Main where

import           Client
import           Options.Applicative
import           Server
import           System.Environment  (getArgs)

import           Api                 (Command (..))

data Options = ServerOpts String
             | ClientOpts String Command

main = do
  args <- execParser options
  case args of
    ServerOpts s   -> runServer s
    ClientOpts s c -> runClient s c

options = info parser $ fullDesc
                     <> progDesc "Raft HTTP"
                     <> header "Raft HTTP"

parser = hsubparser $ command "server" (info serverOptions (progDesc "Start the server"))
                   <> command "client" clientOptions

serverOptions = ServerOpts <$> strArgument (metavar "[hostname]")

clientOptions = info (ClientOpts <$> strArgument (metavar "[hostname]") <*> clientCmd)
                     (fullDesc <> progDesc "Issue a client request")

clientCmd = hsubparser $ command "set" (info set (fullDesc <> progDesc "set a value"))
                      <> command "get" (info get (fullDesc <> progDesc "get a value"))
  where set = Set <$> strArgument (metavar "[key]") <*> strArgument (metavar "[value]")
        get = Get <$> strArgument (metavar "[key]")

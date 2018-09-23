module Main where

import           Client
import           Options.Applicative
import           Server
import           System.Environment  (getArgs)

import           Api                 (Command (..))
import Config

data Options = ServerOpts String String
             | ClientOpts String String Command

main = do
  args <- execParser options
  case args of
    ServerOpts name configPath   -> parseConfig configPath >>= runServer name
    ClientOpts name configPath c -> parseConfig configPath >>= runClient name c

options = info parser $ fullDesc
                     <> progDesc "Raft HTTP"
                     <> header "Raft HTTP"

parser = hsubparser $ command "server" (info serverOptions (progDesc "Start the server"))
                   <> command "client" (info clientOptions (progDesc "Issue a client request"))

serverOptions = ServerOpts <$> strArgument (metavar "[name]")
                           <*> strArgument (metavar "[path to config file]")


clientOptions = ClientOpts <$> strArgument (metavar "[node name]")
                           <*> strArgument (metavar "[path to config file]")
                           <*> clientCmd

clientCmd = hsubparser $ command "set" (info set (fullDesc <> progDesc "set a value"))
                      <> command "get" (info get (fullDesc <> progDesc "get a value"))
  where set = Set <$> strArgument (metavar "[key]") <*> strArgument (metavar "[value]")
        get = Get <$> strArgument (metavar "[key]")

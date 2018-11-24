module Main where

import           Client
import           Options.Applicative
import           Server

import qualified Api                 (Command (..))
import qualified Client              (Command (..))
import           Raft.Log            (ServerId (ServerId))

data Options
  = ServerOpts String
               Bool -- ^ start in bootstrap mode?
  | ClientOpts String
               Client.Command

main :: IO ()
main = do
  args <- execParser options
  case args of
    ServerOpts name bootstrap -> runServer name bootstrap
    ClientOpts name cmd       -> runClient name cmd

options :: ParserInfo Options
options = info parser $ fullDesc
                     <> progDesc "Raft HTTP"
                     <> header "Raft HTTP"

parser :: Parser Options
parser = hsubparser $ command "server" (info serverOptions (progDesc "Start the server"))
                   <> command "client" (info clientOptions (progDesc "Issue a client request"))

serverOptions :: Parser Options
serverOptions = ServerOpts <$> strArgument (metavar "[address]")
                           <*> flag False True (long "bootstrap" <> help "Start in bootstrap mode")

clientOptions :: Parser Options
clientOptions = ClientOpts <$> strArgument (metavar "[node address]")
                           <*> clientCmd

clientCmd :: Parser Command
clientCmd = hsubparser $ command "set" (info (Client.ApiCommand <$> set) (fullDesc <> progDesc "set a value"))
                      <> command "get" (info (Client.ApiCommand <$> get) (fullDesc <> progDesc "get a value"))
                      <> command "add-server" (info addServer (fullDesc <> progDesc "add a server"))
  where set = Api.Set <$> strArgument (metavar "[key]") <*> strArgument (metavar "[value]")
        get = Api.Get <$> strArgument (metavar "[key]")
        addServer = Client.AddServer . ServerId <$> strArgument (metavar "[server address]")

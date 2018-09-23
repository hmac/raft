{-# LANGUAGE DeriveGeneric #-}

module Config (ClusterConfig(..), NodeConfig(..), parseConfig) where

import           Dhall
import qualified Data.Text as T

newtype ClusterConfig = ClusterConfig { nodes :: [NodeConfig] } deriving (Show, Eq, Generic)
data NodeConfig = NodeConfig { name :: String, address :: String } deriving (Show, Eq, Generic)
instance Interpret ClusterConfig
instance Interpret NodeConfig

parseConfig :: String -> IO ClusterConfig
parseConfig path = input auto (T.pack path)

{-# LANGUAGE DeriveGeneric #-}

module Config (ClusterConfig(..), NodeConfig(..), parseConfig) where

import qualified Data.Text as T
import           Dhall

data ClusterConfig = ClusterConfig { nodes    :: [NodeConfig]
                                   , minNodes :: Natural
                                   } deriving (Show, Eq, Generic)
newtype NodeConfig = NodeConfig { address :: String } deriving (Show, Eq, Generic)
instance Interpret ClusterConfig
instance Interpret NodeConfig

parseConfig :: String -> IO ClusterConfig
parseConfig path = input auto (T.pack path)

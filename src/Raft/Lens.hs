{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeSynonymInstances   #-}

module Raft.Lens (module Raft.Lens, (^.)) where
import           Control.Lens

import           Raft.Log
import           Raft.Rpc
import           Raft.Server

makeFieldsNoPrefix ''AppendEntriesReq
makeFieldsNoPrefix ''AppendEntriesRes
makeFieldsNoPrefix ''RequestVoteReq
makeFieldsNoPrefix ''RequestVoteRes
makeFieldsNoPrefix ''ClientReq
makeFieldsNoPrefix ''ClientRes

makeFieldsNoPrefix ''LogEntry
makeLenses ''ServerState

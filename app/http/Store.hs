module Store (mkStore, insert, lookup, delete) where

import           Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import           Data.IORef
import           Prelude            hiding (lookup)

data Store a = Store (IntMap a) (IORef Int)

mkStore :: IO (Store a)
mkStore = do
  keyGenerator <- newIORef 0
  pure $ Store IntMap.empty keyGenerator

insert :: a -> Store a -> IO (Store a)
insert val (Store intMap gen) = do
  key <- atomicModifyIORef' gen (\n -> (n + 1, n))
  pure $ Store (IntMap.insert key val intMap) gen

delete :: Int -> Store a -> IO (Store a)
delete key (Store intMap gen) = pure $ Store (IntMap.delete key intMap) gen

lookup :: Int -> Store a -> Maybe a
lookup key (Store intMap _) = IntMap.lookup key intMap

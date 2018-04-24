{-# LANGUAGE DeriveGeneric #-}
module Timer (periodically, milliSeconds) where

import           Control.Distributed.Process
import           Control.Monad               (unless)
import           Data.Binary                 (Binary)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)

periodically :: TimeInterval -> Process () -> Process ProcessId
periodically t p = spawnLocal $ runTimer t p False

milliSeconds :: Int -> TimeInterval
milliSeconds = TimeInterval Millis

runTimer :: TimeInterval -> Process () -> Bool -> Process ()
runTimer t proc cancelOnReset = do
    cancel <- expectTimeout (asTimeout t)
    -- say $ "cancel = " ++ (show cancel) ++ "\n"
    case cancel of
        Nothing     -> runProc cancelOnReset
        Just Cancel -> return ()
        Just Reset  -> unless cancelOnReset $ runTimer t proc cancelOnReset
  where runProc True  = proc
        runProc False = proc >> runTimer t proc cancelOnReset

data TimeInterval = TimeInterval TimeUnit Int
    deriving (Typeable, Generic, Eq, Show)

instance Binary TimeInterval where

data TimerConfig = Reset | Cancel
    deriving (Typeable, Generic, Eq, Show)
instance Binary TimerConfig where

data TimeUnit = Days | Hours | Minutes | Seconds | Millis | Micros
    deriving (Typeable, Generic, Eq, Show)

instance Binary TimeUnit where

asTimeout :: TimeInterval -> Int
asTimeout (TimeInterval u v) = timeToMicros u v

{-# INLINE timeToMicros #-}
timeToMicros :: TimeUnit -> Int -> Int
timeToMicros Micros  us   = us
timeToMicros Millis  ms   = ms  * (10 ^ (3 :: Int)) -- (1000µs == 1ms)
timeToMicros Seconds secs = timeToMicros Millis  (secs * milliSecondsPerSecond)
timeToMicros Minutes mins = timeToMicros Seconds (mins * secondsPerMinute)
timeToMicros Hours   hrs  = timeToMicros Minutes (hrs  * minutesPerHour)
timeToMicros Days    days = timeToMicros Hours   (days * hoursPerDay)

{-# INLINE hoursPerDay #-}
hoursPerDay :: Int
hoursPerDay = 24

{-# INLINE minutesPerHour #-}
minutesPerHour :: Int
minutesPerHour = 60

{-# INLINE secondsPerMinute #-}
secondsPerMinute :: Int
secondsPerMinute = 60

{-# INLINE milliSecondsPerSecond #-}
milliSecondsPerSecond :: Int
milliSecondsPerSecond = 1000

{-# INLINE microSecondsPerSecond #-}
microSecondsPerSecond :: Int
microSecondsPerSecond = 1000000

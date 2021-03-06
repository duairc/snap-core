-- | An internal Snap module for (optionally) printing debugging
-- messages. Normally 'debug' does nothing, but you can pass \"-fdebug\" to
-- @cabal install@ to build a @snap-core@ which debugs to stderr.
--
-- /N.B./ this is an internal interface, please don't write external code that
-- depends on it.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module Snap.Internal.Debug where

import           Control.Monad.Trans

#ifdef DEBUG_TEST

debug :: (MonadIO m) => String -> m ()
debug !s = return $ s `seq` ()
{-# INLINE debug #-}

debugErrno :: (MonadIO m) => String -> m ()
debugErrno !s = return $ s `seq` ()

#elif defined(DEBUG)

------------------------------------------------------------------------------
import           Control.Concurrent
import           Data.List
import           Data.Maybe
import           Foreign.C.Error
import           System.IO
import           System.IO.Unsafe
import           Text.Printf
------------------------------------------------------------------------------


------------------------------------------------------------------------------
_debugMVar :: MVar ()
_debugMVar = unsafePerformIO $ newMVar ()
{-# NOINLINE _debugMVar #-}

------------------------------------------------------------------------------
debug :: (MonadIO m) => String -> m ()
debug s = liftIO $ withMVar _debugMVar $ \_ -> do
              tid <- myThreadId
              hPutStrLn stderr $ s' tid
              hFlush stderr
  where
    chop x = let y = fromMaybe x $ stripPrefix "ThreadId " x
             in printf "%8s" y

    s' t   = "[" ++ chop (show t) ++ "] " ++ s

{-# INLINE debug #-}


------------------------------------------------------------------------------
debugErrno :: (MonadIO m) => String -> m ()
debugErrno loc = liftIO $ do
    err <- getErrno
    let ex = errnoToIOError loc err Nothing Nothing
    debug $ show ex
------------------------------------------------------------------------------

#else

------------------------------------------------------------------------------
debug :: (MonadIO m) => String -> m ()
debug _ = return ()
{-# INLINE debug #-}

debugErrno :: (MonadIO m) => String -> m ()
debugErrno _ = return ()
------------------------------------------------------------------------------

#endif

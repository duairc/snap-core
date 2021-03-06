{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- | Snap Framework type aliases and utilities for iteratees. Note that as a
-- convenience, this module also exports everything from @Data.Iteratee@ in the
-- @iteratee@ library.
--
-- /WARNING/: Note that all of these types are scheduled to change in the
-- @darcs@ head version of the @iteratee@ library; John Lato et al. are working
-- on a much improved iteratee formulation.

module Snap.Iteratee
  ( -- * Convenience aliases around types from @Data.Iteratee@
    Stream
  , IterV
  , Iteratee
  , Enumerator

    -- * Re-export types and functions from @Data.Iteratee@
  , module Data.Iteratee

    -- * Helper functions

    -- ** Enumerators
  , enumBS
  , enumLBS
  , enumFile

    -- ** Conversion to/from 'WrappedByteString'
  , fromWrap
  , toWrap

    -- ** Iteratee utilities
  , drop'
  , takeExactly
  , takeNoMoreThan
  , countBytes
  , bufferIteratee
  , mkIterateeBuffer
  , unsafeBufferIterateeWithBuffer
  , unsafeBufferIteratee
  ) where

------------------------------------------------------------------------------
import           Control.Monad
import           Control.Monad.CatchIO
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Unsafe as S
import qualified Data.ByteString.Lazy as L
import           Data.Int
import           Data.IORef
import           Data.Iteratee
#ifdef PORTABLE
import           Data.Iteratee.IO (enumHandle)
#endif
import qualified Data.Iteratee.Base.StreamChunk as SC
import           Data.Iteratee.WrappedByteString
import qualified Data.ListLike as LL
import           Data.Monoid (mappend)
import           Foreign
import           Foreign.C.Types
import           GHC.ForeignPtr
import           Prelude hiding (catch,drop)
import qualified Data.DList as D

#ifdef PORTABLE
import           Control.Monad.Trans (liftIO)
import           System.IO
#else
import           Control.Exception (SomeException)
import           System.IO.Posix.MMap
#endif

------------------------------------------------------------------------------

type Stream         = StreamG WrappedByteString Word8
type IterV      m   = IterGV WrappedByteString Word8 m
type Iteratee   m   = IterateeG WrappedByteString Word8 m
type Enumerator m a = Iteratee m a -> m (Iteratee m a)


------------------------------------------------------------------------------
instance (Functor m, MonadCatchIO m) =>
         MonadCatchIO (IterateeG s el m) where
    --catch  :: Exception  e => m a -> (e -> m a) -> m a
    catch m handler = IterateeG $ \str -> do
        ee <- try $ runIter m str
        case ee of
          (Left e)  -> runIter (handler e) str
          (Right v) -> return v

    --block :: m a -> m a
    block m = IterateeG $ \str -> block $ runIter m str
    unblock m = IterateeG $ \str -> unblock $ runIter m str


------------------------------------------------------------------------------
-- | Wraps an 'Iteratee', counting the number of bytes consumed by it.
countBytes :: (Monad m) => Iteratee m a -> Iteratee m (a, Int64)
countBytes = go 0
  where
    go !n iter = IterateeG $ f n iter

    f !n !iter ch@(Chunk ws) = do
        iterv <- runIter iter ch
        case iterv of
          Done x rest -> let !n' = n + m - len rest
                         in return $! Done (x, n') rest
          Cont i err  -> return $ Cont ((go $! n + m) i) err
      where
        m = fromIntegral $ S.length (unWrap ws)

        len (EOF _)   = 0
        len (Chunk s) = fromIntegral $ S.length (unWrap s)

    f !n !iter stream = do
        iterv <- runIter iter stream
        case iterv of
          Done x rest -> return $ Done (x, n) rest
          Cont i err  -> return $ Cont (go n i) err


------------------------------------------------------------------------------
-- | Buffers an iteratee.
--
-- Our enumerators produce a lot of little strings; rather than spending all
-- our time doing kernel context switches for 4-byte write() calls, we buffer
-- the iteratee to send 8KB at a time.
--
-- The IORef returned can be set to True to "cancel" buffering. We added this
-- so that transfer-encoding: chunked (which needs its own buffer and therefore
-- doesn't need /its/ output buffered) can switch the outer buffer off.
--
bufferIteratee :: Iteratee IO a -> IO (Iteratee IO a, IORef Bool)
bufferIteratee iteratee = do
    esc <- newIORef False
    return $ (start esc iteratee, esc)

  where
    blocksize = 8192

    start esc iter = IterateeG $! checkRef esc iter

    checkRef esc iter ch = do
        quit <- readIORef esc
        if quit
          then runIter iter ch
          else f (D.empty,0) iter ch

    --go :: (DList ByteString, Int) -> Iteratee m a -> Iteratee m a
    go (!dl,!n) iter = IterateeG $! f (dl,n) iter

    --f :: (DList ByteString, Int) -> Iteratee m a -> Stream -> m (IterV m a)
    f _       !iter ch@(EOF (Just _)) = runIter iter ch
    f (!dl,_) !iter ch@(EOF Nothing)  = do
        iter' <- if S.null str
                   then return iter
                   else liftM liftI $ runIter iter $ Chunk big
        runIter iter' ch
      where
        str = S.concat $ D.toList dl
        big = WrapBS str

    f (!dl,!n) iter (Chunk (WrapBS s)) =
        if n' >= blocksize
           then do
               iterv <- runIter iter (Chunk big)
               case iterv of
                  Done x rest     -> return $ Done x rest
                  Cont i (Just e) -> return $ Cont i (Just e)
                  Cont i Nothing  -> return $ Cont (go (D.empty,0) i) Nothing
           else return $ Cont (go (dl',n') iter) Nothing
      where
        m   = S.length s
        n'  = n+m
        dl' = D.snoc dl s
        big = WrapBS $ S.concat $ D.toList dl'


bUFSIZ :: Int
bUFSIZ = 8192


-- | Creates a buffer to be passed into 'unsafeBufferIterateeWithBuffer'.
mkIterateeBuffer :: IO (ForeignPtr CChar)
mkIterateeBuffer = mallocPlainForeignPtrBytes bUFSIZ

------------------------------------------------------------------------------
-- | Buffers an iteratee, \"unsafely\". Here we use a fixed binary buffer which
-- we'll re-use, meaning that if you hold on to any of the bytestring data
-- passed into your iteratee (instead of, let's say, shoving it right out a
-- socket) it'll get changed out from underneath you, breaking referential
-- transparency. Use with caution!
--
-- The IORef returned can be set to True to "cancel" buffering. We added this
-- so that transfer-encoding: chunked (which needs its own buffer and therefore
-- doesn't need /its/ output buffered) can switch the outer buffer off.
--
unsafeBufferIteratee :: Iteratee IO a -> IO (Iteratee IO a, IORef Bool)
unsafeBufferIteratee iter = do
    buf <- mkIterateeBuffer
    unsafeBufferIterateeWithBuffer buf iter


------------------------------------------------------------------------------
-- | Buffers an iteratee, \"unsafely\". Here we use a fixed binary buffer which
-- we'll re-use, meaning that if you hold on to any of the bytestring data
-- passed into your iteratee (instead of, let's say, shoving it right out a
-- socket) it'll get changed out from underneath you, breaking referential
-- transparency. Use with caution!
--
-- This version accepts a buffer created by 'mkIterateeBuffer'.
--
-- The IORef returned can be set to True to "cancel" buffering. We added this
-- so that transfer-encoding: chunked (which needs its own buffer and therefore
-- doesn't need /its/ output buffered) can switch the outer buffer off.
--
unsafeBufferIterateeWithBuffer :: ForeignPtr CChar
                               -> Iteratee IO a
                               -> IO (Iteratee IO a, IORef Bool)
unsafeBufferIterateeWithBuffer buf iteratee = do
    esc <- newIORef False
    return $! (start esc iteratee, esc)

  where
    start esc iter = IterateeG $! checkRef esc iter
    go bytesSoFar iter =
        {-# SCC "unsafeBufferIteratee/go" #-}
        IterateeG $! f bytesSoFar iter

    checkRef esc iter ch = do
        quit <- readIORef esc
        if quit
          then runIter iter ch
          else f 0 iter ch

    sendBuf n iter =
        {-# SCC "unsafeBufferIteratee/sendBuf" #-}
        withForeignPtr buf $ \ptr -> do
            s <- S.unsafePackCStringLen (ptr, n)
            runIter iter $ Chunk $ WrapBS s

    copy c@(EOF _) = c
    copy (Chunk (WrapBS s)) = Chunk $ WrapBS $ S.copy s

    f _ iter ch@(EOF (Just _)) = runIter iter ch

    f !n iter ch@(EOF Nothing) =
        if n == 0
          then runIter iter ch
          else do
              iter' <- liftM liftI $ sendBuf n iter
              runIter iter' ch

    f !n iter (Chunk (WrapBS s)) = do
        let m = S.length s
        if m+n > bUFSIZ
          then overflow n iter s m
          else copyAndCont n iter s m

    copyAndCont n iter s m =
      {-# SCC "unsafeBufferIteratee/copyAndCont" #-} do
        S.unsafeUseAsCStringLen s $ \(p,sz) ->
            withForeignPtr buf $ \bufp -> do
                let b' = plusPtr bufp n
                copyBytes b' p sz

        return $ Cont (go (n+m) iter) Nothing


    overflow n iter s m =
      {-# SCC "unsafeBufferIteratee/overflow" #-} do
        let rest = bUFSIZ - n
        let m2   = m - rest
        let (s1,s2) = S.splitAt rest s

        S.unsafeUseAsCStringLen s1 $ \(p,_) ->
          withForeignPtr buf $ \bufp -> do
            let b' = plusPtr bufp n
            copyBytes b' p rest

            iv <- sendBuf bUFSIZ iter
            case iv of
              Done x r        -> return $
                                 Done x (copy r `mappend` (Chunk $ WrapBS s2))
              Cont i (Just e) -> return $ Cont i (Just e)
              Cont i Nothing  -> do
                  -- check the size of the remainder; if it's bigger than the
                  -- buffer size then just send it
                  if m2 >= bUFSIZ
                    then do
                        iv' <- runIter i (Chunk $ WrapBS s2)
                        case iv' of
                          Done x r         -> return $ Done x (copy r)
                          Cont i' (Just e) -> return $ Cont i' (Just e)
                          Cont i' Nothing  -> return $ Cont (go 0 i') Nothing
                    else copyAndCont 0 i s2 m2


------------------------------------------------------------------------------
-- | Enumerates a strict bytestring.
enumBS :: (Monad m) => ByteString -> Enumerator m a
enumBS bs = enumPure1Chunk $ WrapBS bs
{-# INLINE enumBS #-}


------------------------------------------------------------------------------
-- | Enumerates a lazy bytestring.
enumLBS :: (Monad m) => L.ByteString -> Enumerator m a
enumLBS lbs = el chunks
  where
    el [] i     = liftM liftI $ runIter i (EOF Nothing)
    el (x:xs) i = do
        i' <- liftM liftI $ runIter i (Chunk $ WrapBS x)
        el xs i'

    chunks = L.toChunks lbs


------------------------------------------------------------------------------
-- | Converts a lazy bytestring to a wrapped bytestring.
toWrap :: L.ByteString -> WrappedByteString Word8
toWrap = WrapBS . S.concat . L.toChunks
{-# INLINE toWrap #-}


------------------------------------------------------------------------------
-- | Converts a wrapped bytestring to a lazy bytestring.
fromWrap :: WrappedByteString Word8 -> L.ByteString
fromWrap = L.fromChunks . (:[]) . unWrap
{-# INLINE fromWrap #-}


------------------------------------------------------------------------------
-- | Skip n elements of the stream, if there are that many
-- This is the Int64 version of the drop function in the iteratee library
drop' :: (SC.StreamChunk s el, Monad m)
       => Int64
       -> IterateeG s el m ()
drop' 0 = return ()
drop' n = IterateeG step
  where
  step (Chunk str)
    | strlen <= n  = return $ Cont (drop' (n - strlen)) Nothing
      where
        strlen = fromIntegral $ SC.length str
  step (Chunk str) = return $ Done () (Chunk (LL.drop (fromIntegral n) str))
  step stream      = return $ Done () stream


------------------------------------------------------------------------------
-- | Reads n elements from a stream and applies the given iteratee to
-- the stream of the read elements. Reads exactly n elements, and if
-- the stream is short propagates an error.
takeExactly :: (SC.StreamChunk s el, Monad m)
            => Int64
            -> EnumeratorN s el s el m a
takeExactly 0 iter = return iter
takeExactly n' iter =
    if n' < 0
      then takeExactly 0 iter
      else IterateeG (step n')
  where
  step n chk@(Chunk str)
    | SC.null str = return $ Cont (takeExactly n iter) Nothing
    | strlen < n  = liftM (flip Cont Nothing) inner
    | otherwise   = done (Chunk s1) (Chunk s2)
      where
        strlen = fromIntegral $ SC.length str
        inner  = liftM (check (n - strlen)) (runIter iter chk)
        (s1, s2) = SC.splitAt (fromIntegral n) str
  step _n (EOF (Just e))    = return $ Cont undefined (Just e)
  step _n (EOF Nothing)     = return $ Cont undefined (Just (Err "short write"))
  check n (Done x _)        = drop' n >> return (return x)
  check n (Cont x Nothing)  = takeExactly n x
  check n (Cont _ (Just e)) = drop' n >> throwErr e
  done s1 s2 = liftM (flip Done s2) (runIter iter s1 >>= checkIfDone return)


------------------------------------------------------------------------------
-- | Reads up to n elements from a stream and applies the given iteratee to the
-- stream of the read elements. If more than n elements are read, propagates an
-- error.
takeNoMoreThan :: (SC.StreamChunk s el, Monad m)
               => Int64
               -> EnumeratorN s el s el m a
takeNoMoreThan n' iter =
    if n' < 0
      then takeNoMoreThan 0 iter
      else IterateeG (step n')
  where
    step n chk@(Chunk str)
      | SC.null str = return $ Cont (takeNoMoreThan n iter) Nothing
      | strlen < n  = liftM (flip Cont Nothing) inner
      | otherwise   = done (Chunk s1) (Chunk s2)
          where
            strlen   = fromIntegral $ SC.length str
            inner    = liftM (check (n - strlen)) (runIter iter chk)
            (s1, s2) = SC.splitAt (fromIntegral n) str

    step _n (EOF (Just e))    = return $ Cont undefined (Just e)
    step _n chk@(EOF Nothing) = do
        v  <- runIter iter chk

        case v of
          (Done x s)        -> return $ Done (return x) s
          (Cont _ (Just e)) -> return $ Cont undefined (Just e)
          (Cont _ Nothing)  -> return $ Cont (throwErr $ Err "premature EOF") Nothing

    check _ v@(Done _ _)      = return $ liftI v
    check n (Cont x Nothing)  = takeNoMoreThan n x
    check _ (Cont _ (Just e)) = throwErr e

    done _ (EOF _) = error "impossible"
    done s1 s2@(Chunk s2') = do
        v <- runIter iter s1
        case v of
          (Done x s')       -> return $ Done (return x) (s' `mappend` s2)
          (Cont _ (Just e)) -> return $ Cont undefined (Just e)
          (Cont i Nothing)  ->
              if SC.null s2'
                then return $ Cont (takeNoMoreThan 0 i) Nothing
                else return $ Cont undefined (Just $ Err "too many bytes")


------------------------------------------------------------------------------
enumFile :: FilePath -> Iteratee IO a -> IO (Iteratee IO a)

#ifdef PORTABLE

enumFile fp iter = do
    h  <- liftIO $ openBinaryFile fp ReadMode
    i' <- enumHandle h iter
    return $ do
        x <- i'
        liftIO (hClose h)
        return x

#else

enumFile fp iter = do
    es <- (try $
           liftM WrapBS $
           unsafeMMapFile fp) :: IO (Either SomeException (WrappedByteString Word8))

    case es of
      (Left e)  -> return $ throwErr $ Err $ "IO error" ++ show e
      (Right s) -> liftM liftI $ runIter iter $ Chunk s

#endif

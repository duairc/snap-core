{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}

module Snap.Internal.Types where

------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Exception (throwIO, ErrorCall(..))
import           Control.Monad.CatchIO
import           Control.Monad.Cont
import           Control.Monad.Error
import           Control.Monad.List
import           Control.Monad.RWS hiding (pass)
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Monad.Writer hiding (pass)
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.CIByteString as CIB
import           Data.IORef
import qualified Data.Iteratee as Iter
import           Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LT
import           Prelude hiding (catch)

import           Data.Typeable

------------------------------------------------------------------------------
import           Snap.Iteratee hiding (Enumerator)
import           Snap.Internal.Http.Types


------------------------------------------------------------------------------
-- The Snap Monad
------------------------------------------------------------------------------

{-|

'Snap' is the 'Monad' that user web handlers run in. 'Snap' gives you:

1. stateful access to fetch or modify an HTTP 'Request'

2. stateful access to fetch or modify an HTTP 'Response'

3. failure \/ 'Alternative' \/ 'MonadPlus' semantics: a 'Snap' handler can
   choose not to handle a given request, using 'empty' or its synonym 'pass',
   and you can try alternative handlers with the '<|>' operator:

   > a :: Snap String
   > a = pass
   >
   > b :: Snap String
   > b = return "foo"
   >
   > c :: Snap String
   > c = a <|> b             -- try running a, if it fails then try b

4. convenience functions ('writeBS', 'writeLBS', 'writeText', 'writeLazyText',
   'addToOutput') for writing output to the 'Response':

   > a :: (forall a . Enumerator a) -> Snap ()
   > a someEnumerator = do
   >     writeBS "I'm a strict bytestring"
   >     writeLBS "I'm a lazy bytestring"
   >     addToOutput someEnumerator

5. early termination: if you call 'finishWith':

   > a :: Snap ()
   > a = do
   >   modifyResponse $ setResponseStatus 500 "Internal Server Error"
   >   writeBS "500 error"
   >   r <- getResponse
   >   finishWith r

   then any subsequent processing will be skipped and supplied 'Response' value
   will be returned from 'runSnap' as-is.

6. access to the 'IO' monad through a 'MonadIO' instance:

   > a :: Snap ()
   > a = liftIO fireTheMissiles
-}

------------------------------------------------------------------------------
-- | 'MonadSnap' is a type class, analogous to 'MonadIO' for 'IO', that makes
-- it easy to wrap 'Snap' inside monad transformers.
class (Monad m, MonadIO m, MonadCatchIO m, MonadPlus m, Functor m,
       Applicative m, Alternative m) => MonadSnap m where
    liftSnap :: Snap a -> m a

------------------------------------------------------------------------------
newtype Snap a = Snap {
      unSnap :: StateT SnapState (Iteratee IO) (Maybe (Either Response a))
}


------------------------------------------------------------------------------
data SnapState = SnapState
    { _snapRequest  :: Request
    , _snapResponse :: Response
    , _snapLogError :: ByteString -> IO () }


------------------------------------------------------------------------------
instance Monad Snap where
    (Snap m) >>= f =
        Snap $ do
            eth <- m
            maybe (return Nothing)
                  (either (return . Just . Left)
                          (unSnap . f))
                  eth

    return = Snap . return . Just . Right
    fail   = const $ Snap $ return Nothing


------------------------------------------------------------------------------
instance MonadIO Snap where
    liftIO m = Snap $ liftM (Just . Right) $ liftIO m


------------------------------------------------------------------------------
instance MonadCatchIO Snap where
    catch (Snap m) handler = Snap $ do
        x <- try m
        case x of
          (Left e)  -> let (Snap z) = handler e in z
          (Right y) -> return y

    block (Snap m) = Snap $ block m
    unblock (Snap m) = Snap $ unblock m


------------------------------------------------------------------------------
instance MonadPlus Snap where
    mzero = Snap $ return Nothing

    a `mplus` b =
        Snap $ do
            mb <- unSnap a
            if isJust mb then return mb else unSnap b


------------------------------------------------------------------------------
instance Functor Snap where
    fmap = liftM


------------------------------------------------------------------------------
instance Applicative Snap where
    pure  = return
    (<*>) = ap


------------------------------------------------------------------------------
instance Alternative Snap where
    empty = mzero
    (<|>) = mplus


------------------------------------------------------------------------------
instance MonadSnap Snap where
    liftSnap = id


------------------------------------------------------------------------------
instance MonadSnap m => MonadPlus (ContT c m) where
    mzero = lift mzero
    m `mplus` n = ContT $ \ f -> runContT m f `mplus` runContT n f


------------------------------------------------------------------------------
instance MonadSnap m => Alternative (ContT c m) where
    empty = mzero
    (<|>) = mplus


------------------------------------------------------------------------------
instance MonadSnap m => MonadSnap (ContT c m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
instance (MonadSnap m, Error e) => MonadSnap (ErrorT e m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
instance MonadSnap m => MonadSnap (ListT m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
instance (MonadSnap m, Monoid w) => MonadSnap (RWST r w s m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
instance MonadSnap m => MonadSnap (ReaderT r m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
instance MonadSnap m => MonadSnap (StateT s m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
instance (MonadSnap m, Monoid w) => MonadSnap (WriterT w m) where
    liftSnap = lift . liftSnap


------------------------------------------------------------------------------
-- | The Typeable instance is here so Snap can be dynamically executed with
-- Hint.
snapTyCon :: TyCon
snapTyCon = mkTyCon "Snap.Types.Snap"
{-# NOINLINE snapTyCon #-}

instance Typeable1 Snap where
    typeOf1 _ = mkTyConApp snapTyCon []


------------------------------------------------------------------------------
liftIter :: MonadSnap m => Iteratee IO a -> m a
liftIter i = liftSnap $ Snap (lift i >>= return . Just . Right)


------------------------------------------------------------------------------
-- | Sends the request body through an iteratee (data consumer) and
-- returns the result.
runRequestBody :: MonadSnap m => Iteratee IO a -> m a
runRequestBody iter = do
    req  <- getRequest
    senum <- liftIO $ readIORef $ rqBody req
    let (SomeEnumerator enum) = senum

    -- make sure the iteratee consumes all of the output
    let iter' = iter >>= (\a -> Iter.skipToEof >> return a)

    -- run the iteratee
    result <- liftIter $ Iter.joinIM $ enum iter'

    -- stuff a new dummy enumerator into the request, so you can only try to
    -- read the request body from the socket once
    liftIO $ writeIORef (rqBody req)
                        (SomeEnumerator $ return . Iter.joinI . Iter.take 0 )

    return result


------------------------------------------------------------------------------
-- | Returns the request body as a bytestring.
getRequestBody :: MonadSnap m => m L.ByteString
getRequestBody = liftM fromWrap $ runRequestBody stream2stream
{-# INLINE getRequestBody #-}


------------------------------------------------------------------------------
-- | Detaches the request body's 'Enumerator' from the 'Request' and
-- returns it. You would want to use this if you needed to send the
-- HTTP request body (transformed or otherwise) through to the output
-- in O(1) space. (Examples: transcoding, \"echo\", etc)
--
-- Normally Snap is careful to ensure that the request body is fully
-- consumed after your web handler runs; this function is marked
-- \"unsafe\" because it breaks this guarantee and leaves the
-- responsibility up to you. If you don't fully consume the
-- 'Enumerator' you get here, the next HTTP request in the pipeline
-- (if any) will misparse. Be careful with exception handlers.
unsafeDetachRequestBody :: Snap (Enumerator a)
unsafeDetachRequestBody = do
    req <- getRequest
    let ioref = rqBody req
    senum <- liftIO $ readIORef ioref
    let (SomeEnumerator enum) = senum
    liftIO $ writeIORef ioref
               (SomeEnumerator $ return . Iter.joinI . Iter.take 0)
    return enum


------------------------------------------------------------------------------
-- | Short-circuits a 'Snap' monad action early, storing the given
-- 'Response' value in its state.
finishWith :: MonadSnap m => Response -> m ()
finishWith = liftSnap . Snap . return . Just . Left
{-# INLINE finishWith #-}


------------------------------------------------------------------------------
-- | Fails out of a 'Snap' monad action.  This is used to indicate
-- that you choose not to handle the given request within the given
-- handler.
pass :: MonadSnap m => m a
pass = empty


------------------------------------------------------------------------------
-- | Runs a 'Snap' monad action only if the request's HTTP method matches
-- the given method.
method :: MonadSnap m => Method -> m a -> m a
method m action = do
    req <- getRequest
    unless (rqMethod req == m) pass
    action
{-# INLINE method #-}


------------------------------------------------------------------------------
-- Appends n bytes of the path info to the context path with a
-- trailing slash.
updateContextPath :: Int -> Request -> Request
updateContextPath n req | n > 0     = req { rqContextPath = ctx
                                          , rqPathInfo    = pinfo }
                        | otherwise = req
  where
    ctx'  = S.take n (rqPathInfo req)
    ctx   = S.concat [rqContextPath req, ctx', "/"]
    pinfo = S.drop (n+1) (rqPathInfo req)


------------------------------------------------------------------------------
-- Runs a 'Snap' monad action only if the 'rqPathInfo' matches the given
-- predicate.
pathWith :: MonadSnap m
         => (ByteString -> ByteString -> Bool)
         -> ByteString
         -> m a
         -> m a
pathWith c p action = do
    req <- getRequest
    unless (c p (rqPathInfo req)) pass
    localRequest (updateContextPath $ S.length p) action


------------------------------------------------------------------------------
-- | Runs a 'Snap' monad action only when the 'rqPathInfo' of the request
-- starts with the given path. For example,
--
-- > dir "foo" handler
--
-- Will fail if 'rqPathInfo' is not \"@\/foo@\" or \"@\/foo\/...@\", and will
-- add @\"foo\/\"@ to the handler's local 'rqContextPath'.
dir :: MonadSnap m
    => ByteString  -- ^ path component to match
    -> m a         -- ^ handler to run
    -> m a
dir = pathWith f
  where
    f dr pinfo = dr == x
      where
        (x,_) = S.break (=='/') pinfo
{-# INLINE dir #-}


------------------------------------------------------------------------------
-- | Runs a 'Snap' monad action only for requests where 'rqPathInfo' is exactly
-- equal to the given string. If the path matches, locally sets 'rqContextPath'
-- to the old value of 'rqPathInfo', sets 'rqPathInfo'=\"\", and runs the given
-- handler.
path :: MonadSnap m
     => ByteString  -- ^ path to match against
     -> m a         -- ^ handler to run
     -> m a
path = pathWith (==)
{-# INLINE path #-}


------------------------------------------------------------------------------
-- | Runs a 'Snap' monad action only when 'rqPathInfo' is empty.
ifTop :: MonadSnap m => m a -> m a
ifTop = path ""
{-# INLINE ifTop #-}


------------------------------------------------------------------------------
-- | Local Snap version of 'get'.
sget :: Snap SnapState
sget = Snap $ liftM (Just . Right) get
{-# INLINE sget #-}


------------------------------------------------------------------------------
-- | Local Snap monad version of 'modify'.
smodify :: (SnapState -> SnapState) -> Snap ()
smodify f = Snap $ modify f >> return (Just $ Right ())
{-# INLINE smodify #-}


------------------------------------------------------------------------------
-- | Grabs the 'Request' object out of the 'Snap' monad.
getRequest :: MonadSnap m => m Request
getRequest = liftSnap $ liftM _snapRequest sget
{-# INLINE getRequest #-}


------------------------------------------------------------------------------
-- | Grabs the 'Response' object out of the 'Snap' monad.
getResponse :: MonadSnap m => m Response
getResponse = liftSnap $ liftM _snapResponse sget
{-# INLINE getResponse #-}


------------------------------------------------------------------------------
-- | Puts a new 'Response' object into the 'Snap' monad.
putResponse :: MonadSnap m => Response -> m ()
putResponse r = liftSnap $ smodify $ \ss -> ss { _snapResponse = r }
{-# INLINE putResponse #-}


------------------------------------------------------------------------------
-- | Puts a new 'Request' object into the 'Snap' monad.
putRequest :: MonadSnap m => Request -> m ()
putRequest r = liftSnap $ smodify $ \ss -> ss { _snapRequest = r }
{-# INLINE putRequest #-}


------------------------------------------------------------------------------
-- | Modifies the 'Request' object stored in a 'Snap' monad.
modifyRequest :: MonadSnap m => (Request -> Request) -> m ()
modifyRequest f = liftSnap $
    smodify $ \ss -> ss { _snapRequest = f $ _snapRequest ss }
{-# INLINE modifyRequest #-}


------------------------------------------------------------------------------
-- | Modifes the 'Response' object stored in a 'Snap' monad.
modifyResponse :: MonadSnap m => (Response -> Response) -> m ()
modifyResponse f = liftSnap $ 
     smodify $ \ss -> ss { _snapResponse = f $ _snapResponse ss }
{-# INLINE modifyResponse #-}


------------------------------------------------------------------------------
-- | Log an error message in the 'Snap' monad
logError :: MonadSnap m => ByteString -> m ()
logError s = liftSnap $ Snap $ gets _snapLogError >>= (\l -> liftIO $ l s)
                                       >>  return (Just $ Right ())
{-# INLINE logError #-}


------------------------------------------------------------------------------
-- | Adds the output from the given enumerator to the 'Response'
-- stored in the 'Snap' monad state.
addToOutput :: MonadSnap m
            => (forall a . Enumerator a)   -- ^ output to add
            -> m ()
addToOutput enum = modifyResponse $ modifyResponseBody (>. enum)


------------------------------------------------------------------------------
-- | Adds the given strict 'ByteString' to the body of the 'Response' stored in
-- the 'Snap' monad state.
writeBS :: MonadSnap m => ByteString -> m ()
writeBS s = addToOutput $ enumBS s


------------------------------------------------------------------------------
-- | Adds the given lazy 'L.ByteString' to the body of the 'Response' stored in
-- the 'Snap' monad state.
writeLBS :: MonadSnap m => L.ByteString -> m ()
writeLBS s = addToOutput $ enumLBS s


------------------------------------------------------------------------------
-- | Adds the given strict 'T.Text' to the body of the 'Response' stored in the
-- 'Snap' monad state.
writeText :: MonadSnap m => T.Text -> m ()
writeText s = writeBS $ T.encodeUtf8 s


------------------------------------------------------------------------------
-- | Adds the given lazy 'LT.Text' to the body of the 'Response' stored in the
-- 'Snap' monad state.
writeLazyText :: MonadSnap m => LT.Text -> m ()
writeLazyText s = writeLBS $ LT.encodeUtf8 s


------------------------------------------------------------------------------
-- | Sets the output to be the contents of the specified file.
--
-- Calling 'sendFile' will overwrite any output queued to be sent in the
-- 'Response'. If the response body is not modified after the call to
-- 'sendFile', Snap will use the efficient @sendfile()@ system call on
-- platforms that support it.
--
-- If the response body is modified (using 'modifyResponseBody'), the file will
-- be read using @mmap()@.
sendFile :: MonadSnap m => FilePath -> m ()
sendFile f = modifyResponse $ \r -> r { rspBody = SendFile f }


------------------------------------------------------------------------------
-- | Runs a 'Snap' action with a locally-modified 'Request' state
-- object. The 'Request' object in the Snap monad state after the call
-- to localRequest will be unchanged.
localRequest :: MonadSnap m => (Request -> Request) -> m a -> m a
localRequest f m = do
    req <- getRequest

    runAct req <|> (putRequest req >> pass)

  where
    runAct req = do
        modifyRequest f
        result <- m
        putRequest req
        return result
{-# INLINE localRequest #-}


------------------------------------------------------------------------------
-- | Fetches the 'Request' from state and hands it to the given action.
withRequest :: MonadSnap m => (Request -> m a) -> m a
withRequest = (getRequest >>=)
{-# INLINE withRequest #-}


------------------------------------------------------------------------------
-- | Fetches the 'Response' from state and hands it to the given action.
withResponse :: MonadSnap m => (Response -> m a) -> m a
withResponse = (getResponse >>=)
{-# INLINE withResponse #-}


------------------------------------------------------------------------------
-- | Modifies the 'Request' in the state to set the 'rqRemoteAddr'
-- field to the value in the X-Forwarded-For header. If the header is
-- not present, this action has no effect.
--
-- This action should be used only when working behind a reverse http
-- proxy that sets the X-Forwarded-For header. This is the only way to
-- ensure the value in the X-Forwarded-For header can be trusted.
--
-- This is provided as a filter so actions that require the remote
-- address can get it in a uniform manner. It has specifically limited
-- functionality to ensure that its transformation can be trusted,
-- when used correctly.
ipHeaderFilter :: MonadSnap m => m ()
ipHeaderFilter = ipHeaderFilter' "x-forwarded-for"


------------------------------------------------------------------------------
-- | Modifies the 'Request' in the state to set the 'rqRemoteAddr'
-- field to the value from the header specified.  If the header
-- specified is not present, this action has no effect.
--
-- This action should be used only when working behind a reverse http
-- proxy that sets the header being looked at. This is the only way to
-- ensure the value in the header can be trusted.
--
-- This is provided as a filter so actions that require the remote
-- address can get it in a uniform manner. It has specifically limited
-- functionality to ensure that its transformation can be trusted,
-- when used correctly.
ipHeaderFilter' :: MonadSnap m => CIB.CIByteString -> m ()
ipHeaderFilter' header = do
    headerContents <- getHeader header <$> getRequest

    let whitespace = " \t\r\n"
        ipChrs = ".0123456789"
        trim f s = f (`elem` s)

        clean = trim S.takeWhile ipChrs . trim S.dropWhile whitespace
        setIP ip = modifyRequest $ \rq -> rq { rqRemoteAddr = clean ip }
    maybe (return ()) setIP headerContents


------------------------------------------------------------------------------
-- | This exception is thrown if the handler you supply to 'runSnap' fails.
data NoHandlerException = NoHandlerException
   deriving (Eq, Typeable)


------------------------------------------------------------------------------
instance Show NoHandlerException where
    show NoHandlerException = "No handler for request"


------------------------------------------------------------------------------
instance Exception NoHandlerException


------------------------------------------------------------------------------
-- | Runs a 'Snap' monad action in the 'Iteratee IO' monad.
runSnap :: Snap a
        -> (ByteString -> IO ())
        -> Request
        -> Iteratee IO (Request,Response)
runSnap (Snap m) logerr req = do
    (r, ss') <- runStateT m ss

    e <- maybe (return $ Left fourohfour)
               return
               r

    -- is this a case of early termination?
    let resp = case e of
                 Left x  -> x
                 Right _ -> _snapResponse ss'

    return (_snapRequest ss', resp)

  where
    fourohfour = setContentLength 3 $
                 setResponseStatus 404 "Not Found" $
                 modifyResponseBody (>. enumBS "404") $
                 emptyResponse

    dresp = emptyResponse { rspHttpVersion = rqVersion req }

    ss = SnapState req dresp logerr
{-# INLINE runSnap #-}


------------------------------------------------------------------------------
evalSnap :: Snap a
         -> (ByteString -> IO ())
         -> Request
         -> Iteratee IO a
evalSnap (Snap m) logerr req = do
    (r, _) <- runStateT m ss

    e <- maybe (liftIO $ throwIO NoHandlerException)
               return
               r

    -- is this a case of early termination?
    case e of
      Left _  -> liftIO $ throwIO $ ErrorCall "no value"
      Right x -> return x
  where
    dresp = emptyResponse { rspHttpVersion = rqVersion req }
    ss = SnapState req dresp logerr
{-# INLINE evalSnap #-}



------------------------------------------------------------------------------
-- | See 'rqParam'. Looks up a value for the given named parameter in the
-- 'Request'. If more than one value was entered for the given parameter name,
-- 'getParam' gloms the values together with:
--
-- @    'S.intercalate' \" \"@
--
getParam :: MonadSnap m
         => ByteString          -- ^ parameter name to look up
         -> m (Maybe ByteString)
getParam k = do
    rq <- getRequest
    return $ liftM (S.intercalate " ") $ rqParam k rq



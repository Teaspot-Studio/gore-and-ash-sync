{-|
Module      : Game.GoreAndAsh.Sync.Module
Description : Implementation of synchronization module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
module Game.GoreAndAsh.Sync.Module(
    SyncT
  , globalSyncName
  ) where

import Control.Lens ((&), (.~), (^.))
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Trans.Resource
import Data.IORef
import Data.Map.Strict (Map)
import Data.Proxy
import Data.Word
import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.API
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time

import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M

-- | Name of global scope for synchronisation that is created
-- by default.
--
-- You should never redefine this scope!
globalSyncName :: SyncName
globalSyncName = ""

-- | Internal state of core module
data SyncEnv t b = SyncEnv {
  -- | Module options
  syncEnvOptions         :: SyncOptions ()
  -- | Storage of name map and next free id
, syncEnvNames           :: ExternalRef t (NameMap, SyncId)
  -- | Current sync object
, syncEnvName            :: SyncName
  -- | Store current values of send counter for each peer
, syncEnvSendCounters    :: IORef (Map (Peer b) Word16)
  -- | Store current values of receive counter for each peer
, syncEnvReceiveCounters :: IORef (Map (Peer b) Word16)
}

-- | Creation of intial sync state
newSyncEnv :: (MonadAppHost t m, HasNetworkBackend b) => SyncOptions s -> m (SyncEnv t b)
newSyncEnv opts = do
  namesRef <- newExternalRef (H.singleton globalSyncName 0, 1)
  sendCounters <- liftIO $ newIORef mempty
  receiveCounters <- liftIO $ newIORef mempty
  return SyncEnv {
      syncEnvOptions = opts & syncOptionsNext .~ ()
    , syncEnvNames = namesRef
    , syncEnvName = globalSyncName
    , syncEnvSendCounters = sendCounters
    , syncEnvReceiveCounters = receiveCounters
    }

-- | Monad transformer of synchronization core module.
--
-- [@t@] - FRP engine implementation, can be ignored almost everywhere.
--
-- [@b@] - Network transport backend (see 'NetworkT')
--
-- [@m@] - Next monad in modules monad stack;
--
-- [@a@] - Type of result value;
--
-- How to embed module:
--
-- @
-- newtype AppMonad t a = AppMonad (SyncT t (TimerT t (NetworkT t (LoggingT t (GameMonad t))))) a)
--   deriving (Functor, Applicative, Monad, MonadFix, MonadIO, LoggingMonad, NetworkMonad, TimerMonad, SyncMonad)
-- @
newtype SyncT t b m a = SyncT { runSyncT :: ReaderT (SyncEnv t b) m a }
  deriving (Functor, Applicative, Monad, MonadReader (SyncEnv t b), MonadFix
    , MonadIO, MonadThrow, MonadCatch, MonadMask, MonadSample t, MonadHold t)

instance MonadTrans (SyncT t b) where
  lift = SyncT . lift

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (SyncT t b m) where
  newEventWithTrigger = lift . newEventWithTrigger
  newFanEventWithTrigger initializer = lift $ newFanEventWithTrigger initializer

instance MonadSubscribeEvent t m => MonadSubscribeEvent t (SyncT t b m) where
  subscribeEvent = lift . subscribeEvent

instance MonadAppHost t m => MonadAppHost t (SyncT t b m) where
  getFireAsync = lift getFireAsync
  getRunAppHost = do
    runner <- SyncT getRunAppHost
    return $ \m -> runner $ runSyncT m
  performPostBuild_ = lift . performPostBuild_
  liftHostFrame = lift . liftHostFrame

instance MonadTransControl (SyncT t b) where
  type StT (SyncT t b) a = StT (ReaderT (SyncEnv t b)) a
  liftWith = defaultLiftWith SyncT runSyncT
  restoreT = defaultRestoreT SyncT

instance MonadBase b m => MonadBase b (SyncT t backend m) where
  liftBase = SyncT . liftBase

instance (MonadBaseControl b m) => MonadBaseControl b (SyncT t backend m) where
  type StM (SyncT t backend m) a = ComposeSt (SyncT t backend) m a
  liftBaseWith     = defaultLiftBaseWith
  restoreM         = defaultRestoreM

instance MonadResource m => MonadResource (SyncT t b m) where
  liftResourceT = SyncT . liftResourceT

instance (MonadIO (HostFrame t), NetworkMonad t b m, TimerMonad t m, GameModule t m, MonadMask m) => GameModule t (SyncT t b m) where
  type ModuleOptions t (SyncT t b m) = SyncOptions (ModuleOptions t m)

  runModule opts m = do
    s <- newSyncEnv opts
    a <- runModule (opts ^. syncOptionsNext) (runReaderT (runSyncT m') s)
    return a
    where
      m' = do
        a <- m
        syncService
        return a

  withModule t _ = withModule t (Proxy :: Proxy m)

instance (MonadAppHost t m, MonadMask m, TimerMonad t m, LoggingMonad t m, HasNetworkBackend b) => SyncMonad t b (SyncT t b m) where
  syncOptions = asks syncEnvOptions
  {-# INLINE syncOptions #-}
  syncKnownNames = do
    dynVar <- externalRefDynamic =<< asks syncEnvNames
    return $ fst <$> dynVar
  {-# INLINE syncKnownNames #-}
  syncCurrentName = asks syncEnvName
  {-# INLINE syncCurrentName #-}
  syncScopeName name (SyncT ma) = SyncT $ withReaderT setName ma
    where
      setName e = e { syncEnvName = name }
  {-# INLINE syncScopeName #-}
  syncUnsafeRegId name = do
    namesRef <- asks syncEnvNames
    modifyExternalRef namesRef $ \(names, i) -> let
      names' = H.insert name i names
      i' = i + 1
      state' = names' `seq` i' `seq` (names', i')
      in (state', i)
  {-# INLINE syncUnsafeRegId #-}
  syncUnsafeAddId name i = do
    namesRef <- asks syncEnvNames
    modifyExternalRef namesRef $ \(names, localI) -> let
      names' = H.insert name i names
      i' = i `max` localI
      state' = names' `seq` i' `seq` (names', i')
      in (state', ())
  {-# INLINE syncUnsafeAddId #-}
  syncUnsafeDelId name = do
    namesRef <- asks syncEnvNames
    modifyExternalRef namesRef $ \(names, localI) -> let
      names' = H.delete name names
      state = names' `seq` (names', localI)
      in (state, ())
  {-# INLINE syncUnsafeDelId #-}

  syncIncSendCounter p = do
    ref <- asks syncEnvSendCounters
    liftIO $ atomicModifyIORef' ref $ \m -> case M.lookup p m of
      Nothing -> (M.insert p 1 m, 0)
      Just c  -> if c == maxBound
        then (M.insert p 1 m, 0)
        else (M.insert p (c+1) m, c)
  {-# INLINE syncIncSendCounter #-}

  syncCheckReceiveCounter p c = do
    ref <- asks syncEnvReceiveCounters
    liftIO $ atomicModifyIORef' ref $ \m -> case M.lookup p m of
      Nothing -> (M.insert p c m, True)
      Just c' -> let
        maxc = max c c'
        next = if maxc == maxBound then 0 else maxc
        in if c >= c' then (M.insert p next m, True) else (m, False)
  {-# INLINE syncCheckReceiveCounter #-}

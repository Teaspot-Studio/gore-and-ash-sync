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
import Data.Monoid
import Data.Proxy
import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.API
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time

import qualified Data.HashMap.Strict as H

-- | Name of global scope for synchronisation that is created
-- by default.
--
-- You should never redefine this scope!
globalSyncName :: SyncName
globalSyncName = ""

-- | Internal state of core module
data SyncEnv t = SyncEnv {
  -- | Module options
  syncEnvOptions :: SyncOptions ()
  -- | Storage of name map and next free id
, syncEnvNames :: ExternalRef t (NameMap, SyncId)
  -- | Current sync object
, syncEnvName :: IORef SyncName
}

-- | Creation of intial sync state
newSyncEnv :: MonadAppHost t m => SyncOptions s -> m (SyncEnv t)
newSyncEnv opts = do
  namesRef <- newExternalRef (H.singleton globalSyncName 0, 1)
  nameRef <- liftIO $ newIORef globalSyncName
  return SyncEnv {
    syncEnvOptions = opts & syncOptionsNext .~ ()
  , syncEnvNames = namesRef
  , syncEnvName = nameRef
  }

-- | Monad transformer of synchronization core module.
--
-- [@t@] - FRP engine implementation, can be ignored almost everywhere.
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
newtype SyncT t m a = SyncT { runSyncT :: ReaderT (SyncEnv t) m a }
  deriving (Functor, Applicative, Monad, MonadReader (SyncEnv t), MonadFix
    , MonadIO, MonadThrow, MonadCatch, MonadMask, MonadSample t, MonadHold t)

instance MonadTrans (SyncT t) where
  lift = SyncT . lift

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (SyncT t m) where
  newEventWithTrigger = lift . newEventWithTrigger
  newFanEventWithTrigger initializer = lift $ newFanEventWithTrigger initializer

instance MonadSubscribeEvent t m => MonadSubscribeEvent t (SyncT t m) where
  subscribeEvent = lift . subscribeEvent

instance MonadAppHost t m => MonadAppHost t (SyncT t m) where
  getFireAsync = lift getFireAsync
  getRunAppHost = do
    runner <- SyncT getRunAppHost
    return $ \m -> runner $ runSyncT m
  performPostBuild_ = lift . performPostBuild_
  liftHostFrame = lift . liftHostFrame

instance MonadTransControl (SyncT t) where
  type StT (SyncT t) a = StT (ReaderT (SyncEnv t)) a
  liftWith = defaultLiftWith SyncT runSyncT
  restoreT = defaultRestoreT SyncT

instance MonadBase b m => MonadBase b (SyncT t m) where
  liftBase = SyncT . liftBase

instance (MonadBaseControl b m) => MonadBaseControl b (SyncT t m) where
  type StM (SyncT t m) a = ComposeSt (SyncT t) m a
  liftBaseWith     = defaultLiftBaseWith
  restoreM         = defaultRestoreM

instance MonadResource m => MonadResource (SyncT t m) where
  liftResourceT = SyncT . liftResourceT

instance (MonadIO (HostFrame t), NetworkMonad t m, LoggingMonad t m, TimerMonad t m, GameModule t m, MonadMask m) => GameModule t (SyncT t m) where
  type ModuleOptions t (SyncT t m) = SyncOptions (ModuleOptions t m)

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

instance (MonadAppHost t m, MonadMask m, TimerMonad t m, LoggingMonad t m) => SyncMonad t (SyncT t m) where
  syncOptions = asks syncEnvOptions
  {-# INLINE syncOptions #-}
  syncKnownNames = do
    dynVar <- externalRefDynamic =<< asks syncEnvNames
    return $ fst <$> dynVar
  {-# INLINE syncKnownNames #-}
  syncCurrentName = do
    ref <- asks syncEnvName
    liftIO $ readIORef ref
  {-# INLINE syncCurrentName #-}
  syncUnsafeSetName name = do
    ref <- asks syncEnvName
    liftIO . atomicModifyIORef' ref $ \oldName -> (oldName <> name, ())
  {-# INLINE syncUnsafeSetName #-}
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
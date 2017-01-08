{-|
Module      : Game.GoreAndAsh.Sync.API
Description : API of synchronization module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
{-# LANGUAGE LambdaCase #-}
module Game.GoreAndAsh.Sync.API(
  -- * API
    SyncName
  , SyncItemId
  , SyncMonad(..)
  , ClientSynced(..)
  , serverRejected
  , conditional
  , syncWithNameWith
  , syncWithName
  -- ** Server side
  , syncToClientManual
  , syncToClient
  , syncToClientsManual
  , syncToClients
  , syncToAllClients
  , sendToClient
  , sendToClients
  , sendToAllClients
  , sendToClientMany
  , sendToClientsMany
  , sendToAllClientsMany
  , syncFromClient
  , syncFromClients
  , syncFromAllClients
  , receiveFromClient
  , receiveFromClients
  , receiveFromAllClients
  -- ** Client side
  , syncToServer
  , syncFromServerWith
  , syncFromServer
  , sendToServer
  , sendToServerMany
  , receiveFromServer
  -- ** Prediction
  , predict
  , predictMaybe
  , predictM
  , predictMaybeM
  -- * Internal API
  , NameMap
  , syncService
  , makeSyncName
  , resolveSyncName
  ) where

import Control.Lens ((^.))
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Trans
import Control.Monad.Trans.Control
import Data.Bifunctor
import Data.Map.Strict (Map)
import Data.Monoid
import Data.Store
import Game.GoreAndAsh.Core
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time
import GHC.Generics

import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M

-- TODO, what is left to finish the module:
-- 1. Remote collections.

-- | Bijection between name and id of synchronized object
type NameMap = H.HashMap SyncName SyncId

class (MonadAppHost t m, TimerMonad t m, LoggingMonad t m, MonadMask m)
  => SyncMonad t m | m -> t where
    -- | Get settings of the module
    syncOptions :: m (SyncOptions ())
    -- | Get map of known names on the node
    syncKnownNames :: m (Dynamic t NameMap)
    -- | Return current scope sync object of synchronization object
    syncCurrentName :: m SyncName

    -- | Set current scope name without resolving or generation id for the name.
    --
    -- It is low-level operation, you probably want to see 'syncWithName'.
    syncScopeName :: SyncName -- ^ Name to use for scope
      -> m a -- ^ Scope that will see the name in 'syncCurrentName' call
      -> m a

    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by server to generate id for name.
    syncUnsafeRegId :: SyncName -> m SyncId
    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by client to register id requested from server.
    syncUnsafeAddId :: SyncName -> SyncId -> m ()

-- | Execute nested action with given scope name and restore it after
--
-- Instead of 'syncWithName' uses dynamic for initial values, that is important
-- for aligning states of initial value and values of generated dynamic in future
-- after scope is resolved.
syncWithNameWith :: (SyncMonad t m, NetworkClient t m)
  => SyncName     -- ^ Name to use for scope
  -> Dynamic t a  -- ^ Initial value (before the name is resolved)
  -> m a          -- ^ Scope
  -> m (Dynamic t a) -- ^ Result of scope execution
syncWithNameWith name initDyn m =  do
  let m' = syncScopeName name m
  opts <- syncOptions
  let role = opts ^. syncOptionsRole
  case role of
    SyncSlave -> do
      fmap join $ whenConnected (return initDyn) $ \peer -> do
        resolveSyncName peer name (sample . current $ initDyn) (const m')
    SyncMaster -> makeSyncName name >> fmap pure m'

-- | Execute nested action with given scope name and restore it after
syncWithName :: (SyncMonad t m, NetworkClient t m)
  => SyncName -- ^ Name to use for scope
  -> a   -- ^ Initial value (before the name is resolved)
  -> m a -- ^ Scope
  -> m (Dynamic t a) -- ^ Result of scope execution
syncWithName name a0 = syncWithNameWith name (pure a0)

instance {-# OVERLAPPABLE #-} (MonadAppHost t (mt m), MonadMask (mt m), MonadTransControl mt, SyncMonad t m, TimerMonad t m, LoggingMonad t m)
  => SyncMonad t (mt m) where
    syncOptions = lift syncOptions
    {-# INLINE syncOptions #-}
    syncKnownNames = lift syncKnownNames
    {-# INLINE syncKnownNames #-}
    syncCurrentName = lift syncCurrentName
    {-# INLINE syncCurrentName #-}
    syncScopeName name ma = do
      res <- liftWith $ \run -> syncScopeName name $ run ma
      restoreT $ pure res
    {-# INLINE syncScopeName #-}
    syncUnsafeRegId = lift . syncUnsafeRegId
    {-# INLINE syncUnsafeRegId #-}
    syncUnsafeAddId a b = lift $ syncUnsafeAddId a b
    {-# INLINE syncUnsafeAddId #-}

-- | Start streaming given dynamic value to specific client.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
--
-- You can group 'syncToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
syncToClientManual :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Manual send event. Send contents of dynamics to client only when the
  -- event fires.
  -> Event t ()
  -- | Client that is target of synchronisation.
  -> Peer
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
syncToClientManual itemId mt da manualE peer = do
  buildE <- getPostBuild
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- listen for requests
  reqE <- syncRequestMessage peer i itemId
  let respE = tagPromptlyDyn da reqE
  logVerboseE $ ffor respE $ const $ "Sync: Got request for initial value of " <> showl itemId
  -- send updates
  let initialE = tagPromptlyDyn da buildE
      manualE' = tagPromptlyDyn da manualE
      updatedE = leftmost [manualE', respE, initialE]
      msgE = fmap (encodeSyncMessage mt i itemId) updatedE
  peerChanSend peer chan msgE

-- | Start streaming given dynamic value to specific client.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
--
-- You can group 'syncToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
syncToClient :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Client that is target of synchronisation.
  -> Peer
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
syncToClient itemId mt da peer = syncToClientManual itemId mt da (const () <$> updated da) peer

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClientsManual :: (SyncMonad t m, NetworkServer t m, Store a, Foldable f)
  -- | Set of clients that should be informed about chages of the value
  => Dynamic t (f Peer)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Manual send event. Send contents of dynamics to client only when the
  -- event fires.
  -> Event t ()
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
syncToClientsManual peers itemId mt da manualE = dynAppHost $ mapM_ (syncToClientManual itemId mt da manualE) <$> peers

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClients :: (SyncMonad t m, NetworkServer t m, Store a, Foldable f)
  -- | Set of clients that should be informed about chages of the value
  => Dynamic t (f Peer)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
syncToClients peers itemId mt da = dynAppHost $ mapM_ (syncToClient itemId mt da) <$> peers

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToAllClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
syncToAllClients itemId mt da = do
  peers <- networkPeers
  syncToClients peers itemId mt da

-- | Send given high-level message to given peer.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClient :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Each time the event fires the content in sended to remote peer.
  -> Event t a
  -- | Client that is target of synchronisation.
  -> Peer
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
sendToClient itemId mt ea peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- send updates
  let msgE = fmap (encodeSyncMessage mt i itemId) ea
  peerChanSend peer chan msgE

-- | Send given high-level message to given peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClients' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClients :: (SyncMonad t m, NetworkServer t m, Store a, Foldable f)
  -- | Collection of peers to sync the message to
  => Dynamic t (f Peer)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Each time the event fires the content in sended to remote peer.
  -> Event t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
sendToClients peers itemId mt ea = dynAppHost $ mapM_ (sendToClient itemId mt ea) <$> peers

-- | Send given high-level message to all connected peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
sendToAllClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Each time the event fires the content in sended to remote peer.
  -> Event t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
sendToAllClients itemId mt ea = do
  peers <- networkPeers
  sendToClients peers  itemId mt ea

-- | Send given high-level message to given peer.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClientMany :: (SyncMonad t m, NetworkServer t m, Store a, Foldable f, Functor f)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Each time the event fires the content in sended to remote peer.
  -> Event t (f a)
  -- | Client that is target of synchronisation.
  -> Peer
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
sendToClientMany itemId mt eas peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- send updates
  let msgsE = fmap (encodeSyncMessage mt i itemId) <$> eas
  peerChanSendMany peer chan msgsE


-- | Send given high-level message to given peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClients' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClientsMany :: (SyncMonad t m, NetworkServer t m, Store a, Foldable f1, Foldable f2, Functor f2)
  -- | Collection of peers to sync the message to
  => Dynamic t (f1 Peer)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Each time the event fires the content in sended to remote peer.
  -> Event t (f2 a)
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
sendToClientsMany peers itemId mt eas = dynAppHost $ mapM_ (sendToClientMany itemId mt eas) <$> peers

-- | Send given high-level message to all connected peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
sendToAllClientsMany :: (SyncMonad t m, NetworkServer t m, Store a, Foldable f, Functor f)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Each time the event fires the content in sended to remote peer.
  -> Event t (f a)
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
sendToAllClientsMany itemId mt eas = do
  peers <- networkPeers
  sendToClientsMany peers itemId mt eas

-- | Synchronisation from client to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
--
-- You probably want to group 'syncFromClient' calls within one scope of 'processPeers'
-- or 'peersCollection' as it more efficient than multiple calls for 'syncFromClients'
-- or 'syncFromAllClients'.
syncFromClient :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Make initial value
  -> m a
  -- | When the event fires, client side info is rejected and payload replaces
  -- dynamic contents.
  -> Event t a
  -- | Peer that is listened for values.
  -> Peer
  -- | Dynamic with respect to rejects and event that fires with old and new value
  -- when server rejects client side value.
  -> m (Dynamic t a, Event t (a, a))
syncFromClient itemId mkInit rejectE peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- listen for state
  msgE <- syncPeerMessage peer i itemId
  -- check whether we want to reject value
  rec
    let rejectsE = attachWith (,) (current updatedDyn) rejectE
        rejectMsgE = encodeSyncMessage ReliableMessage i itemId <$> rejectE
    _ <- peerChanSend peer chan rejectMsgE
    -- collect state on server side
    initVal <- mkInit
    updatedDyn <- holdDyn initVal $ leftmost [rejectE, msgE]
  return (updatedDyn, rejectsE)

-- | Synchronisation from clients to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
syncFromClients :: forall t m a f . (SyncMonad t m, NetworkServer t m, Store a, Foldable f)
  -- | Collection of peers to receive from
  => Dynamic t (f Peer)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Make initial value
  -> (Peer -> m a)
  -- | When the event fires, client side info is rejected and payload replaces
  -- dynamic contents.
  -> Event t (Map Peer a)
  -- | Collected state for each Peer with respect of rejections. The second event
  -- contains info which values were rejected and which values replaced them.
  --
  -- Note: see 'syncFromClient' result type.
  -> m (Dynamic t (Map Peer a), Event t (Map Peer (a, a)))
syncFromClients peersDyn itemId mkInit rejectE = do
  switchedMap :: Event t (Dynamic t (Map Peer a), Event t (Map Peer (a, a))) <- dynAppHost $ go <$> peersDyn
  dynPair <- holdDyn (pure mempty, never) switchedMap
  return (join . fmap fst $ dynPair, switchPromptlyDyn . fmap snd $ dynPair)
  where
    go :: f Peer -> m (Dynamic t (Map Peer a), Event t (Map Peer (a, a)))
    go peers = do
      es <- mapM goPeer $ F.toList peers
      let dmap = sequence $ M.fromList $ (\(a, b, _) -> (a, b)) <$> es
      let emap = mergeMap $ M.fromList $ (\(a, _, c) -> (a, c)) <$> es
      return (dmap, emap)
    goPeer :: Peer -> m (Peer, Dynamic t a, Event t (a, a))
    goPeer peer = do
      let rejectE' = fforMaybe rejectE $ M.lookup peer
      (da, ea) <- syncFromClient itemId (mkInit peer) rejectE' peer
      return (peer, da, ea)

-- | Synchronisation from client to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
syncFromAllClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Make initial value
  -> (Peer -> m a)
  -- | When the event fires, client side info is rejected and payload replaces
  -- dynamic contents.
  -> Event t (Map Peer a)
  -- | Collected state for each Peer.
  -> m (Dynamic t (Map Peer a), Event t (Map Peer (a, a)))
syncFromAllClients itemId initial rejectE = do
  peers <- networkPeers
  syncFromClients peers itemId initial rejectE

-- | Receiving high-level message from client to server.
--
-- Server has to call corresponding 'sendToServer' function to receive updates.
--
-- You probably want to group 'receiveFromClient' calls within one scope of peers
-- (see 'networkPeers') as it more efficient than multiple calls for 'receiveFromAllClients'.
receiveFromClient :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Peer that is listened for values.
  -> Peer
  -- | Collected state for each Peer.
  -> m (Event t a)
receiveFromClient itemId peer = do
  i <- makeSyncName =<< syncCurrentName
  syncPeerMessage peer i itemId

-- | Receiving high-level message from client to server.
--
-- Server has to call corresponding 'sendToServer' function to receive updates.
--
-- You probably want to group 'receiveFromClient' calls within one scope of peers
-- (see 'networkPeers') as it more efficient than multiple calls for 'receiveFromAllClients'.
receiveFromClients :: forall t m a f . (SyncMonad t m, NetworkServer t m, Store a, Foldable f)
  -- | Collection of peers to receive from
  => Dynamic t (f Peer)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Collected state for each Peer.
  -> m (Event t (Map Peer a))
receiveFromClients peersDyn itemId = do
  switchE <- dynAppHost $ go <$> peersDyn
  switchPromptly never switchE
  where
    go :: f Peer -> m (Event t (Map Peer a))
    go peers = do
      es <- mapM goPeer $ F.toList peers
      return $ mergeMap $ M.fromList es

    goPeer :: Peer -> m (Peer, Event t a)
    goPeer peer = do
      a <- receiveFromClient itemId peer
      return (peer, a)

-- | Receiving high-level message from client to server.
--
-- Server has to call corresponding 'sendToServer' function to receive updates.
--
-- You probably want to group 'receiveFromClient' calls within one scope of peers
-- (see 'networkPeers') as it more efficient than multiple calls for 'receiveFromAllClients'.
receiveFromAllClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Collected state for each Peer.
  -> m (Event t (Map Peer a))
receiveFromAllClients itemId = do
  peers <- networkPeers
  receiveFromClients peers itemId

-- | Update dynamic value only if given predicate returns 'True'.
--
-- The helper is intended to be used with 'syncToClients' to create
-- conditional synchronisation.
conditional :: (Reflex t, MonadHold t m)
  => Dynamic t a -- ^ Original dynamic
  -> (a -> PushM t Bool) -- ^ Predicate, return 'True' to pass value into new dynamic
  -> m (Dynamic t a) -- ^ Filtered dynamic
conditional da predicate = do
  ai <- sample . current $ da
  let ae = push predicate' . updated $ da
  holdDyn ai ae
  where
    predicate' a = do
      res <- predicate a
      return $ if res then Just a else Nothing

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predict :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predict origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDyn predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictMaybe :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> Maybe a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predictMaybe origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynMaybe predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictM :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> PushM t a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predictM origDyn tickE predictFunc = do
  a <- sample . current $ origDyn
  let mkStep v = foldDynM predictFunc v tickE
  initialDyn <- mkStep a
  dynDyn <- holdAppHost (pure initialDyn) $ mkStep <$> updated origDyn
  return $ join dynDyn

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictMaybeM :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> PushM t (Maybe a))
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predictMaybeM origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynMaybeM predictFunc a tickE

-- | Receive stream of values from remote server. With explicit value to use for
-- initial values that are used until connected to server and until scope name
-- is resolved.
--
-- Matches to call of 'syncToClient', should be called on client side.
syncFromServerWith :: (SyncMonad t m, NetworkClient t m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> Dynamic t a -- ^ Which dynamic to use for initial value
  -> m (Dynamic t a)
syncFromServerWith itemId initDyn = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  fmap join $ whenConnected (return initDyn) $ \peer -> do -- first wait until connected
    fmap join $ resolveSyncName peer name (return initDyn) $ \i -> do -- wait for id
      -- send initial request to inform client of initial value for rarely changing values
      buildE <- getPostBuild
      let reqE = const (encodeSyncRequest ReliableMessage i itemId) <$> buildE
      logVerboseE $ ffor buildE $ const $ "Sync: Sending request for initial value of " <> showl itemId <> " for scope " <> showl name
      _ <- peerChanSend peer chan reqE
      -- listen for responds of server
      msgE <- syncPeerMessage peer i itemId
      a <- sample . current $ initDyn
      holdDyn a msgE -- here collect updates in dynamic

-- | Receive stream of values from remote server.
--
-- Matches to call of 'syncToClient', should be called on client side.
syncFromServer :: (SyncMonad t m, NetworkClient t m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> a -- ^ Initial value
  -> m (Dynamic t a)
syncFromServer itemId initVal = syncFromServerWith itemId (pure initVal)

-- | Receive message from remote server.
--
-- Matches to call of 'sendToClient', should be called on client side.
receiveFromServer :: (SyncMonad t m, NetworkClient t m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> m (Event t a)
receiveFromServer itemId = do
  name <- syncCurrentName
  fmap switchPromptlyDyn $ whenConnected (pure never) $ \peer -> do -- first wait until connected
    fmap switchPromptlyDyn $ resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      -- listen for responds of server
      syncPeerMessage peer i itemId

-- | Result of execution of 'syncToServer'
data ClientSynced a =
    ClientSentToServer -- ^ Client sent state to server
  | ServerRejected a -- ^ Server rejected last state and returned valid one
  deriving (Generic, Show, Read)

-- | Pass only rejected-by-server messages
serverRejected :: Reflex t => Event t (ClientSynced a) -> Event t a
serverRejected = fmapMaybe $ \case
  ServerRejected a -> Just a
  _ -> Nothing

-- | Synchronisation from client to server. Server can reject values and send actual state.
--
-- Server has to call corresponding 'syncFromClients' function to receive updates.
syncToServer :: (SyncMonad t m, NetworkClient t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to server. Note that updates to server
  -- are sent each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Event that fires each time a new message is passed to server or server
  -- rejected client state.
  --
  -- Note: that you might like to update input dynamic with corrected values via
  -- mfix cycle.
  -> m (Event t (ClientSynced a))
syncToServer itemId mt da = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  dynEv <- whenConnected (pure never) $ \peer -> do -- first wait until connected
    dynEv <- resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      -- we need to send initial request to inform client of initial value for rarely changing values
      buildE <- getPostBuild
      let initialE = encodeSyncMessage mt i itemId <$> tagPromptlyDyn da buildE
          updatedE = encodeSyncMessage mt i itemId <$> updated da
      sendedE <- peerChanSend peer chan $ leftmost [updatedE, initialE]
      -- listen for responds of server
      msgE <- syncPeerMessage peer i itemId
      -- we can either inform about rejected value or that we synced to server
      return $ leftmost [
          ServerRejected <$> msgE
        , const ClientSentToServer <$> sendedE
        ]
    return $ switchPromptlyDyn dynEv
  return $ switchPromptlyDyn dynEv

-- | Synchronisation from client to server. Server can reject values and send actual state.
--
-- Server has to call corresponding 'syncFromClients' function to receive updates.
sendToServer :: (SyncMonad t m, NetworkClient t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to server.
  -> Event t a
  -- | Event that fires each time a new message is passed to server
  -> m (Event t ())
sendToServer itemId mt ea = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  fmap switchPromptlyDyn $ whenConnected (pure never) $ \peer -> do -- first wait until connected
    fmap switchPromptlyDyn $ resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      let msgE = encodeSyncMessage mt i itemId <$> ea
      peerChanSend peer chan msgE

-- | Synchronisation from client to server. Server can reject values and send actual state.
--
-- Server has to call corresponding 'syncFromClients' function to receive updates.
sendToServerMany :: (SyncMonad t m, NetworkClient t m, Store a, Foldable f, Functor f)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to server.
  -> Event t (f a)
  -- | Event that fires each time a new message is passed to server
  -> m (Event t ())
sendToServerMany itemId mt eas = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  fmap switchPromptlyDyn $ whenConnected (pure never) $ \peer -> do -- first wait until connected
    fmap switchPromptlyDyn $ resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      let msgsE = fmap (encodeSyncMessage mt i itemId) <$> eas
      peerChanSendMany peer chan msgsE

-- | Helper that fires when a synchronization message in interest arrives
syncMessage :: (SyncMonad t m, NetworkMonad t m)
  => (Peer -> SyncMessage -> Maybe a) -> m (Event t a)
syncMessage predicate = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  msgE <- chanMessage chan
  logEitherWarn $ fforMaybe msgE $ \(peer, bs) -> moveEither $ do
    msg <- decodeSyncMessage bs
    return $ predicate peer msg
  where
    moveEither :: Either PeekException (Maybe a) -> Maybe (Either LogStr a)
    moveEither e = case e of
      Left er -> Just . Left $ showl er
      Right ma -> Right <$> ma

-- | Helper that fires when a sync request arrives
syncRequestMessage :: (SyncMonad t m, NetworkMonad t m)
  => Peer -- ^ Expected peer as source of message
  -> SyncId -- ^ Id of scope that is expected
  -> SyncItemId -- ^ Id of synch item that is expected
  -> m (Event t ())
syncRequestMessage peer i ii = syncMessage $ \peer' msg -> case msg of
  SyncRequestMessage i' ii' -> if peer' == peer && i' == i && ii' == ii
    then Just ()
    else Nothing
  _ -> Nothing

-- | Helper, fires when a synchronization message arrived
syncServiceMessage :: (SyncMonad t m, NetworkMonad t m)
  => m (Event t (Peer, SyncServiceMessage))
syncServiceMessage = syncMessage $ \peer msg -> case msg of
  SyncServiceMessage smsg -> Just (peer, smsg)
  _ -> Nothing

-- | Helper, fires when a synchronization message arrived
syncPeerMessage :: (SyncMonad t m, NetworkMonad t m, Store a)
  => Peer -- ^ Peer that should send the message
  -> SyncId -- ^ Scope id that is expected
  -> SyncItemId -- ^ Sync item id in scope
  -> m (Event t a)
syncPeerMessage peer i itemId = do
  msgE <- syncMessage $ \peer' msg -> case msg of
    SyncPayloadMessage i' itemId' bs -> if peer == peer' && i == i' && itemId == itemId'
      then Just bs
      else Nothing
    _ -> Nothing
  logEitherWarn $ ffor msgE $ first mkDecodeFailMsg . decode
  where
    mkDecodeFailMsg e = "Sync: Failed to decode payload for scope: "
      <> showl i <> ", with item id: "
      <> showl itemId <> ", error: "
      <> showl e

-- | Helper that finds id for name or create new id for the name.
makeSyncName :: SyncMonad t m
  => SyncName -- ^ Name to get id for
  -> m SyncId
makeSyncName name = do
  namesDyn <- syncKnownNames
  startNames <- sample . current $ namesDyn
  case H.lookup name startNames of
    Just i -> return i
    Nothing -> syncUnsafeRegId name

-- | Helper that tries to get an id for given sync name and then switch into
-- given handler.
resolveSyncName :: forall t m a . (SyncMonad t m, NetworkMonad t m)
  => Peer -- ^ Where to ask the name id
  -> SyncName -- ^ Name to resolve
  -> m a -- ^ Initial value
  -> (SyncId -> m a) -- ^ Next component to switch in when id of the name is acquired
  -> m (Dynamic t a) -- ^ Fired when the function finally resolve the name
resolveSyncName peer name im m = do
  namesDyn <- syncKnownNames
  startNames <- sample . current $ namesDyn
  case H.lookup name startNames of
    Just i -> do
      a <- m i
      return $ pure a
    Nothing -> do
      opts <- syncOptions
      buildE <- getPostBuild
      let resolvedEMany = fforMaybe (updated namesDyn) $ H.lookup name
      resolvedE <- headE resolvedEMany
      tickE <- tickEveryUntil (opts ^. syncOptionsResolveDelay) resolvedE
      let chan = opts ^. syncOptionsChannel
          requestE = leftmost [tickE, buildE]
      _ <- requestSyncId peer chan $ const name <$> requestE
      holdAppHost im $ fmap m resolvedE

-- | Helper that sends message to server with request to send back id of given
-- sync object.
--
-- Return event that fires when the request message is sent.
requestSyncId :: (LoggingMonad t m, NetworkMonad t m)
  => Peer -> ChannelID -> Event t SyncName -> m (Event t ())
requestSyncId peer chan ename = peerChanSend peer chan $ fmap mkMessage ename
  where
    mkMessage = encodeSyncServiceMsg ReliableMessage . ServiceAskId

-- | Helper that listens for all requests for sync ids and sends responds to them.
-- Also registers all ids from master nodes if respond is arrived to the local node.
--
-- The component is included in all implementations of the sync module.
syncService :: forall t m . (SyncMonad t m, NetworkMonad t m) => m ()
syncService = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
      role = opts ^. syncOptionsRole
  -- Filter messages
  msgE <- syncServiceMessage
  let reqE = fforMaybe msgE $ \(peer, msg) -> case msg of
        ServiceAskId name -> Just (peer, name)
        _ -> Nothing
      respE = fforMaybe msgE $ \(_, msg) -> case msg of
        ServiceTellId i name -> Just (name, i)
        _ -> Nothing
  -- Responses to request
  namesDyn <- syncKnownNames
  logVerboseE $ ffor reqE $ \(_, name) -> "Sync: got request for id of '" <> showl name <> "'"
  _ <- msgSend $ flip push reqE $ \(peer, name) -> do
    names <- sample . current $ namesDyn
    let makeMsg i = (peer, chan,) . encodeSyncServiceMsg ReliableMessage $ ServiceTellId i name
    return $ makeMsg <$> H.lookup name names
  -- Update cache for responses
  case role of
    SyncSlave -> do
      logVerboseE $ ffor respE $ \(name, i) -> "Sync: registering '"
        <> showl name <> "' <=> '"
        <> showl i <> "'"
      void $ performAppHost $ ffor respE $ uncurry syncUnsafeAddId
    SyncMaster -> return () -- not interested in on server

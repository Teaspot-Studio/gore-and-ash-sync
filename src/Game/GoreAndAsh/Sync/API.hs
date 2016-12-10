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
    SyncName
  , SyncMonad(..)
  , syncToClients
  , syncFromServer
  -- * Internal
  , NameMap
  , syncService
  ) where

import Control.Lens ((^.))
import Control.Monad
import Control.Monad.Trans
import Data.Monoid
import Data.Store
import Game.GoreAndAsh.Core
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time

import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M

-- | Bijection between name and id of synchronized object
type NameMap = H.HashMap SyncName SyncId

class (MonadAppHost t m, TimerMonad t m, LoggingMonad t m)
  => SyncMonad t m | m -> t where
    -- | Get settings of the module
    syncOptions :: m (SyncOptions ())
    -- | Get map of known names on the node
    syncKnownNames :: m (Dynamic t NameMap)
    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by server to generate id for name.
    syncUnsafeRegId :: SyncName -> m SyncId
    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by client to register id requested from server.
    syncUnsafeAddId :: SyncName -> SyncId -> m ()

instance {-# OVERLAPPABLE #-} (MonadAppHost t (mt m), MonadTrans mt, SyncMonad t m, TimerMonad t m, LoggingMonad t m)
  => SyncMonad t (mt m) where
    syncOptions = lift syncOptions
    {-# INLINE syncOptions #-}
    syncKnownNames = lift syncKnownNames
    {-# INLINE syncKnownNames #-}
    syncUnsafeRegId = lift . syncUnsafeRegId
    {-# INLINE syncUnsafeRegId #-}
    syncUnsafeAddId a b = lift $ syncUnsafeAddId a b
    {-# INLINE syncUnsafeAddId #-}

-- TODO: Idea to make named dynamic NDynamic t a = (SyncName, Dynamic t a)

-- | Start streaming given dynamic value to all connected clients
syncToClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization object
  => SyncName
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients
  -> Dynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t [Peer])
syncToClients name mt da = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName name
  dynSended <- processPeers $ \peer -> do
    buildE <- getPostBuild
    let updatedE = leftmost [updated da, tagPromptlyDyn da buildE]
        msgE = fmap (mkMessage i) updatedE
    peerChanSend peer chan msgE
  pure . switchPromptlyDyn $ fmap (fmap M.keys . mergeMap) dynSended
  where
    mkMessage i a = encodeSyncMessage mt $ SyncPayloadMessage i a

-- | Receive stream of values from remote server.
syncFromServer :: (SyncMonad t m, NetworkClient t m, Store a)
  => SyncName -- ^ Unique name of synchronization object
  -> a -- ^ Initial value
  -> m (Dynamic t a)
syncFromServer name initVal = do
  let pureInitVal = return $ pure initVal
  fmap join $ whenConnected pureInitVal $ \peer -> do -- first wait until connected
    fmap join $ resolveSyncName name pureInitVal $ \i -> do -- wait for id
      msgE <- syncPeerMessage peer
      let neededMsgE = fforMaybe msgE $ \case
            SyncPayloadMessage{..} -> if i == syncId
              then Just syncPayload
              else Nothing
            _ -> Nothing
      holdDyn initVal neededMsgE -- here collect updates in dynamic

-- | Helper, fires when a synchronization message arrived
syncMessage :: (SyncMonad t m, NetworkMonad t m, Store a)
  => m (Event t (Peer, SyncMessage a))
syncMessage = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  msgE <- chanMessage chan
  logEitherWarn $ ffor msgE $ \(peer, bs) -> case decodeSyncMessage bs of
    Left er -> Left $ showl er
    Right a -> Right (peer, a)

-- | Helper, fires when a synchronization message arrived
syncPeerMessage :: (SyncMonad t m, NetworkMonad t m, Store a)
  => Peer -> m (Event t (SyncMessage a))
syncPeerMessage peer = do
  msgE <- syncMessage
  return $ fforMaybe msgE $ \(peer', msg) -> if peer == peer'
    then Just msg
    else Nothing

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
resolveSyncName :: forall t m a . (SyncMonad t m, NetworkClient t m)
  => SyncName -- ^ Name to resolve
  -> m a -- ^ Initial value
  -> (SyncId -> m a) -- ^ Next component to switch in when id of the name is acquired
  -> m (Dynamic t a) -- ^ Fired when the function finally resolve the name
resolveSyncName name im m = do
  namesDyn <- syncKnownNames
  startNames <- sample . current $ namesDyn
  case H.lookup name startNames of
    Just i -> cachedName i
    Nothing -> join <$> chain (resolveStep namesDyn)
  where
    cachedName :: SyncId -> m (Dynamic t a)
    cachedName i = do
      a <- m i
      return $ pure a

    resolveStep :: Dynamic t NameMap -> m (Dynamic t a, Chain t m (Dynamic t a))
    resolveStep namesDyn = do
      opts <- syncOptions
      buildE <- getPostBuild
      let resolvedE = fforMaybe (updated namesDyn) $ H.lookup name
      tickE <- tickEveryUntil (opts ^. syncOptionsResolveDelay) resolvedE
      let chan = opts ^. syncOptionsChannel
          requestE = leftmost [tickE, buildE]
      _ <- requestSyncId chan $ const name <$> requestE
      initVal <- im
      return (pure initVal, Chain $ fmap calcStep resolvedE)

    calcStep :: SyncId -> m (Dynamic t a, Chain t m (Dynamic t a))
    calcStep i = do
      a <- m i
      return (pure a, Chain never)

-- | Helper that sends message to server with request to send back id of given
-- sync object.
--
-- Return event that fires when the request message is sent.
requestSyncId :: (LoggingMonad t m, NetworkClient t m)
  => ChannelID -> Event t SyncName -> m (Event t ())
requestSyncId chan ename = do
  dynSent <- whenConnected (pure never) $ \server ->
    peerChanSend server chan $ fmap mkMessage ename
  return $ switchPromptlyDyn dynSent
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
  msgE <- syncMessage :: m (Event t (Peer, SyncMessage ()))
  let reqE = fforMaybe msgE $ \(peer, msg) -> case msg of
        SyncServiceMessage (ServiceAskId name) -> Just (peer, name)
        _ -> Nothing
      respE = fforMaybe msgE $ \(_, msg) -> case msg of
        SyncServiceMessage (ServiceTellId i name) -> Just (name, i)
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

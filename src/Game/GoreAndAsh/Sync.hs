{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-|
Module      : Game.GoreAndAsh.Sync
Description : Gore&Ash high-level networking core module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX

The core module contains high-level networking API for Gore&Ash. It allows to define separate
types of messages for each actor and perform automatic synchronzation controlled by synchronization
EDSL.

The module depends on following core modules:

* actor - "Game.GoreAndAsh.Actor"
* logging - "Game.GoreAndAsh.Logging"
* network - "Game.GoreAndAsh.Network"

So 'SyncT' should be placed after 'LoggingT', 'ActorT' and 'NetworkT' in monad stack.

The module is NOT pure within first phase (see 'ModuleStack' docs), therefore currently only 'IO' end monad can handler the module.

Example of embedding:

@
-- | Application monad is monad stack build from given list of modules over base monad (IO)
type AppStack = ModuleStack [LoggingT, NetworkT, ActorT, SyncT ... other modules ... ] IO
newtype AppState = AppState (ModuleState AppStack)
  deriving (Generic)

instance NFData AppState 

-- | Wrapper around type family
newtype AppMonad a = AppMonad (AppStack a)
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadThrow, MonadCatch, LoggingMonad, NetworkMonad, ActorMonad, SyncMonad ... other modules monads ... )

-- | Current GHC (7.10.3) isn't able to derive this
instance SyncMonad AppMonad where 
  getSyncIdM = AppMonad . getSyncIdM
  getSyncTypeRepM = AppMonad . getSyncTypeRepM
  registerSyncIdM = AppMonad . registerSyncIdM
  addSyncTypeRepM a b = AppMonad $ addSyncTypeRepM a b
  syncScheduleMessageM peer ch i mt msg  = AppMonad $ syncScheduleMessageM peer ch i mt msg
  syncSetLoggingM = AppMonad . syncSetLoggingM
  syncSetRoleM = AppMonad . syncSetRoleM
  syncGetRoleM = AppMonad syncGetRoleM
  syncRequestIdM a b = AppMonad $ syncRequestIdM a b 

instance GameModule AppMonad AppState where 
  type ModuleState AppMonad = AppState
  runModule (AppMonad m) (AppState s) = do 
    (a, s') <- runModule m s 
    return (a, AppState s')
  newModuleState = AppState <$> newModuleState
  withModule _ = withModule (Proxy :: Proxy AppStack)
  cleanupModule (AppState s) = cleanupModule s 

-- | Arrow that is build over the monad stack
type AppWire a b = GameWire AppMonad a b
-- | Action that makes indexed app wire
type AppActor i a b = GameActor AppMonad i a b
@

Important note, the system tries to use channel id 1 for service messages, but fallbacks
to default channel if there is only one channel allocated in network module. Check initalization
of network module, client and server allocated channels count must match.
-}
module Game.GoreAndAsh.Sync(
  -- * Low-level API
    SyncState
  , SyncT
  , SyncRole(..)
  , SyncMonad(..)
  -- * Typed message API
  -- $messageExample
  , NetworkMessage(..)
  -- ** Getting messages
  , peerIndexedMessages
  , peerProcessIndexed
  , peerProcessIndexedM
  -- ** Sending messages
  , peerSendIndexedM
  , peerSendIndexed
  , peerSendIndexedDyn
  , peerSendIndexedMany
  , peerSendIndexedManyDyn
  -- ** Helpers
  , filterMsgs
  -- * Automatic synchronization
  -- $syncExample
  -- ** Remote actor API
  , RemoteActor(..)
  , clientSync
  , serverSync
  -- *** Synchronization primitives
  , Sync
  , FullSync
  , noSync
  , clientSide
  , serverSide
  , condSync
  , syncReject
  -- *** Helpers for conditional synchronization
  , fieldChanges
  , fieldChangesWithin
  -- ** Remote collection
  , RemActorCollId(..)
  , remoteActorCollectionServer
  , remoteActorCollectionClient
  ) where

-- for docs
import Game.GoreAndAsh
import Game.GoreAndAsh.Actor 
import Game.GoreAndAsh.Logging 
import Game.GoreAndAsh.Network 

import Game.GoreAndAsh.Sync.API as X
import Game.GoreAndAsh.Sync.Message as X
import Game.GoreAndAsh.Sync.Module as X
import Game.GoreAndAsh.Sync.Remote as X
import Game.GoreAndAsh.Sync.State as X

{- $messageExample
Example of usage of typed message API:

@
data Player = Player {
  playerId :: !PlayerId
, playerPos :: !(V2 Double)
, playerSize :: !Double
} deriving (Generic)

instance NFData Player 

newtype PlayerId = PlayerId { unPlayerId :: Int } deriving (Eq, Show, Generic) 
instance NFData PlayerId 
instance Hashable PlayerId 
instance Serialize PlayerId

-- | Local message type
data PlayerMessage =
    -- | The player was shot by specified player
    PlayerShotMessage !PlayerId 
  deriving (Typeable, Generic)

instance NFData PlayerMessage 

instance ActorMessage PlayerId where
  type ActorMessageType PlayerId = PlayerMessage
  toCounter = unPlayerId
  fromCounter = PlayerId

-- | Remote message type
data PlayerNetMessage = 
    NetMsgPlayerFire !(V2 Double)
  deriving (Generic, Show)

instance NFData PlayerNetMessage
instance Serialize PlayerNetMessage

instance NetworkMessage PlayerId where 
  type NetworkMessageType PlayerId = PlayerNetMessage

playerActorServer :: :: (PlayerId -> Player) -> AppActor PlayerId Game Player 
playerActorServer initialPlayer = makeActor $ \i -> stateWire (initialPlayer i) $ mainController i
  where
  mainController i = proc (g, p) -> do
    p2 <- peerProcessIndexedM peer (ChannelID 0) i netProcess -< p
    forceNF . playerShot -< p2
    where
    -- | Shortcut for peer
    peer = playerPeer $ initialPlayer i

    -- | Handle when player is shot
    playerShot :: AppWire Player Player
    playerShot = proc p -> do 
      emsg <- actorMessages i isPlayerShotMessage -< ()
      let newPlayer = p {
          playerPos = 0
        }
      returnA -< event p (const newPlayer) emsg

    -- | Process player specific net messages
    netProcess :: Player -> PlayerNetMessage -> GameMonadT AppMonad Player 
    netProcess p msg = case msg of 
      NetMsgPlayerFire v -> do 
        let d = normalize v 
            v2 a = V2 a a
            pos = playerPos p + d * v2 (playerSize p * 1.5)
            vel = d * v2 bulletSpeed
        putMsgLnM $ "Fire bullet at " <> pack (show pos) <> " with velocity " <> pack (show vel)
        actors <- calculatePlayersOnLine pos vel
        forM_ actors . actorSendM actor . PlayerShotMessage . playerId $ p
        return p 

playerActorClient :: Peer -> PlayerId -> AppActor PlayerId Camera Player 
playerActorClient peer i = makeFixedActor i $ stateWire initialPlayer $ proc (c, p) -> do 
  processFire -< (c, p)
  liftGameMonad4 renderSquare -< (playerSize p, playerPos p, playerColor p, c)
  forceNF -< p
  where
    initialPlayer = Player {
        playerId = i 
      , playerPos = 0
      , playerColor = V3 1 0 0
      , playerRot = 0
      , playerSpeed = 0.5
      , playerSize = 1
      }

    processFire :: AppWire (Camera, Player) ()
    processFire = proc (c, p) -> do 
      e <- mouseClick ButtonLeft -< ()
      let wpos = cameraToWorld c <$> e
      let edir = (\v -> normalize $ v - playerPos p) <$> wpos 
      let emsg = NetMsgPlayerFire <$> edir
      peerSendIndexed peer (ChannelID 0) i ReliableMessage -< emsg
      returnA -< ()
@
-}

{- $syncExample

The synchronization API is built around 'Sync' applicative functor. It allows to combine
complex synchronization strategies from reasonable small amount of basic blocks (see 'noSync', 'clientSide', 'serverSide', 'condSync', 'syncReject'). 

Synchornization description is considered as complete, when you get 'Sync m i a a' type ('FullSync' type synonym).
After that you can use 'clientSync' and 'serverSync' at your actors to sync them.

Example of usage of sync API:

@
data Player = Player {
  playerId :: !PlayerId
, playerPos :: !(V2 Double)
, playerSize :: !Double
} deriving (Generic)

instance NFData Player 

newtype PlayerId = PlayerId { unPlayerId :: Int } deriving (Eq, Show, Generic) 
instance NFData PlayerId 
instance Hashable PlayerId 
instance Serialize PlayerId

-- | Local message type
data PlayerMessage =
    -- | The player was shot by specified player
    PlayerShotMessage !PlayerId 
  deriving (Typeable, Generic)

instance NFData PlayerMessage 

instance ActorMessage PlayerId where
  type ActorMessageType PlayerId = PlayerMessage
  toCounter = unPlayerId
  fromCounter = PlayerId

-- | Remote message type
data PlayerNetMessage = 
    NetMsgPlayerFire !(V2 Double)
  deriving (Generic, Show)

instance NFData PlayerNetMessage
instance Serialize PlayerNetMessage

instance NetworkMessage PlayerId where 
  type NetworkMessageType PlayerId = PlayerNetMessage

playerActorServer :: :: (PlayerId -> Player) -> AppActor PlayerId Game Player 
playerActorServer initialPlayer = makeActor $ \i -> stateWire (initialPlayer i) $ mainController i
  where
  mainController i = proc (g, p) -> do
    p2 <- peerProcessIndexedM peer (ChannelID 0) i netProcess -< p
    forceNF . serverSync playerSync i . playerShot -< p2
    where
    -- | Shortcut for peer
    peer = playerPeer $ initialPlayer i

    -- | Handle when player is shot
    playerShot :: AppWire Player Player
    playerShot = proc p -> do 
      emsg <- actorMessages i isPlayerShotMessage -< ()
      let newPlayer = p {
          playerPos = 0
        }
      returnA -< event p (const newPlayer) emsg

    -- | Process player specific net messages
    netProcess :: Player -> PlayerNetMessage -> GameMonadT AppMonad Player 
    netProcess p msg = case msg of 
      NetMsgPlayerFire v -> do 
        let d = normalize v 
            v2 a = V2 a a
            pos = playerPos p + d * v2 (playerSize p * 1.5)
            vel = d * v2 bulletSpeed
        putMsgLnM $ "Fire bullet at " <> pack (show pos) <> " with velocity " <> pack (show vel)
        actors <- calculatePlayersOnLine pos vel
        forM_ actors . actorSendM actor . PlayerShotMessage . playerId $ p
        return p 

    playerSync :: FullSync AppMonad PlayerId Player 
    playerSync = Player 
      \<$\> pure i 
      \<*\> clientSide peer 0 playerPos
      \<*\> clientSide peer 1 playerSize

playerActorClient :: Peer -> PlayerId -> AppActor PlayerId Camera Player 
playerActorClient peer i = makeFixedActor i $ stateWire initialPlayer $ proc (c, p) -> do 
  processFire -< (c, p)
  liftGameMonad4 renderSquare -< (playerSize p, playerPos p, playerColor p, c)
  forceNF . clientSync playerSync peer i -< p
  where
    initialPlayer = Player {
        playerId = i 
      , playerPos = 0
      , playerColor = V3 1 0 0
      , playerRot = 0
      , playerSpeed = 0.5
      , playerSize = 1
      }

    processFire :: AppWire (Camera, Player) ()
    processFire = proc (c, p) -> do 
      e <- mouseClick ButtonLeft -< ()
      let wpos = cameraToWorld c <$> e
      let edir = (\v -> normalize $ v - playerPos p) <$> wpos 
      let emsg = NetMsgPlayerFire <$> edir
      peerSendIndexed peer (ChannelID 0) i ReliableMessage -< emsg
      returnA -< ()

    playerSync :: FullSync AppMonad PlayerId Player 
    playerSync = Player 
      \<$\> pure i 
      \<*\> clientSide peer 0 playerPos
      \<*\> clientSide peer 1 playerSize
@
-}
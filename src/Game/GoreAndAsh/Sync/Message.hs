{-|
Module      : Game.GoreAndAsh.Sync.Message
Description : Message structure for synchronization module.
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
module Game.GoreAndAsh.Sync.Message(
    SyncName
  , SyncId
  , SyncMessage(..)
  , SyncServiceMessage(..)
  , encodeSyncMessage
  , encodeSyncServiceMsg
  , decodeSyncMessage
  ) where

import Data.Store
import Data.Word
import GHC.Generics
import Game.GoreAndAsh.Network.Message
import Data.ByteString (ByteString)

-- | Defines unique name of synchronization object so nodes
-- are able to find which value need an update on other side.
type SyncName = String

-- | Identifier that bijectively maps to 'SyncName'. That helps to avoid
-- overhead of sending full names over network.
type SyncId = Word32

-- | Defines main message protocol
data SyncMessage a =
  -- | Utility messages
    SyncServiceMessage !SyncServiceMessage
  -- | Payloads of synchronizations
  | SyncPayloadMessage {
      syncId      :: !SyncId
    , syncPayload :: !a
    }
  deriving (Generic)

instance Store a => Store (SyncMessage a)

-- | Defines service messages
data SyncServiceMessage =
  -- | Request an id for given name
    ServiceAskId !SyncName
  -- | Information that given sync name has given id
  | ServiceTellId !SyncId !SyncName
  deriving (Generic)

instance Store SyncServiceMessage

-- | Convert synch message into message of underlying network module
encodeSyncMessage :: Store a => MessageType -> SyncMessage a -> Message
encodeSyncMessage mt sm = Message mt (encode sm)

-- | Helper for encoding service messages
encodeSyncServiceMsg :: MessageType -> SyncServiceMessage -> Message
encodeSyncServiceMsg mt smsg = Message mt (encode msg)
  where
    msg :: SyncMessage ()
    msg = SyncServiceMessage smsg

-- | Convert received payload to sync message
decodeSyncMessage :: Store a => ByteString -> Either PeekException (SyncMessage a)
decodeSyncMessage = decode

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
  , SyncItemId
  , SyncId
  , SyncMessage(..)
  , SyncServiceMessage(..)
  , encodeSyncMessage
  , encodeSyncCommand
  , encodeSyncRequest
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
--
-- The name is used to define dynamically resolved scope for
-- values.
type SyncName = String

-- | Defines unique name withing a current 'SyncName' object scope.
-- That is statically known number that binds a value between clients and
-- server within single sync object.
--
-- Note that unlike the 'SyncName' the id is used to define
-- statially resolved value.
type SyncItemId = Word32

-- | Identifier that bijectively maps to 'SyncName'. That helps to avoid
-- overhead of sending full names over network.
type SyncId = Word32

-- | Defines main message protocol
data SyncMessage =
  -- | Utility messages
    SyncServiceMessage !SyncServiceMessage
  -- | Payloads of synchronizations that is sended by source of value to consumers
  | SyncPayloadMessage {
      syncId      :: !SyncId     -- ^ Scope id
    , syncItemId  :: !SyncItemId -- ^ Specific value id
    , syncCounter :: !Word16     -- ^ Counter of message, messages being late are droped
    , syncPayload :: !ByteString -- ^ Payload with updated value
    }
  -- | Payloads for single commands that aren't sequenced
  | SyncCommandMessage {
      syncId      :: !SyncId     -- ^ Scope id
    , syncItemId  :: !SyncItemId -- ^ Specific value id
    , syncPayload :: !ByteString -- ^ Payload with updated value
    }
  -- | Request of value from consumer (needed for rarely changing values)
  | SyncRequestMessage {
      syncId      :: !SyncId     -- ^ Scope id
    , syncItemId  :: !SyncItemId -- ^ Specific value id
    }
  deriving (Generic)

instance Store SyncMessage

-- | Defines service messages
data SyncServiceMessage =
  -- | Request an id for given name
    ServiceAskId !SyncName
  -- | Information that given sync name has given id
  | ServiceTellId !SyncId !SyncName
  deriving (Generic)

instance Store SyncServiceMessage

-- | Convert sync message into message of underlying network module
encodeSyncMessage :: Store a => MessageType -> SyncId -> SyncItemId -> Word16 -> a -> Message
encodeSyncMessage mt i ii c a = Message mt (encode $ SyncPayloadMessage i ii c $ encode a)

-- | Convert sync message into message of underlying network module
encodeSyncCommand :: Store a => MessageType -> SyncId -> SyncItemId -> a -> Message
encodeSyncCommand mt i ii a = Message mt (encode $ SyncCommandMessage i ii $ encode a)

-- | Convert sync message into message of underlying network module
encodeSyncRequest :: MessageType -> SyncId -> SyncItemId -> Message
encodeSyncRequest mt i ii = Message mt (encode $ SyncRequestMessage i ii)

-- | Helper for encoding service messages
encodeSyncServiceMsg :: MessageType -> SyncServiceMessage -> Message
encodeSyncServiceMsg mt smsg = Message mt (encode $ SyncServiceMessage smsg)

-- | Convert received payload to sync message
decodeSyncMessage :: ByteString -> Either PeekException SyncMessage
decodeSyncMessage = decode

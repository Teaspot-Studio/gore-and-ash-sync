{-|
Module      : Game.GoreAndAsh.Sync.Collection.Message
Description : Synchronisation of remote collections, message protocol.
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
module Game.GoreAndAsh.Sync.Collection.Message(
    RemoteCollectionMsg(..)
  , sendComponentCreateMsg
  , sendComponentDeleteMsg
  , sendComponentsRequestMsg
  , decodeRemoteCollectionMsg
  ) where

import Data.Store
import GHC.Generics
import Data.ByteString (ByteString)

import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.Message

-- | Communication protocol for remote collections
data RemoteCollectionMsg k v =
  -- | Message that indicates that server has created a component
    RemoteComponentCreate {
      remoteComponentSyncId :: !SyncId     -- ^ ID of sync scope
    , remoteComponentItemId :: !SyncItemId -- ^ ID of collection
    , remoteComponentKey    :: !k          -- ^ Key of component
    , remoteComponentValue  :: !v          -- ^ Creation parameter
    }
  -- | Message that indicates that server has destroyed a component
  | RemoteComponentDelete {
      remoteComponentSyncId :: !SyncId     -- ^ ID of sync scope
    , remoteComponentItemId :: !SyncItemId -- ^ ID of collection
    , remoteComponentKey    :: !k          -- ^ Key of component deleted
    }
  -- | Message from client that wants to know current list of components
  | RemoteComponentsRequest {
      remoteComponentSyncId :: !SyncId     -- ^ ID of sync scope
    , remoteComponentItemId :: !SyncItemId -- ^ ID of collection
    }
  deriving (Generic)

instance (Store k, Store v) => Store (RemoteCollectionMsg k v)

-- | Encoding high-level collection message about creation of component
-- to low-level network message.
encodeComponentCreateMsg :: (Store k, Store v)
  => SyncId -- ^ Sync scope dynamic id
  -> SyncItemId -- ^ Sync item static id
  -> k -- ^ Component key
  -> v -- ^ Component create value
  -> Message
encodeComponentCreateMsg i itemId k v = Message ReliableMessage $
  encode RemoteComponentCreate {
      remoteComponentSyncId = i
    , remoteComponentItemId = itemId
    , remoteComponentKey    = encode k
    , remoteComponentValue  = encode v
    }

-- | Send message about remote collection component creation from
-- incoming event.
sendComponentCreateMsg :: (LoggingMonad t m, NetworkMonad t m, Store k, Store v)
  => Peer -- ^ Client which we are sending
  -> ChannelID -- ^ ID of channel to use
  -> SyncId -- ^ Sync scope dynamic id
  -> SyncItemId -- ^ Sync item static id
  -> Event t (k, v) -- ^ Key and creation value of component
  -> m (Event t ()) -- ^ Event that message is sent
sendComponentCreateMsg peer chan i itemId ekv = peerChanSend peer chan $
  uncurry (encodeComponentCreateMsg i itemId) <$> ekv

-- | Encoding high-level collection message about deletion of component
-- to low-level network message.
encodeComponentDeleteMsg :: Store k
  => SyncId -- ^ Sync scope dynamic id
  -> SyncItemId -- ^ Sync item static id
  -> k -- ^ Component key
  -> Message
encodeComponentDeleteMsg i itemId k = Message ReliableMessage $ encode msg
  where
  msg :: RemoteCollectionMsg ByteString ByteString
  msg = RemoteComponentDelete {
      remoteComponentSyncId = i
    , remoteComponentItemId = itemId
    , remoteComponentKey    = encode k
    }

-- | Send message about remote collection component destruction from
-- incoming event.
sendComponentDeleteMsg :: (LoggingMonad t m, NetworkMonad t m, Store k)
  => Peer -- ^ Client which we are sending
  -> ChannelID -- ^ ID of channel to use
  -> SyncId -- ^ Sync scope dynamic id
  -> SyncItemId -- ^ Sync item static id
  -> Event t k -- ^ Key of component
  -> m (Event t ()) -- ^ Event that message is sent
sendComponentDeleteMsg peer chan i itemId ek = peerChanSend peer chan $
  encodeComponentDeleteMsg i itemId <$> ek

-- | Encoding high-level collection message about request for components
-- to low-level network message.
encodeComponentsRequestMsg ::
     SyncId -- ^ Sync scope dynamic id
  -> SyncItemId -- ^ Sync item static id
  -> Message
encodeComponentsRequestMsg i itemId = Message ReliableMessage $ encode msg
  where
  msg :: RemoteCollectionMsg ByteString ByteString
  msg = RemoteComponentsRequest {
      remoteComponentSyncId = i
    , remoteComponentItemId = itemId
    }

-- | Send message about request for remote collection components from
-- incoming event.
sendComponentsRequestMsg :: (LoggingMonad t m, NetworkMonad t m)
  => Peer -- ^ Client which we are sending
  -> ChannelID -- ^ ID of channel to use
  -> SyncId -- ^ Sync scope dynamic id
  -> SyncItemId -- ^ Sync item static id
  -> Event t a -- ^ When to send a request message
  -> m (Event t ()) -- ^ Event that message is sent
sendComponentsRequestMsg peer chan i itemId ek = peerChanSend peer chan $
  const (encodeComponentsRequestMsg i itemId) <$> ek

-- | Decoding high-level remote collection message from bytestring received
-- from network module.
decodeRemoteCollectionMsg :: (Store k, Store v)
  => ByteString -- ^ Payload to decode
  -> Either PeekException (RemoteCollectionMsg k v)
decodeRemoteCollectionMsg bs = do
  tempMsg :: RemoteCollectionMsg ByteString ByteString <- decode bs
  case tempMsg of
    RemoteComponentCreate{..} -> RemoteComponentCreate
      <$> pure remoteComponentSyncId
      <*> pure remoteComponentItemId
      <*> decode remoteComponentKey
      <*> decode remoteComponentValue
    RemoteComponentDelete{..} -> RemoteComponentDelete
      <$> pure remoteComponentSyncId
      <*> pure remoteComponentItemId
      <*> decode remoteComponentKey
    RemoteComponentsRequest{..} -> RemoteComponentsRequest
      <$> pure remoteComponentSyncId
      <*> pure remoteComponentItemId

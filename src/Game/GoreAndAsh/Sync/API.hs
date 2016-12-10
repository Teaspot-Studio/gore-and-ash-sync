{-|
Module      : Game.GoreAndAsh.Sync.API
Description : API of synchronization module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
module Game.GoreAndAsh.Sync.API(
    SyncMonad(..)
  ) where

import Game.GoreAndAsh.Core
import Control.Monad.Trans

class (MonadAppHost t m)
  => SyncMonad t m | m -> t where
    noop :: m ()

instance {-# OVERLAPPABLE #-} (MonadAppHost t (mt m), MonadTrans mt, SyncMonad t m)
  => SyncMonad t (mt m) where
    noop = lift noop
    {-# INLINE noop #-}

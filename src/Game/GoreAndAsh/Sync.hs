{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-|
Module      : Game.GoreAndAsh.Sync
Description : Gore&Ash high-level networking core module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX

The core module contains high-level networking API for Gore&Ash. It allows to perform
automatic synchronzation of states on clients and server using a special EDSL.

Example of embedding:
TODO ADD THIS

Important note, the system tries to use channel id 1 for service messages, but fallbacks
to default channel if there is only one channel allocated in network module. Check initalization
of network module, client and server allocated channels count must match.
-}
module Game.GoreAndAsh.Sync(

  ) where

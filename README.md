gore-and-ash-sync
====================

The module provides facilities of high level synchronizing for [Gore&Ash](https://github.com/Teaspot-Studio/gore-and-ash) engine.

The module depends on:
- [gore-and-ash-logging](https://github.com/Teaspot-Studio/gore-and-ash-logging)
- [gore-and-ash-actor](https://github.com/Teaspot-Studio/gore-and-ash-actor)
- [gore-and-ash-network](https://github.com/Teaspot-Studio/gore-and-ash-network)

Installing
==========

Add following to your `stack.yml` to `packages` section:
```yaml
- location:
    git: https://github.com/Teaspot-Studio/gore-and-ash-sync.git
    commit: <PLACE HERE FULL HASH OF LAST COMMIT> 
```

When defining you application stack, add `SyncT`:
``` haskell
type AppStack = ModuleStack [LoggingT, ActorT, NetworkT, SyncT, ... other modules ... ] IO
```

Unfortunately deriving for `SyncMonad` isn't work (bug of GHC 7.10.3), so you need meddle with some boilerplate while defining `SyncMonad` instance for your application monad wrapper:
``` haskell
newtype AppMonad a = AppMonad (AppStack a)
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadThrow, MonadCatch LoggingMonad, NetworkMonad)

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
```
{-|
Module      : Game.GoreAndAsh.Sync.Predict
Description : Prediction tools for synchonisation
Copyright   : (c) Anton Gushcha, 2015-2017
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
module Game.GoreAndAsh.Sync.Predict(
    predict
  , predictMaybe
  , predictM
  , predictMaybeM
  -- * With interpolation
  , predictInterpolateM
  ) where

import Control.Monad
import Data.Time

import Game.GoreAndAsh
import Game.GoreAndAsh.Time

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predict :: (MonadGame t m)
  => Dynamic t a
  -- ^ Original dynamic. Common case is dynamic from 'syncFromServer' function.
  -> Event t b
  -- ^ Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> (b -> a -> a)
  -- ^ Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> m (Dynamic t a)
  -- ^ Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
predict origDyn tickE predictFunc = do
  dynDyn <- networkHold (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDyn predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictMaybe :: (MonadGame t m)
  => Dynamic t a
  -- ^ Original dynamic. Common case is dynamic from 'syncFromServer' function.
  -> Event t b
  -- ^ Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> (b -> a -> Maybe a)
  -- ^ Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> m (Dynamic t a)
  -- ^ Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
predictMaybe origDyn tickE predictFunc = do
  dynDyn <- networkHold (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynMaybe predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictM :: (MonadGame t m)
  => Dynamic t a
  -- ^ Original dynamic. Common case is dynamic from 'syncFromServer' function.
  -> Event t b
  -- ^ Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> (b -> a -> PushM t a)
  -- ^ Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> m (Dynamic t a)
  -- ^ Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
predictM origDyn tickE predictFunc = do
  a <- sample . current $ origDyn
  let mkStep v = foldDynM predictFunc v tickE
  initialDyn <- mkStep a
  dynDyn <- networkHold (pure initialDyn) $ mkStep <$> updated origDyn
  return $ join dynDyn

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictMaybeM :: (MonadGame t m)
  => Dynamic t a
  -- ^ Original dynamic. Common case is dynamic from 'syncFromServer' function.
  -> Event t b
  -- ^ Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> (b -> a -> PushM t (Maybe a))
  -- ^ Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> m (Dynamic t a)
  -- ^ Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
predictMaybeM origDyn tickE predictFunc = do
  dynDyn <- networkHold (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynMaybeM predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictInterpolateM :: forall t m a b . (MonadGame t m, Fractional a)
  => Int -- ^ Number of intermediate values
  -> (a -> m (Maybe NominalDiffTime))
  -- ^ Time interval in which all interpolation have to be performed, depends on difference
  -- betwen old and new values of dynamic. Returned 'Nothing' means not interpolation needed,
  -- just replace with new value.
  -> Dynamic t a
  -- ^ Original dynamic. Common case is dynamic from 'syncFromServer' function.
  -> Event t b
  -- ^ Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> (b -> a -> PushM t a)
  -- ^ Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> m (Dynamic t a)
  -- ^ Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
predictInterpolateM n mkDt origDyn tickE predictFunc = do
  let
    -- Make dynamict that predicts from given start value
    mkPredictStep :: a -> m (Dynamic t a)
    mkPredictStep v = foldDynM predictFunc v tickE

    -- Make dynamict that interpolates from old server value to new one (argument)
    -- and switch to prediction after
    mkInterpStep :: Dynamic t a -> a -> m (Dynamic t a)
    mkInterpStep oldDyn newV = do
      oldV <- sample . current $ oldDyn
      mdt <- mkDt $ newV - oldV
      case mdt of
        Nothing -> mkPredictStep newV
        Just dt -> do
          stopE <- tickOnce dt
          interDyn <- simpleInterpolate n dt oldV newV stopE
          rec
            let nextE = flip pushAlways stopE $ const $ do
                  v <- sample . current $ resDyn -- start from last interpolated
                  return $ mkPredictStep v
            resDyn <- join <$> networkHold (pure interDyn) nextE
          return resDyn

  -- Initial dynamic without interpolation
  a <- sample . current $ origDyn
  initialDyn <- mkPredictStep a
  rec
    dynDyn <- networkHold (pure initialDyn) $ mkInterpStep interpDyn <$> updated origDyn
    let interpDyn = join dynDyn
  return interpDyn

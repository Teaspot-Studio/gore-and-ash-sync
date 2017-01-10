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

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictInterpolateM :: forall t m a b . (MonadAppHost t m, TimerMonad t m, Fractional a)
  => Int -- ^ Number of intermediate values
  -- | Time interval in which all interpolation have to be performed, depends on difference
  -- betwen old and new values of dynamic. Returned 'Nothing' means not interpolation needed,
  -- just replace with new value.
  -> (a -> m (Maybe NominalDiffTime))
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  -> Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> PushM t a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
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
            resDyn <- join <$> holdAppHost (pure interDyn) nextE
          return resDyn

  -- Initial dynamic without interpolation
  a <- sample . current $ origDyn
  initialDyn <- mkPredictStep a
  rec
    dynDyn <- holdAppHost (pure initialDyn) $ mkInterpStep interpDyn <$> updated origDyn
    let interpDyn = join dynDyn
  return interpDyn

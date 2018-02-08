-- A type of test case generators.
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies, DefaultSignatures, GADTs, FlexibleInstances, UndecidableInstances #-}
module QuickSpec.Testing where

import QuickSpec.Prop
import Control.Monad.Trans
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Reader

class Monad m => MonadTester testcase term m | m -> testcase term where
  test :: Prop term -> m (Maybe testcase)

  default test :: (MonadTrans t, MonadTester testcase term m', m ~ t m') => Prop term -> m (Maybe testcase)
  test = lift . test

instance MonadTester testcase term m => MonadTester testcase term (StateT s m)
instance MonadTester testcase term m => MonadTester testcase term (ReaderT r m)

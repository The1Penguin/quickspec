-- Testing conjectures using QuickCheck.
{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances, RecordWildCards, MultiParamTypeClasses, GeneralizedNewtypeDeriving #-}
module QuickSpec.Internal.Testing.QuickCheck where

import QuickSpec.Internal.Testing
import QuickSpec.Internal.Pruning
import QuickSpec.Internal.Prop
import Test.QuickCheck
import Test.QuickCheck.Gen
import Test.QuickCheck.Random
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Data.List
import System.Random hiding (uniform)
import QuickSpec.Internal.Terminal
import Data.Lens.Light

data Config =
  Config {
    cfg_num_tests :: Int,
    cfg_max_test_size :: Int,
    cfg_fixed_seed :: Maybe QCGen}
  deriving Show

lens_num_tests = lens cfg_num_tests (\x y -> y { cfg_num_tests = x })
lens_max_test_size = lens cfg_max_test_size (\x y -> y { cfg_max_test_size = x })
lens_fixed_seed = lens cfg_fixed_seed (\x y -> y { cfg_fixed_seed = x })

data Environment testcase term result =
  Environment {
    env_config :: Config,
    env_tests :: [testcase],
    env_eval :: testcase -> term -> Maybe result }

newtype Tester testcase term result m a =
  Tester (ReaderT (Environment testcase term result) m a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadTerminal, MonadPruner term' res')

instance MonadTrans (Tester testcase term result) where
  lift = Tester . lift

run ::
  Config -> Gen testcase -> (testcase -> term -> Maybe result) ->
  Tester testcase term result m a -> Gen (m a)
run config@Config{..} gen eval (Tester x) = do
  seed <- maybe arbitrary return cfg_fixed_seed
  let
    seeds = unfoldr (Just . split) seed
    n = fromIntegral (ceiling (fromIntegral cfg_num_tests * (1 - zeroProportion)))
    zeroes = cfg_num_tests - n
    k = max 1 cfg_max_test_size
    bias = 3
    -- Run this proportion of tests of size 0.
    zeroProportion = 0.01
    -- Bias tests towards smaller sizes.
    -- We do this by distributing the cube of the size uniformly.
    sizes =
      replicate zeroes 0 ++
      (reverse $ map (k -) $
       map (truncate . (** (1/fromInteger bias)) . fromIntegral) $
       uniform (toInteger n) (toInteger k^bias))
    tests = zipWith (unGen gen) seeds sizes
  return $ runReaderT x
    Environment {
      env_config = config,
      env_tests = tests,
      env_eval = eval }

-- uniform n k: generate a list of n integers which are distributed evenly between 0 and k-1.
uniform :: Integer -> Integer -> [Integer]
uniform n k =
  -- n `div` k: divide evenly as far as possible.
  concat [replicate (fromIntegral (n `div` k)) i | i <- [0..k-1]] ++
  -- The leftovers get distributed at equal intervals.
  [i * k `div` leftovers | i <- [0..leftovers-1]]
  where
    leftovers = n `mod` k

instance (Monad m, Eq result) => MonadTester testcase term (Tester testcase term result m) where
  test prop =
    Tester $ do
      env@Environment{..} <- ask
      return $! foldr testAnd TestPassed (map (quickCheckTest env prop) env_tests)
  retest testcase prop =
    Tester $ do
      env@Environment{..} <- ask
      return $! quickCheckTest env prop testcase

quickCheckTest :: Eq result =>
  Environment testcase term result -> Prop term -> testcase -> TestResult testcase
quickCheckTest Environment{env_config = Config{..}, ..} (lhs :=>: rhs) testcase =
  foldr testAnd (testEq rhs) (map testEq lhs)
  where
    testEq (t :=: u) =
      case (env_eval testcase t, env_eval testcase u) of
        (Just t, Just u)
          | t == u -> TestPassed
          | otherwise -> TestFailed testcase
        _ -> Untestable

{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE FlexibleContexts, PatternGuards #-}
module QuickSpec.Internal.Explore where

import QuickSpec.Internal.Explore.Polymorphic
import QuickSpec.Internal.Testing
import QuickSpec.Internal.Pruning
import QuickSpec.Internal.Term
import QuickSpec.Internal.Type
import QuickSpec.Internal.Utils
import QuickSpec.Internal.Prop
import QuickSpec.Internal.Terminal
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict
import Text.Printf
import Data.Semigroup(Semigroup(..))
import Data.List

newtype Enumerator a = Enumerator { enumerate :: Int -> [[a]] -> [a] }

-- N.B. order matters!
-- Later enumerators get to see terms which were generated by earlier ones.
instance Semigroup (Enumerator a) where
  e1 <> e2 = Enumerator $ \n tss ->
    let us = enumerate e1 n tss
        vs = enumerate e2 n (appendAt n us tss)
    in us ++ vs
instance Monoid (Enumerator a) where
  mempty = Enumerator (\_ _ -> [])
  mappend = (<>)

mapEnumerator :: ([a] -> [a]) -> Enumerator a -> Enumerator a
mapEnumerator f e =
  Enumerator $ \n tss ->
    f (enumerate e n tss)

filterEnumerator :: (a -> Bool) -> Enumerator a -> Enumerator a
filterEnumerator p e =
  mapEnumerator (filter p) e

enumerateConstants :: Sized a => [a] -> Enumerator a
enumerateConstants ts = Enumerator (\n _ -> [t | t <- ts, size t == n])

enumerateApplications :: Apply a => Enumerator a
enumerateApplications = Enumerator $ \n tss ->
    [ unPoly v
    | i <- [0..n],
      t <- tss !! i,
      u <- tss !! (n-i),
      Just v <- [tryApply (poly t) (poly u)] ]

filterUniverse :: Typed f => Universe -> Enumerator (Term f) -> Enumerator (Term f)
filterUniverse univ e =
  filterEnumerator (`usefulForUniverse` univ) e

sortTerms :: Ord b => (a -> b) -> Enumerator a -> Enumerator a
sortTerms measure e =
  mapEnumerator (sortBy' measure) e

quickSpec ::
  (Ord fun, Ord norm, Sized fun, Typed fun, Ord result, PrettyTerm fun,
  MonadPruner (Term fun) norm m, MonadTester testcase (Term fun) m, MonadTerminal m) =>
  (Prop (Term fun) -> m ()) ->
  (Term fun -> testcase -> Maybe result) ->
  Int -> Int -> (Type -> VariableUse) -> Universe -> Enumerator (Term fun) -> m ()
quickSpec present eval maxSize maxCommutativeSize use univ enum = do
  let
    state0 = initialState use univ (\t -> size t <= maxCommutativeSize) eval

    loop m n _ | m > n = return ()
    loop m n tss = do
      putStatus (printf "enumerating terms of size %d" m)
      let
        ts = enumerate (filterUniverse univ enum) m tss
        total = length ts
        consider (i, t) = do
          putStatus (printf "testing terms of size %d: %d/%d" m i total)
          res <- explore t
          putStatus (printf "testing terms of size %d: %d/%d" m i total)
          lift $ mapM_ present (result_props res)
          case res of
            Accepted _ -> return True
            Rejected _ -> return False
      us <- map snd <$> filterM consider (zip [1 :: Int ..] ts)
      clearStatus
      loop (m+1) n (appendAt m us tss)

  evalStateT (loop 0 maxSize (repeat [])) state0

----------------------------------------------------------------------
-- Functions that are not really to do with theory exploration,
-- but are useful for printing the output nicely.
----------------------------------------------------------------------

pPrintSignature :: (Pretty a, Typed a) => [a] -> Doc
pPrintSignature funs =
  text "== Functions ==" $$
  vcat (map pPrintDecl decls)
  where
    decls = [ (prettyShow f, pPrintType (typ f)) | f <- funs ]
    maxWidth = maximum (0:map (length . fst) decls)
    pad xs = nest (maxWidth - length xs) (text xs)
    pPrintDecl (name, ty) =
      pad name <+> text "::" <+> ty

-- Put an equation that defines the function f into the form f lhs = rhs.
-- An equation defines f if:
--   * it is of the form f lhs = rhs (or vice versa).
--   * f is not a background function.
--   * lhs only contains background functions.
--   * rhs does not contain f.
--   * all vars in rhs appear in lhs
prettyDefinition :: Eq fun => [fun] -> Prop (Term fun) -> Prop (Term fun)
prettyDefinition cons (lhs :=>: t :=: u)
  | Just (f, ts) <- defines u,
    f `notElem` funs t,
    null (usort (vars t) \\ vars ts) =
    lhs :=>: u :=: t
    -- In the case where t defines f, the equation is already oriented correctly
  | otherwise = lhs :=>: t :=: u
  where
    defines (Fun f :@: ts)
      | f `elem` cons,
        all (`notElem` cons) (funs ts) = Just (f, ts)
    defines _ = Nothing

-- Transform x+(y+z) = y+(x+z) into associativity, if + is commutative
prettyAC :: (Eq f, Eq norm) => (Term f -> norm) -> Prop (Term f) -> Prop (Term f)
prettyAC norm (lhs :=>: Fun f :@: [Var x, Fun f1 :@: [Var y, Var z]] :=: Fun f2 :@: [Var y1, Fun f3 :@: [Var x1, Var z1]])
  | f == f1, f1 == f2, f2 == f3,
    x == x1, y == y1, z == z1,
    x /= y, y /= z, x /= z,
    norm (Fun f :@: [Var x, Var y]) == norm (Fun f :@: [Var y, Var x]) =
      lhs :=>: Fun f :@: [Fun f :@: [Var x, Var y], Var z] :=: Fun f :@: [Var x, Fun f :@: [Var y, Var z]]
prettyAC _ prop = prop

-- Add a type signature when printing the equation x = y.
disambiguatePropType :: Prop (Term fun) -> Doc
disambiguatePropType (_ :=>: (Var x) :=: Var _) =
  text "::" <+> pPrintType (typ x)
disambiguatePropType _ = pPrintEmpty

-- Parser combinators.
-- Illustrates observational equality with polymorphic types.
{-# LANGUAGE DeriveDataTypeable, TypeOperators, ScopedTypeVariables, StandaloneDeriving, TypeApplications, TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses #-}
import Control.Monad
import Test.QuickCheck
import QuickSpec
import Data.List
import Text.ParserCombinators.ReadP
import Data.Constraint

deriving instance Typeable ReadP

-- Generate random parsers.
instance Arbitrary a => Arbitrary (ReadP a) where
  arbitrary = fmap readS_to_P arbReadS

arbReadS :: Arbitrary a => Gen (String -> [(a, String)])
arbReadS = fmap convert (liftM2 (,) (elements [0..5]) arbitrary)
  where
    convert (n, parse) xs = take n [(x, drop n xs) | (x, n) <- parse xs]

-- Observational equality for parsers.
instance Ord a => Observe String [(a, String)] (ReadP a) where
  observe input parser = sort (readP_to_S parser input)

peek :: ReadP Char
peek = do
  (x:_) <- look
  return x

main = qqSpec [
  inst (Sub Dict :: Arbitrary A :- Arbitrary (ReadP A)),
  inst (Sub Dict :: Ord A :- Observe String [(A, String)] (ReadP A)),

  background [
    con "return" (return :: A -> ReadP A),
    con "()" (),
    con "void" (void :: ReadP A -> ReadP ()),
    con ">>=" ((>>=) :: ReadP A -> (A -> ReadP B) -> ReadP B),
    con ">=>" ((>=>) :: (A -> ReadP B) -> (B -> ReadP C) -> A -> ReadP C) ],

  con "get" get,
  con "peek" peek,
  con "+++" ((+++) :: ReadP A -> ReadP A -> ReadP A),
  con "<++" ((<++) :: ReadP A -> ReadP A -> ReadP A),
  con "pfail" (pfail :: ReadP A),
  con "eof" eof 


  ,template "id" "?F(X)=X"
  ,template "fix-point" "?F(?X) = ?X"
  ,template "cancel" "?F(?G(X)) = ?F(X)"
  ,template "op-id-elem" "?F(X,?G) = X"
  ,template "commutative" "?F(X,Y) = ?F(Y,X)"
  ,template "op-commute" "?F(?G(X)) = ?G(?F(X))"
  ,template "2-distributive" "?F(?G(X,Y)) = ?G(?F(X),?F(Y))"
  ,template "analogy-distributive" "?F(?G(X),?G(Y)) = ?G(?H(X,Y))"
  ,template "associative-3" "?F(?F(X,Y),Z) = ?F(X,?F(Y,Z))"]

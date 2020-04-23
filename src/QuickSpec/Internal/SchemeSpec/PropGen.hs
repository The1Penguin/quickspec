module QuickSpec.Internal.SchemeSpec.PropGen where
import QuickSpec.Internal.Term
import QuickSpec.Internal.Prop
import QuickSpec.Internal.Haskell(Constant, con_type, con)
import QuickSpec.Internal.Type
import QuickSpec.Internal.Utils
import qualified QuickSpec.Internal.Explore.Polymorphic as Polymorphic

import Data.Maybe(isJust,catMaybes)
import Data.List(nub, subsequences)
import qualified Data.Map.Strict as Map
import Control.Monad(liftM)

import Debug.Trace

-----------------------------------------------------------------
-- Template-based term generation
-----------------------------------------------------------------
-- TODO: Renaming away from schema/scheme
-- TODO: Documentation
-- TODO: conditionals


-- Take template and a list of functions, return a list of properties generated by using
-- the functions to fill the holes of the template
schemaProps :: Prop (Term Constant) -> [Constant] -> [Constant] -> [Prop (Term Constant)]
schemaProps p allcs currcs =
  map (\(lt,rt) -> Polymorphic.regeneralise ([] :=>: (lt :=: rt))) $
  --catMaybes $ map doubleCheckVars $
  fillHoles (sides p) (map oneTypeVar allcs, map oneTypeVar currcs) -- TODO: reconsider where to use oneTypeVar
  where fillHoles :: (Term Constant, Term Constant) -> ([Constant], [Constant]) -> [(Term Constant, Term Constant)]
        fillHoles (lh, rh) (allc, currc) = concatMap (tryFill (lh,rh)) $ findFillings (lh,rh) (allc,currc)
        tryFill (t1,t2) m = case canFill m Map.empty t1 of
          Nothing -> []
          Just (t1', vts) -> case canFill m vts t2 of
            Nothing -> []
            Just (t2', _) ->
              if ((t1' /= t2') &&
                  ((isJust $ polyMgu pt1 pt2) ||
                   (isJust $ polyMgu pt2 pt1)
                  )
                 )
              then [(t1',t2')]
              else []
                 where pt1 = poly $ typ t1'
                       pt2 = poly $ typ t2'
-- Takes template and list of functions (divided into functions in current exploration scope and background functions),
-- returns a list of maps with hole names as keys and possible fillings for those holes as values
findFillings :: (Term Constant, Term Constant) ->([Constant], [Constant])-> [Map.Map String Constant]
findFillings s (allcs, currcs) = findFillings' currcs $ allFillings (allHoles s) allcs
  where findFillings' :: [Constant] -> [(MetaVar, [Constant])] -> [Map.Map String Constant]
        findFillings' curr l = map Map.fromList $
          filter (containsAny curr . map snd) (crossProd $ map fillings l)
          -- filter out those that have nothing from currcs
        fillings (mv, cons) = [(hole_id mv, c)| c <- cons]
        allFillings :: [MetaVar] -> [Constant] -> [(MetaVar, [Constant])]
        allFillings holes cons = map (allFeasibleFillings cons) holes
        allFeasibleFillings fs h = (h, filter (feasibleFill h) fs)
        feasibleFill :: MetaVar -> Constant -> Bool
        feasibleFill mv c = (isJust $ matchType (hole_ty mv) (con_type c))
                         && (typeArity (hole_ty mv) == typeArity (con_type c))
        containsAny xs ys = or $ map (flip elem ys) xs

allHoles :: (Term Constant, Term Constant) -> [MetaVar]
allHoles (t1,t2) = allHoles' t1 (allHoles' t2 [])
  where allHoles' (Hole mv) hs = if mv `notElem` hs then hs ++ [mv] else hs
        allHoles' (tl :$: tr) hs = allHoles' tl (allHoles' tr hs)
        allHoles' _ hs = hs

-- Try to fill the holes in the given term using the given map of fillings
canFill :: Map.Map String Constant -> Map.Map Int Type -> Term Constant -> Maybe (Term Constant, Map.Map Int Type)
canFill fillings vartypes (Hole mv) = case Map.lookup (hole_id mv) fillings of
  Nothing -> --trace ("no filling for hole " ++ (hole_id mv))
    Nothing
  Just f -> --trace ("filling hole " ++ (hole_id mv) ++ " with " ++ con_name f)
    Just (Fun f, vartypes)
canFill _ vartypes (Var v) = case Map.lookup vid vartypes of
  Nothing -> --trace ("variable: "++ prettyShow v)
    Just (Var v, Map.insert vid vtype vartypes)
  Just t -> --trace ("types: "++ prettyShow t ++ prettyShow vtype) $
            if (t == vtype)
            then Just (Var v, vartypes)
            else Nothing
  where vid = var_id v
        vtype = var_ty v
canFill _ vartypes (Fun f) = Just ((Fun f), vartypes)
canFill fillings vartypes (t1 :$: t2) = case canFill fillings vartypes t2 of
  Nothing -> --trace ("couldn't fill argument")
    Nothing
  Just (t2', vts) -> --trace ("filled argument: " ++ prettyShow t2') $
    case canFill fillings vts t1 of
      Nothing -> --trace ("couldn't fill applied")
        Nothing
      Just (t1', vts') -> --trace ("filled applied: "++ prettyShow t1') $
        case tryApply (poly t1') (poly t2') of
          Just v -> case checkVars Map.empty upv of
            Nothing -> Nothing
            Just _  -> Just $ (upv, vts')
            where upv = unPoly v
          Nothing -> Nothing

-- Make sure variables with same name also have the same type
checkVars :: Map.Map Int Type -> Term Constant -> Maybe (Map.Map Int Type)
checkVars vartypes (Var v) = case Map.lookup vid vartypes of
  Nothing -> Just (Map.insert vid vtype vartypes)
  Just t -> if t == vtype
    then Just vartypes
    else Nothing
  where vtype = var_ty v
        vid   = var_id v
checkVars vartypes (t1 :$: t2) = case checkVars vartypes t1 of
  Nothing -> Nothing
  Just vts -> checkVars vts t2
checkVars vartypes _ = Just vartypes

doubleCheckVars :: (Term Constant, Term Constant) -> Maybe (Term Constant, Term Constant)
doubleCheckVars p@(lt,rt) = case checkVars Map.empty lt of
  Nothing -> Nothing
  Just vts -> if isJust (checkVars vts rt) then Just p else Nothing
doubleCheckVars _ = Nothing
---------------------------------------------
-- Generalize templates
---------------------------------------------

-- TODO: add support for toggling expansion?

expandTemplate :: Int -> Prop (Term Constant) -> [(Prop (Term Constant), Bool)]
expandTemplate maxArity p = concatMap (partialApp maxArity) $ nestApp p

-- partialApp maxArity p returns all possible expansions of p using partial application
-- with up to maxArity variables
partialApp :: Int -> (Prop (Term Constant), Bool) -> [(Prop (Term Constant),Bool)]
partialApp maxArity p = nub [foldl partialExpand p c | c <- combos]
  where combos = crossProd [[(i,h)|i <- [0..maxArity]]| h <- (nub $ mvars $ fst p)]
-- TODO: Limit this expansion in some way?

-- Replace ?F with ?F X1 X2 ...
partialExpand :: (Prop (Term Constant), Bool) -> (Int,MetaVar) -> (Prop (Term Constant), Bool)
partialExpand (p,b) (k,h) | k <= typeArity (hole_ty h) = (p, b)
partialExpand (p,_) (k,h) | otherwise = (sprop (partialExpand' hname vnums lh,
                                           partialExpand' hname vnums rh), True)
  where (lh,rh) = sides p
        k' = k - (typeArity (hole_ty h)) - 1
        hname = hole_id h
        fnum = freeVar [lh,rh]
        vnums = [fnum..fnum+k']
partialExpand' hid vns x@(Hole mv) | hole_id mv == hid =
                                              (Hole $ MV {hole_id = hid, hole_ty = typeVar})
                                              :@: fvs
                                          | otherwise = x
          where fvs = [Var $ V typeVar vn | vn <- vns]
partialExpand' hid vns (t1 :$: t2) = (partialExpand' hid vns t1) :$: (partialExpand' hid vns t2)
partialExpand' _ _ x = x

nestApp :: Prop (Term Constant) -> [(Prop (Term Constant), Bool)]
nestApp p = (p, False) : [(appExpand p f, True) | f <- nub $ mvars p]
              --[foldl appExpand p fs| fs <- subsequences (nub $ mvars p)]

-- Replace ?F with ?F1 applied to ?F2
appExpand :: Prop (Term Constant) -> MetaVar -> Prop (Term Constant)
appExpand p m =  sprop (appExpand' h lh, appExpand' h rh)
  where h = hole_id m
        (lh,rh) = sides p
        appExpand' mv (x@(Hole mv') :@: ts) =
          if hole_id mv' == mv
          then (Hole $ MV {hole_id = mv ++ "1", hole_ty = typeVar})
               :$: ((Hole $ MV {hole_id = mv ++ "2", hole_ty = typeVar}) :@: ts')
          else x :@: ts'
          where ts' = map (appExpand' mv) ts
        appExpand' mv (t1 :$: t2) = (appExpand' mv t1 :$: appExpand' mv t2)
        appExpand' _ x = x

sides :: Prop a -> (a, a)
sides (_ :=>: (sl :=: sr)) = (sl,sr)

sprop :: (Term Constant, Term Constant) -> Prop (Term Constant)
sprop (l,r) = Polymorphic.regeneralise ([] :=>: (l :=: r))

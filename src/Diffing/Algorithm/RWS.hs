{-# LANGUAGE GADTs, DataKinds, RankNTypes, TypeOperators #-}
module Diffing.Algorithm.RWS
( rws
, Options(..)
, defaultOptions
, ComparabilityRelation
, FeatureVector
, defaultFeatureVectorDecorator
, featureVectorDecorator
, pqGramDecorator
, Gram(..)
, canCompareTerms
, equalTerms
) where

import Control.Applicative (empty)
import Control.Arrow ((&&&))
import Control.Monad.State.Strict
import Data.Align.Generic
import Data.Diff (DiffF(..), deleting, inserting, merge, replacing)
import Data.Foldable
import Data.Function ((&))
import Data.Functor.Classes
import Data.Functor.Foldable
import Data.Hashable
import Data.Ix
import qualified Data.KdMap.Static as KdMap
import Data.List (sortOn)
import Data.Maybe
import Data.Record
import Data.Semigroup hiding (First(..))
import Data.Term as Term
import Data.These
import Data.Traversable
import Diffing.Algorithm.RWS.FeatureVector
import Diffing.Algorithm.SES

type Label f fields label = forall b. TermF f (Record fields) b -> label

-- | A relation on 'Term's, guaranteed constant-time in the size of the 'Term' by parametricity.
--
--   This is used both to determine whether two root terms can be compared in O(1), and, recursively, to determine whether two nodes are equal in O(n); thus, comparability is defined s.t. two terms are equal if they are recursively comparable subterm-wise.
type ComparabilityRelation syntax ann1 ann2 = forall a b. TermF syntax ann1 a -> TermF syntax ann2 b -> Bool

rws :: (Foldable syntax, Functor syntax, GAlign syntax)
    => ComparabilityRelation syntax (Record (FeatureVector ': fields1)) (Record (FeatureVector ': fields2))
    -> (Term syntax (Record (FeatureVector ': fields1)) -> Term syntax (Record (FeatureVector ': fields2)) -> Bool)
    -> [Term syntax (Record (FeatureVector ': fields1))]
    -> [Term syntax (Record (FeatureVector ': fields2))]
    -> EditScript (Term syntax (Record (FeatureVector ': fields1))) (Term syntax (Record (FeatureVector ': fields2)))
rws _          _          as [] = This <$> as
rws _          _          [] bs = That <$> bs
rws canCompare _          [a] [b] = if canCompareTerms canCompare a b then [These a b] else [That b, This a]
rws canCompare equivalent as bs
  = ses equivalent as bs
  & mapContiguous [] []
  where Options{..} = defaultOptions

        -- Map contiguous sequences of unmapped terms separated by SES-mapped equivalencies.
        mapContiguous as bs [] = mapSimilar (reverse as) (reverse bs)
        mapContiguous as bs (first : rest) = case first of
          This  a   -> mapContiguous (a : as)      bs  rest
          That    b -> mapContiguous      as  (b : bs) rest
          These _ _ -> mapSimilar (reverse as) (reverse bs) <> (first : mapContiguous [] [] rest)

        -- Map comparable, mutually similar terms, inserting & deleting surrounding terms.
        mapSimilar as' bs' = go as bs
          where go as [] = This . snd <$> as
                go [] bs = That . snd <$> bs
                go [a] [b] | canCompareTerms canCompare (snd a) (snd b) = [These (snd a) (snd b)]
                           | otherwise = [That (snd b), This (snd a)]
                go as@((i, _) : _) ((j, b) : restB) =
                  fromMaybe (That b : go as restB) $ do
                    -- Look up the most similar term to b near i.
                    (i', a) <- mostSimilarMatching (\ i' a -> inRange (i, i + optionsLookaheadPlaces) i' && canCompareTerms canCompare a b) kdMapA b
                    -- Look up the most similar term to a near j.
                    (j', _) <- mostSimilarMatching (\ j' b -> inRange (j, j + optionsLookaheadPlaces) j' && canCompareTerms canCompare a b) kdMapB a
                    -- Fail out if there’s a better match for a nearby.
                    guard (j == j')
                    -- Delete any elements of as before the selected element.
                    let (deleted, _ : restA) = span ((< i') . fst) as
                    pure $! (This . snd <$> deleted) <> (These a b : go restA restB)
                (as, bs) = (zip [0..] as', zip [0..] bs')
                (kdMapA, kdMapB) = (toKdMap as, toKdMap bs)

        -- Find the most similar term matching a predicate, if any.
        --
        -- RWS can produce false positives in the case of e.g. hash collisions. Therefore, we find the _l_ nearest candidates, filter out any which don’t match the predicate, and select the minimum of the remaining by (a constant-time approximation of) edit distance.
        --
        -- cf §4.2 of RWS-Diff
        mostSimilarMatching isEligible tree term = listToMaybe (sortOn (editDistanceUpTo optionsNodeComparisons term . snd) candidates)
          where candidates = filter (uncurry isEligible) (snd <$> KdMap.kNearest tree optionsMaxSimilarTerms (rhead (termAnnotation term)))

data Options = Options
  { optionsLookaheadPlaces :: {-# UNPACK #-} !Int -- ^ How many places ahead should we look for similar terms?
  , optionsMaxSimilarTerms :: {-# UNPACK #-} !Int -- ^ The maximum number of similar terms to consider.
  , optionsNodeComparisons :: {-# UNPACK #-} !Int -- ^ The number of nodes to compare when selecting the most similar term.
  }

defaultOptions :: Options
defaultOptions = Options
  { optionsLookaheadPlaces = 0
  , optionsMaxSimilarTerms = 2
  , optionsNodeComparisons = 10
  }

defaultP, defaultQ :: Int
defaultP = 0
defaultQ = 3


toKdMap :: Functor syntax => [(Int, Term syntax (Record (FeatureVector ': fields)))] -> KdMap.KdMap Double FeatureVector (Int, Term syntax (Record (FeatureVector ': fields)))
toKdMap = KdMap.build unFV . fmap (rhead . termAnnotation . snd &&& id)

-- | A `Gram` is a fixed-size view of some portion of a tree, consisting of a `stem` of _p_ labels for parent nodes, and a `base` of _q_ labels of sibling nodes. Collectively, the bag of `Gram`s for each node of a tree (e.g. as computed by `pqGrams`) form a summary of the tree.
data Gram label = Gram { stem :: [Maybe label], base :: [Maybe label] }
 deriving (Eq, Show)

-- | Annotates a term with a feature vector at each node, using the default values for the p, q, and d parameters.
defaultFeatureVectorDecorator
 :: (Hashable label, Traversable f)
 => Label f fields label
 -> Term f (Record fields)
 -> Term f (Record (FeatureVector ': fields))
defaultFeatureVectorDecorator getLabel = featureVectorDecorator . pqGramDecorator getLabel defaultP defaultQ

-- | Annotates a term with a feature vector at each node, parameterized by stem length, base width, and feature vector dimensions.
featureVectorDecorator :: (Foldable f, Functor f, Hashable label) => Term f (Record (label ': fields)) -> Term f (Record (FeatureVector ': fields))
featureVectorDecorator = cata (\ (In (label :. rest) functor) ->
  termIn (foldl' addSubtermVector (unitVector (hash label)) functor :. rest) functor)
  where addSubtermVector v term = addVectors v (rhead (termAnnotation term))

-- | Annotates a term with the corresponding p,q-gram at each node.
pqGramDecorator
  :: Traversable f
  => Label f fields label -- ^ A function computing the label from an arbitrary unpacked term. This function can use the annotation and functor’s constructor, but not any recursive values inside the functor (since they’re held parametric in 'b').
  -> Int -- ^ 'p'; the desired stem length for the grams.
  -> Int -- ^ 'q'; the desired base length for the grams.
  -> Term f (Record fields) -- ^ The term to decorate.
  -> Term f (Record (Gram label ': fields)) -- ^ The decorated term.
pqGramDecorator getLabel p q = cata algebra
  where
    algebra term = let label = getLabel term in
      termIn (gram label :. termFAnnotation term) (assignParentAndSiblingLabels (termFOut term) label)
    gram label = Gram (padToSize p []) (padToSize q (pure (Just label)))
    assignParentAndSiblingLabels functor label = (`evalState` (replicate (q `div` 2) Nothing <> siblingLabels functor)) (for functor (assignLabels label))

    assignLabels :: Functor f
                 => label
                 -> Term f (Record (Gram label ': fields))
                 -> State [Maybe label] (Term f (Record (Gram label ': fields)))
    assignLabels label (Term.Term (In (gram :. rest) functor)) = do
      labels <- get
      put (drop 1 labels)
      pure $! termIn (gram { stem = padToSize p (Just label : stem gram), base = padToSize q labels } :. rest) functor
    siblingLabels :: Traversable f => f (Term f (Record (Gram label ': fields))) -> [Maybe label]
    siblingLabels = foldMap (base . rhead . termAnnotation)
    padToSize n list = take n (list <> repeat empty)

-- | Test the comparability of two root 'Term's in O(1).
canCompareTerms :: ComparabilityRelation syntax ann1 ann2 -> Term syntax ann1 -> Term syntax ann2 -> Bool
canCompareTerms canCompare t1 t2 = canCompare (unTerm t1) (unTerm t2)

-- | Recursively test the equality of two 'Term's in O(n).
equalTerms :: Eq1 syntax => ComparabilityRelation syntax ann1 ann2 -> Term syntax ann1 -> Term syntax ann2 -> Bool
equalTerms canCompare = go
  where go a b = canCompareTerms canCompare a b && liftEq go (termOut a) (termOut b)


-- | Return an edit distance between two terms, up to a certain depth.
--
--   Computes a constant-time approximation to the edit distance of a diff. This is done by comparing at most _m_ nodes, & assuming the rest are zero-cost.
editDistanceUpTo :: (GAlign syntax, Foldable syntax, Functor syntax) => Int -> Term syntax ann1 -> Term syntax ann2 -> Int
editDistanceUpTo m a b = diffCost m (approximateDiff a b)
  where diffCost = flip . cata $ \ diff m -> case diff of
          _ | m <= 0 -> 0
          Merge body -> sum (fmap ($ pred m) body)
          body -> succ (sum (fmap ($ pred m) body))
        approximateDiff a b = maybe (replacing a b) (merge (termAnnotation a, termAnnotation b)) (galignWith (Just . these deleting inserting approximateDiff) (termOut a) (termOut b))


-- Instances

instance Hashable label => Hashable (Gram label) where
  hashWithSalt _ = hash
  hash gram = hash (stem gram <> base gram)
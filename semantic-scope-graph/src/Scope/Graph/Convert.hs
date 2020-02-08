{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Scope.Graph.Convert
  ( ToScopeGraph (..)
  , Result (..)
  , todo
  , complete
  ) where

import           Analysis.Name (Name)
import           Control.Effect.ScopeGraph
import           Control.Effect.State
import           Data.List.NonEmpty
import qualified Data.ScopeGraph as ScopeGraph
import           Data.Typeable
import           Source.Loc

class Typeable t => ToScopeGraph t where
  scopeGraph ::
    ( Has ScopeGraph sig m
    , Has (State (ScopeGraph.ScopeGraph Name)) sig m
    )
    => t Loc
    -> m Result

data Result
  = Complete
  | Todo (NonEmpty String)
    deriving (Eq, Show, Ord)

instance Semigroup Result where
  Complete <> Complete = Complete
  Todo a <> Todo b     = Todo (a <> b)
  a <> Complete        = a
  Complete <> a        = a

instance Monoid Result where mempty = Complete

todo :: (Show a, Applicative m) => a -> m Result
todo = pure . Todo . pure . show

complete :: Applicative m => m Result
complete = pure Complete

module Line where

-- | A line of items or an empty line.
newtype Line a = Line { unLine :: [a] }
  deriving (Eq, Foldable, Functor, Show, Traversable)

isEmpty :: Line a -> Bool
isEmpty = null . unLine

-- | Transform the line by applying a function to a list of all the items in the
-- | line.
wrapLineContents :: ([a] -> b) -> Line a -> Line b
wrapLineContents _ (Line []) = mempty
wrapLineContents transform line = Line [ transform (unLine line) ]

-- | Return the first item in the Foldable, or Nothing if it's empty.
maybeFirst :: Foldable f => f a -> Maybe a
maybeFirst = foldr (const . Just) Nothing

-- | Is the final element of a line matched by the given predicate?
isOpenLineBy :: (a -> Bool) -> Line a -> Bool
isOpenLineBy f (Line elements) = null elements || f (last elements)

-- | Coalesce a pair of lines if the first is matched by a predicate.
coalesceLinesBy :: (a -> Bool) -> Line a -> Line a -> [Line a]
coalesceLinesBy f line nextLine | isOpenLineBy f line = [line `mappend` nextLine]
coalesceLinesBy _ line nextLine = [line, nextLine]

instance Applicative Line where
  pure = Line . pure
  a <*> b = Line (unLine a <*> unLine b)

instance Monoid (Line a) where
  mempty = Line []
  mappend xs ys = Line (unLine xs `mappend` unLine ys)

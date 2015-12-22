module Split where

import Prelude hiding (div, head, span)
import Diff
import Patch
import Term
import Syntax
import Control.Comonad.Cofree
import Range
import Control.Monad.Free
import Data.ByteString.Lazy.Internal
import Text.Blaze.Html
import Text.Blaze.Html5 hiding (map)
import qualified Text.Blaze.Html5.Attributes as A
import Text.Blaze.Html.Renderer.Utf8
import qualified OrderedMap as Map
import Data.Monoid
import qualified Data.Set as Set
import Data.List (intercalate)

type ClassName = String

data HTML =
  Break
  | Text String
  | Span (Maybe ClassName) String
  | Ul (Maybe ClassName) [HTML]
  | Dl (Maybe ClassName) [HTML]
  | Div (Maybe ClassName) [HTML]
  | Dt String
  deriving (Show, Eq)

classifyMarkup :: Maybe ClassName -> Markup -> Markup
classifyMarkup (Just className) element = element ! A.class_ (stringValue className)
classifyMarkup _ element = element

toLi :: HTML -> Markup
toLi (Text s) = string s
toLi e = li $ toMarkup e

toDd :: HTML -> Markup
toDd (Text s) = string s
toDd e = dd $ toMarkup e

instance ToMarkup HTML where
  toMarkup Break = br
  toMarkup (Text s) = string s
  toMarkup (Span className s) = classifyMarkup className . span $ string s
  toMarkup (Ul className children) = classifyMarkup className . ul $ mconcat (toLi <$> children)
  toMarkup (Dl className children) = classifyMarkup className . dl $ mconcat (toDd <$> children)
  toMarkup (Div className children) = classifyMarkup className . div $ mconcat (toMarkup <$> children)
  toMarkup (Dt key) = dt $ string key

split :: Diff a Info -> String -> String -> IO ByteString
split diff left right = return . renderHtml
  . docTypeHtml
    . ((head $ link ! A.rel (stringValue "stylesheet") ! A.href (stringValue "style.css")) <>)
    . body
      . (table ! A.class_ (stringValue "diff")) $
        ((colgroup $ (col ! A.width (stringValue . show $ columnWidth)) <> col <> (col ! A.width (stringValue . show $ columnWidth)) <> col) <>)
        . mconcat $ toMarkup <$> reverse numbered
  where
    rows = toRenderable <$> fst (splitDiffByLines diff (0, 0) (left, right))
    toRenderable (Row a b) = Row (Renderable . (,) left . split fst <$> a) (Renderable . (,) right . split snd <$> b)
    numbered = foldl numberRows [] rows
    maxNumber = case numbered of
      [] -> 0
      ((x, _, y, _) : _) -> max x y

    digits :: Int -> Int
    digits n = let base = 10 :: Int in
      ceiling (logBase (fromIntegral base) (fromIntegral n) :: Double)

    split :: (forall b. (b, b) -> b) -> Free (Annotated leaf (annotation, annotation)) (Patch (Term leaf annotation)) -> SplitDiff leaf annotation
    split which (Pure patch) = Pure $ case which (before patch, after patch) of
      Just term -> term
      _ -> error "`split` expects to be called with a total selector for patches"
    split which (Free (Annotated infos syntax)) = Free . Annotated (which infos) $ split which <$> syntax

    columnWidth = max (20 + digits maxNumber * 8) 40

    numberRows :: [(Int, Line a, Int, Line a)] -> Row a -> [(Int, Line a, Int, Line a)]
    numberRows [] (Row EmptyLine EmptyLine) = []
    numberRows [] (Row left@(Line _) EmptyLine) = [(1, left, 0, EmptyLine)]
    numberRows [] (Row EmptyLine right@(Line _)) = [(0, EmptyLine, 1, right)]
    numberRows [] (Row left right) = [(1, left, 1, right)]
    numberRows rows@((leftCount, _, rightCount, _):_) (Row EmptyLine EmptyLine) = (leftCount, EmptyLine, rightCount, EmptyLine):rows
    numberRows rows@((leftCount, _, rightCount, _):_) (Row left@(Line _) EmptyLine) = (leftCount + 1, left, rightCount, EmptyLine):rows
    numberRows rows@((leftCount, _, rightCount, _):_) (Row EmptyLine right@(Line _)) = (leftCount, EmptyLine, rightCount + 1, right):rows
    numberRows rows@((leftCount, _, rightCount, _):_) (Row left right) = (leftCount + 1, left, rightCount + 1, right):rows


data Row a = Row { unLeft :: Line a, unRight :: Line a }
  deriving (Eq, Functor)

instance Show a => Show (Row a) where
  show (Row left right) = "\n" ++ show left ++ " | " ++ show right

instance ToMarkup a => ToMarkup (Int, Line a, Int, Line a) where
  toMarkup (m, left, n, right) = tr $ toMarkup (m, left) <> toMarkup (n, right) <> string "\n"

instance ToMarkup a => ToMarkup (Int, Line a) where
  toMarkup (_, line@EmptyLine) = numberTd "" <> toMarkup line <> string "\n"
  -- toMarkup (num, line@(Line _)) = td (string $ show num) ! A.class_ (stringValue "blob-num blob-num-replacement") <> toMarkup line <> string "\n"
  toMarkup (num, line@(Line _)) = numberTd (show num) <> toMarkup line <> string "\n"

numberTd :: String -> Html
numberTd "" = td mempty ! A.class_ (stringValue "blob-num blob-num-empty empty-cell")
numberTd s = td (string s) ! A.class_ (stringValue "blob-num")

codeTd :: Maybe Html -> Html
codeTd Nothing = td mempty ! A.class_ (stringValue "blob-code blob-code-empty empty-cell")
-- codeTd True (Just el) = td el ! A.class_ (stringValue "blob-code blob-code-replacement")
codeTd (Just el) = td el ! A.class_ (stringValue "blob-code")

instance ToMarkup a => ToMarkup (Line a) where
  toMarkup EmptyLine = codeTd Nothing
  toMarkup (Line html) = codeTd . Just . mconcat $ toMarkup <$> html

data Line a =
  Line [a]
  | EmptyLine
  deriving (Eq, Functor)

unLine :: Line a -> [a]
unLine EmptyLine = []
unLine (Line elements) = elements

instance Show a => Show (Line a) where
  show (Line elements) = "[" ++ intercalate ", " (show <$> elements) ++ "]"
  show EmptyLine = "EmptyLine"

instance Monoid (Line a) where
  mempty = EmptyLine
  mappend EmptyLine line = line
  mappend line EmptyLine = line
  mappend (Line xs) (Line ys) = Line (xs <> ys)

-- | A diff with only one side’s annotations.
type SplitDiff leaf annotation = Free (Annotated leaf annotation) (Term leaf annotation)

newtype Renderable a = Renderable (String, a)

instance ToMarkup f => ToMarkup (Renderable (Info, Syntax a (f, Range))) where
  toMarkup (Renderable (source, (Info range categories, syntax))) = classifyMarkup (classify categories) $ case syntax of
    Leaf _ -> span . string $ substring range source
    Indexed children -> ul . mconcat $ contentElements children
    Fixed children -> ul . mconcat $ contentElements children
    Keyed children -> dl . mconcat $ contentElements children
    where markupForSeparatorAndChild :: ToMarkup f => ([Markup], Int) -> (f, Range) -> ([Markup], Int)
          markupForSeparatorAndChild (rows, previous) child = (rows ++ [ string (substring (Range previous $ start $ snd child) source), toMarkup $ fst child ], end $ snd child)

          contentElements children = let (elements, previous) = foldl markupForSeparatorAndChild ([], start range) children in
            elements ++ [ string $ substring (Range previous $ end range) source ]

instance ToMarkup (Renderable (Term a Info)) where
  toMarkup (Renderable (source, term)) = fst $ cata (\ info@(Info range _) syntax -> (toMarkup $ Renderable (source, (info, syntax)), range)) term

instance ToMarkup (Renderable (SplitDiff a Info)) where
  toMarkup (Renderable (source, diff)) = fst $ iter (\ (Annotated info@(Info range _) syntax) -> (toMarkup $ Renderable (source, (info, syntax)), range)) $ toMarkupAndRange <$> diff
    where toMarkupAndRange :: Term a Info -> (Markup, Range)
          toMarkupAndRange term@(Info range _ :< _) = ((div ! A.class_ (stringValue "patch")) . toMarkup $ Renderable (source, term), range)

splitDiffByLines :: Diff a Info -> (Int, Int) -> (String, String) -> ([Row (SplitDiff a Info)], (Range, Range))
splitDiffByLines diff (prevLeft, prevRight) sources = case diff of
  Free (Annotated annotation syntax) -> (splitAnnotatedByLines sources (ranges annotation) (categories annotation) syntax, ranges annotation)
  Pure (Insert term) -> let (lines, range) = splitTermByLines term (snd sources) in
    (Row EmptyLine . fmap Pure <$> lines, (Range prevLeft prevLeft, range))
  Pure (Delete term) -> let (lines, range) = splitTermByLines term (fst sources) in
    (flip Row EmptyLine . fmap Pure <$> lines, (range, Range prevRight prevRight))
  Pure (Replace leftTerm rightTerm) -> let (leftLines, leftRange) = splitTermByLines leftTerm (fst sources)
                                           (rightLines, rightRange) = splitTermByLines rightTerm (snd sources) in
                                           (zipWithDefaults Row EmptyLine EmptyLine (fmap Pure <$> leftLines) (fmap Pure <$> rightLines), (leftRange, rightRange))
  where categories (Info _ left, Info _ right) = (left, right)
        ranges (Info left _, Info right _) = (left, right)

diffToRows :: Diff a Info -> (Int, Int) -> String -> String -> ([Row HTML], (Range, Range))
diffToRows (Free annotated@(Annotated (Info left _, Info right _) _)) _ before after = (annotatedToRows annotated before after, (left, right))
diffToRows (Pure (Insert term)) (previousIndex, _) _ after = (rowWithInsertedLine <$> afterLines, (Range previousIndex previousIndex, range))
  where
    (afterLines, range) = termToLines term after
    rowWithInsertedLine (Line elements) = Row EmptyLine $ Line [ Div (Just "insert") elements ]
    rowWithInsertedLine line = Row line line
diffToRows (Pure (Delete term)) (_, previousIndex) before _ = (rowWithDeletedLine <$> lines, (range, Range previousIndex previousIndex))
  where
    (lines, range) = termToLines term before
    rowWithDeletedLine (Line elements) = Row (Line [ Div (Just "delete") elements ]) EmptyLine
    rowWithDeletedLine line = Row line line
diffToRows (Pure (Replace a b)) _ before after = (replacedRows, (leftRange, rightRange))
  where
    replacedRows = zipWithMaybe rowFromMaybeRows (replace <$> leftElements) (replace <$> rightElements)
    replace = Div (Just "replace") . unLine
    (leftElements, leftRange) = termToLines a before
    (rightElements, rightRange) = termToLines b after

-- | Takes a term and a source and returns a list of lines and their range within source.
splitTermByLines :: Term a Info -> String -> ([Line (Term a Info)], Range)
splitTermByLines (Info range categories :< syntax) source = flip (,) range $ case syntax of
  Leaf a -> contextLines (:< Leaf a) range categories source
  Indexed children -> adjoinChildLines Indexed children
  Fixed children -> adjoinChildLines Fixed children
  Keyed children -> adjoinChildLines Keyed children
  where adjoin = reverse . foldl (adjoinLinesBy $ openTerm source) []
        adjoinChildLines constructor children = let (lines, previous) = foldl (childLines $ constructor mempty) ([], start range) children in
          adjoin $ lines ++ contextLines (:< constructor mempty) (Range previous $ end range) categories source

        childLines constructor (lines, previous) child = let (childLines, childRange) = splitTermByLines child source in
          (adjoin $ lines ++ contextLines (:< constructor) (Range previous $ start childRange) categories source ++ childLines, end childRange)

-- | Takes a term and a source and returns a list of lines and their range within source.
termToLines :: Term a Info -> String -> ([Line HTML], Range)
termToLines (Info range categories :< syntax) source = (rows syntax, range)
  where
    rows (Leaf _) = adjoin $ Line . (:[]) <$> elements
    rows (Indexed i) = rewrapLineContentsIn (Ul $ classify categories) <$> childLines i
    rows (Fixed f) = rewrapLineContentsIn (Ul $ classify categories) <$> childLines f
    rows (Keyed k) = rewrapLineContentsIn (Dl $ classify categories) <$> childLines k

    adjoin = reverse . foldl (adjoinLinesBy openElement) []
    rewrapLineContentsIn f (Line elements) = Line [ f elements ]
    rewrapLineContentsIn _ EmptyLine = EmptyLine
    contextLines r s = Line . (:[]) <$> textElements r s
    childLines i = let (lines, previous) = foldl sumLines ([], start range) i in
      adjoin $ lines ++ contextLines (Range previous (end range)) source
    sumLines (lines, previous) child = let (childLines, childRange) = termToLines child source in
      (adjoin $ lines ++ contextLines (Range previous $ start childRange) source ++ childLines, end childRange)
    elements = elementAndBreak (Span $ classify categories) =<< actualLines (substring range source)

splitAnnotatedByLines :: (String, String) -> (Range, Range) -> (Set.Set Category, Set.Set Category) -> Syntax a (Diff a Info) -> [Row (SplitDiff a Info)]
splitAnnotatedByLines sources ranges categories syntax = case syntax of
  Leaf a -> contextRows (Leaf a) ranges categories sources
  Indexed children -> adjoinChildRows Indexed children
  Fixed children -> adjoinChildRows Fixed children
  Keyed children -> adjoinChildRows Keyed children
  where contextRows constructor ranges categories sources = zipWithDefaults Row EmptyLine EmptyLine (contextLines (Free . (`Annotated` constructor)) (fst ranges) (fst categories) (fst sources)) (contextLines (Free . (`Annotated` constructor)) (snd ranges) (snd categories) (snd sources))

        adjoin = reverse . foldl (adjoinRowsBy (openDiff $ fst sources) (openDiff $ snd sources)) []
        adjoinChildRows constructor children = let (rows, previous) = foldl (childRows $ constructor mempty) ([], starts ranges) children in
          adjoin $ rows ++ contextRows (constructor mempty) (makeRanges previous (ends ranges)) categories sources

        childRows constructor (rows, previous) child = let (childRows, childRanges) = splitDiffByLines child previous sources in
          (adjoin $ rows ++ contextRows constructor (makeRanges previous (starts childRanges)) categories sources ++ childRows, ends childRanges)

        starts (left, right) = (start left, start right)
        ends (left, right) = (end left, end right)
        makeRanges (leftStart, rightStart) (leftEnd, rightEnd) = (Range leftStart leftEnd, Range rightStart rightEnd)
        duplicate x = (x, x)

-- | Given an Annotated and before/after strings, returns a list of `Row`s representing the newline-separated diff.
annotatedToRows :: Annotated a (Info, Info) (Diff a Info) -> String -> String -> [Row HTML]
annotatedToRows (Annotated (Info left leftCategories, Info right rightCategories) syntax) before after = rows syntax
  where
    rows (Leaf _) = zipWithMaybe rowFromMaybeRows leftElements rightElements
    rows (Indexed i) = rewrapRowContentsIn Ul <$> childRows i
    rows (Fixed f) = rewrapRowContentsIn Ul <$> childRows f
    rows (Keyed k) = rewrapRowContentsIn Dl <$> childRows (snd <$> Map.toList k)

    leftElements = elementAndBreak (Span $ classify leftCategories) =<< actualLines (substring left before)
    rightElements = elementAndBreak (Span $ classify rightCategories) =<< actualLines (substring right after)

    wrap _ EmptyLine = EmptyLine
    wrap f (Line elements) = Line [ f elements ]
    rewrapRowContentsIn f (Row left right) = Row (wrap (f $ classify leftCategories) left) (wrap (f $ classify rightCategories) right)
    ranges = (left, right)
    sources = (before, after)
    childRows = appendRemainder . foldl sumRows ([], starts ranges)
    appendRemainder (rows, previousIndices) = reverse . foldl (adjoinRowsBy openElement openElement) [] $ rows ++ contextRows (ends ranges) previousIndices sources
    starts (left, right) = (start left, start right)
    ends (left, right) = (end left, end right)
    sumRows (rows, previousIndices) child = let (childRows, childRanges) = diffToRows child previousIndices before after in
      (rows ++ contextRows (starts childRanges) previousIndices sources ++ childRows, ends childRanges)

contextLines :: (Info -> a) -> Range -> Set.Set Category -> String -> [Line a]
contextLines constructor range categories source = Line . (:[]) . constructor . (`Info` categories) <$> actualLineRanges range source

contextRows :: (Int, Int) -> (Int, Int) -> (String, String) -> [Row HTML]
contextRows childIndices previousIndices sources = zipWithMaybe rowFromMaybeRows leftElements rightElements
  where
    leftElements = textElements (Range (fst previousIndices) (fst childIndices)) (fst sources)
    rightElements = textElements (Range (snd previousIndices) (snd childIndices)) (snd sources)

elementAndBreak :: (String -> HTML) -> String -> [HTML]
elementAndBreak _ "" = []
elementAndBreak _ "\n" = [ Break ]
elementAndBreak constructor x | '\n' <- last x = [ constructor $ init x, Break ]
elementAndBreak constructor x = [ constructor x ]

textElements :: Range -> String -> [HTML]
textElements range source = elementAndBreak Text =<< actualLines s
  where s = substring range source

rowFromMaybeRows :: Maybe a -> Maybe a -> Row a
rowFromMaybeRows a b = Row (maybe EmptyLine (Line . (:[])) a) (maybe EmptyLine (Line . (:[])) b)

maybeLast :: Foldable f => f a -> Maybe a
maybeLast = foldl (flip $ const . Just) Nothing

adjoinRowsBy :: (a -> Maybe a) -> (a -> Maybe a) -> [Row a] -> Row a -> [Row a]
adjoinRowsBy _ _ [] row = [row]

adjoinRowsBy f g rows (Row left' right') | Just _ <- openLineBy f $ unLeft <$> rows, Just _ <- openLineBy g $ unRight <$> rows = zipWith Row lefts rights
  where lefts = adjoinLinesBy f (unLeft <$> rows) left'
        rights = adjoinLinesBy g (unRight <$> rows) right'

adjoinRowsBy f _ rows (Row left' right') | Just _ <- openLineBy f $ unLeft <$> rows = case right' of
  EmptyLine -> rest
  _ -> Row EmptyLine right' : rest
  where rest = zipWith Row lefts rights
        lefts = adjoinLinesBy f (unLeft <$> rows) left'
        rights = unRight <$> rows

adjoinRowsBy _ g rows (Row left' right') | Just _ <- openLineBy g $ unRight <$> rows = case left' of
  EmptyLine -> rest
  _ -> Row left' EmptyLine : rest
  where rest = zipWith Row lefts rights
        lefts = unLeft <$> rows
        rights = adjoinLinesBy g (unRight <$> rows) right'

adjoinRowsBy _ _ rows row = row : rows

openElement :: HTML -> Maybe HTML
openElement Break = Nothing
openElement (Ul _ elements) = openElement =<< maybeLast elements
openElement (Dl _ elements) = openElement =<< maybeLast elements
openElement (Div _ elements) = openElement =<< maybeLast elements
openElement h = Just h

openRange :: String -> Range -> Maybe Range
openRange source range = case (source !!) <$> maybeLastIndex range of
  Just '\n' -> Nothing
  _ -> Just range

openTerm :: String -> Term a Info -> Maybe (Term a Info)
openTerm source term@(Info range _ :< _) = const term <$> openRange source range

openDiff :: String -> SplitDiff a Info -> Maybe (SplitDiff a Info)
openDiff source diff@(Free (Annotated (Info range _) _)) = const diff <$> openRange source range
openDiff source diff@(Pure term) = const diff <$> openTerm source term

openDiff2 :: (forall b. (b, b) -> b) -> (String, String) -> Diff a Info -> Maybe (Diff a Info)
openDiff2 which sources diff@(Free (Annotated (Info range1 _, Info range2 _) _)) = const diff <$> openRange (which sources) (which (range1, range2))
openDiff2 which sources diff@(Pure patch) = const diff . openTerm (which sources) <$> which (before patch, after patch)

openLineBy :: (a -> Maybe a) -> [Line a] -> Maybe (Line a)
openLineBy _ [] = Nothing
openLineBy f (EmptyLine : rest) = openLineBy f rest
openLineBy f (line : _) = const line <$> (f =<< maybeLast (unLine line))

adjoinLinesBy :: (a -> Maybe a) -> [Line a] -> Line a -> [Line a]
adjoinLinesBy _ [] line = [line]
adjoinLinesBy f (EmptyLine : xs) line | Just _ <- openLineBy f xs = EmptyLine : adjoinLinesBy f xs line
adjoinLinesBy f (prev:rest) line | Just _ <- openLineBy f [ prev ] = (prev <> line) : rest
adjoinLinesBy _ lines line = line : lines

zipWithMaybe :: (Maybe a -> Maybe b -> c) -> [a] -> [b] -> [c]
zipWithMaybe f a b = zipWithDefaults f Nothing Nothing (Just <$> a) (Just <$> b)

zipWithDefaults :: (a -> b -> c) -> a -> b -> [a] -> [b] -> [c]
zipWithDefaults f da db a b = take (max (length a) (length b)) $ zipWith f (a ++ repeat da) (b ++ repeat db)

classify :: Set.Set Category -> Maybe ClassName
classify categories = ("category-" ++) <$> maybeLast categories

actualLines :: String -> [String]
actualLines "" = [""]
actualLines lines = case break (== '\n') lines of
  (l, lines') -> case lines' of
                      [] -> [ l ]
                      _:lines' -> (l ++ "\n") : actualLines lines'

-- | Compute the line ranges within a given range of a string.
actualLineRanges :: Range -> String -> [Range]
actualLineRanges range = drop 1 . scanl toRange (Range (start range) (start range)) . actualLines . substring range
  where toRange previous string = Range (end previous) $ end previous + length string

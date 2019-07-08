-- | This module contains functions for pretty printing.
--
--   We are using the 'Pretty' type class from the 'wl-pprint-text' package.

module Compiler.Pretty
  ( module Text.PrettyPrint.Leijen.Text
  , prettySeparated
  , prettyMaybe
  , prettyString
  , prettyText
  , renderPretty'
  , putPretty
  , putPrettyLn
  , hPutPretty
  , hPutPrettyLn
  , writePrettyFile
  , showPretty
  )
  where

import           System.IO
import           Data.List                      ( intersperse )

import qualified Data.Text.Lazy                as TL
import           Text.PrettyPrint.Leijen.Text

-------------------------------------------------------------------------------
-- Pretty printing                                                           --
-------------------------------------------------------------------------------

-- | Pretty prints a list of pretty printable values by concatenating their
--   documents with the given separator in between.
prettySeparated :: Pretty a => Doc -> [a] -> Doc
prettySeparated separator = hcat . intersperse separator . map pretty

-- | Pretty prints the value contained in the given 'Maybe' value or pretty
--   prints a default value.
--
--   There is also a 'Pretty' instance for 'Maybe' that produces the empty
--   document if the value is 'Nothing'.
prettyMaybe :: (Pretty a, Pretty b) => a -> Maybe b -> Doc
prettyMaybe c Nothing  = pretty c
prettyMaybe _ (Just x) = pretty x

-- | Pretty prints a string without automatic newlines if the string does not
--   fit onto the page.
prettyString :: String -> Doc
prettyString = text . TL.pack

-- | Pretty prints a string such that long lines that don't fit the page
--   are automatically broken between two words.
prettyText :: String -> Doc
prettyText = foldr (</>) empty . map prettyString . words

-------------------------------------------------------------------------------
-- Trailing lines                                                            --
-------------------------------------------------------------------------------

-- | A pretty printable value with a trailing newline.
data Pretty a => TrailingLine a = TrailingLine a

-- | Pretty prints the wrapped value of a 'TrailingLine' and adds the trailing
--   newline to the resulting document.
instance Pretty a => Pretty (TrailingLine a) where
  pretty (TrailingLine x) = pretty x <> line

-------------------------------------------------------------------------------
-- Rendering                                                                 --
-------------------------------------------------------------------------------

-- | Pretty prints a value with a maximum line length of @80@ characters.
renderPretty' :: Pretty a => a -> SimpleDoc
renderPretty' = renderPretty ribbonFrac maxLineWidth . pretty
 where
  ribbonWidth, maxLineWidth :: Int
  ribbonWidth  = maxLineWidth
  maxLineWidth = 80

  ribbonFrac :: Float
  ribbonFrac = fromIntegral ribbonWidth / fromIntegral maxLineWidth

-------------------------------------------------------------------------------
-- Output                                                                    --
-------------------------------------------------------------------------------

-- | Prints a pretty printable value to 'stdout'.
putPretty :: Pretty a => a -> IO ()
putPretty = hPutPretty stdout

-- | Prints a pretty printable value to 'stdout' with trailing newline.
putPrettyLn :: Pretty a => a -> IO ()
putPrettyLn = putPretty . TrailingLine

-- | Prints a pretty printable value to the given file handle.
hPutPretty :: Pretty a => Handle -> a -> IO ()
hPutPretty h = displayIO h . renderPretty'

-- | Prints a pretty printable value to the given file handle and adds a
--   trailing newline.
hPutPrettyLn :: Pretty a => Handle -> a -> IO ()
hPutPrettyLn h = hPutPretty h . TrailingLine

-- | Writes a pretty printable value to the file located at the given path.
--   There is always a trailing newline at the end of the file.
writePrettyFile :: Pretty a => FilePath -> a -> IO ()
writePrettyFile filename = withFile filename WriteMode . flip hPutPrettyLn

-------------------------------------------------------------------------------
-- Conversion                                                                --
-------------------------------------------------------------------------------

-- | Convers a pretty printable value to a string.
showPretty :: Pretty a => a -> String
showPretty = TL.unpack . displayT . renderPretty'

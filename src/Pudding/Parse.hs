{-# LANGUAGE OverloadedStrings #-}
module Pudding.Parse (
  PToken(..),
  conduitPuddingParser,
  ) where

import Control.Applicative ((<|>),(<$>), (*>), (<*))
import Control.Monad (void)
import Data.Attoparsec.ByteString (Parser, Result, IResult(..), choice, many', endOfInput)
import qualified Data.Attoparsec.ByteString as A (takeWhile1)
import Data.Attoparsec.Char8 as AC (char, string, double, feed, parse, isSpace_w8, isSpace, skipSpace, sepBy, satisfy, notInClass)
import Data.ByteString.Char8 as BC (ByteString, pack, append)
import Data.Conduit as C (Conduit)
import qualified Data.Conduit.List as CL (concatMapAccum)
import Data.Functor ((<$))

data PToken = PWord ByteString
            | PNumber Double
            | PBool Bool
            | PString ByteString
            deriving (Show, Eq)

-- $setup
-- >>> import Data.Conduit
-- >>> import Data.Conduit.List
-- >>> import Data.Attoparsec
-- >>> :set -XOverloadedStrings

-- | token parser
--
-- >>> parseOnly pToken "123.5"
-- Right (PNumber 123.5)
-- >>> parseOnly pToken "\"aabbcc\""
-- Right (PString "aabbcc")
-- >>> parseOnly pToken "abc"
-- Right (PWord "abc")
-- >>> parseOnly pToken "2dup"
-- Right (PWord "2dup")
pToken :: Parser PToken
pToken = choice [PNumber <$> double <* spaceOrEnd
                ,PBool <$> choice [True <$ string "true"
                                  ,False <$ string "false"] <* spaceOrEnd
                ,PString <$> pString <* spaceOrEnd
                ,PWord <$> A.takeWhile1 (not . isSpace_w8) <* spaceOrEnd
                ]

spaceOrEnd :: Parser ()
spaceOrEnd = void (satisfy isSpace) <|> endOfInput

-- | string paresr
--
-- >>> parseOnly pString . pack $ show ""
-- Right ""
-- >>> parseOnly pString . pack $ show "abc"
-- Right "abc"
-- >>> parseOnly pString . pack $ show "'"
-- Right "'"
-- >>> parseOnly pString "\"\\\"\\\\\\0\\a\\b\\f\\n\\r\\t\""
-- Right "\"\\\NUL\a\b\f\n\r\t"
pString :: Parser ByteString
pString = char '"' *> (pack <$> many' (pEscape <|> pChar)) <* char '"'

pChar :: Parser Char
pChar = AC.satisfy $ AC.notInClass "\"\\"

-- | espace char parser
--
-- >>> parseOnly pEscape "\\\""
-- Right '"'
-- >>> parseOnly pEscape "\\\\"
-- Right '\\'
-- >>> parseOnly pEscape "\\0"
-- Right '\NUL'
-- >>> parseOnly pEscape "\\a"
-- Right '\a'
-- >>> parseOnly pEscape "\\t"
-- Right '\t'
pEscape :: Parser Char
pEscape = char '\\' *> (unEscape <$> AC.satisfy (`elem` "\"\\0abfnrt"))
  where
    unEscape '"' = '"'
    unEscape '\\' = '\\'
    unEscape '0' = '\0'
    unEscape 'a' = '\a'
    unEscape 'b' = '\b'
    unEscape 'f' = '\f'
    unEscape 'n' = '\n'
    unEscape 'r' = '\r'
    unEscape 't' = '\t'
    unEscape a = error $ "unknown character: " ++ [a]

-- |
-- >>> runResourceT $ sourceList ["aaa 1", "2 3"] $= conduitPuddingParser $$ consume
-- [PWord "aaa",PNumber 1.0,PNumber 2.0,PNumber 3.0]
conduitPuddingParser :: Monad m => Conduit ByteString m PToken
conduitPuddingParser = CL.concatMapAccum step ""
  where
    step :: ByteString -> ByteString -> (ByteString, [PToken])
    step input rest = case parseFeed parser (append rest input) of
      Done t r -> (t, r)
      Fail { } -> ("", [])
      _ -> error "Partial should not happen"

    parser :: Parser [PToken]
    parser = skipSpace >> pToken `sepBy` skipSpace

    parseFeed :: Parser [PToken] -> ByteString -> Result [PToken]
    parseFeed p i = feed (parse p i) ""

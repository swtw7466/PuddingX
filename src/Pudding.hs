{-# LANGUAGE OverloadedStrings #-}
module Pudding where

import Control.Applicative ((<|>),(<$>), (*>), (<*))
import Control.Monad.State (State, get, put, runState)
import Control.Monad.Trans.Either (EitherT, left, right, runEitherT)
import Control.Monad.Trans.Resource (MonadThrow)
import Data.Attoparsec.ByteString (Parser, many')
import qualified Data.Attoparsec.ByteString as A
import Data.Attoparsec.Char8 as AC hiding (space)
import Data.ByteString.Char8 as BC (ByteString, pack, append)
import Data.Conduit as C (Conduit, GLInfConduit, (=$=))
import qualified Data.Conduit.List as CL (map, concatMap, concatMapAccum)
import Data.Functor ((<$))
import Data.Map as Map (Map, fromList, lookup)
import Data.Tuple (swap)
import GHC.Word (Word8)
import Prelude hiding (div)

data PToken = PWord ByteString
            | PNumber Double
            | PBool Bool
            | PString ByteString
            deriving (Show, Eq)

-- | token parser
--
-- >>> parseOnly pToken . pack $ "123.5"
-- Right (PNumber 123.5)
-- >>> parseOnly pToken . pack $ "\"aabbcc\""
-- Right (PString "aabbcc")
-- >>> parseOnly pToken . pack $ "abc"
-- Right (PWord "abc")
pToken :: Parser PToken
pToken = PNumber <$> double
         <|> PBool <$> choice [True <$ string "true"
                              ,False <$ string "false"]
         <|> PString <$> pString
         <|> PWord <$> (A.takeWhile1 $ not . isSpace_w8)

-- | string paresr
--
-- >>> parseOnly pString . pack $ show ""
-- Right ""
-- >>> parseOnly pString . pack $ show "abc"
-- Right "abc"
-- >>> parseOnly pString . pack $ show "'"
-- Right "'"
-- >>> parseOnly pString . pack $ "\"\\\"\\\\\\0\\a\\b\\f\\n\\r\\t\""
-- Right "\"\\\NUL\a\b\f\n\r\t"
pString :: Parser ByteString
pString = char '"' *> (pack <$> many' (pEscape <|> pChar)) <* char '"'

pChar :: Parser Char
pChar = AC.satisfy $ AC.notInClass "\"\\"

-- | espace char parser
--
-- >>> parseOnly pEscape $ pack "\\\""
-- Right '"'
-- >>> parseOnly pEscape $ pack "\\\\"
-- Right '\\'
-- >>> parseOnly pEscape $ pack "\\0"
-- Right '\NUL'
-- >>> parseOnly pEscape $ pack "\\a"
-- Right '\a'
-- >>> parseOnly pEscape $ pack "\\t"
-- Right '\t'
pEscape :: Parser Char
pEscape = char '\\' *> (unEscape <$> (AC.satisfy (`elem` "\"\\0abfnrt")))
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

conduitPuddingParser :: MonadThrow m => Conduit ByteString m PToken
conduitPuddingParser = CL.concatMapAccum step ""
  where
    step :: ByteString -> ByteString -> (ByteString, [PToken])
    step input rest = case parseFeed parser (append rest input) of
      Done t r -> (t, r)
      Fail _ _ _ -> ("", [])

    parser :: Parser [PToken]
    parser = (skipSpace >> pToken `sepBy` skipSpace)

    parseFeed :: Parser [PToken] -> ByteString -> Result [PToken]
    parseFeed p i = feed (parse p i) ""

data PData = PDNumber Double
           | PDBool Bool
           | PDString ByteString
           deriving (Eq, Show)

--type PProc = [PData] -> Either ByteString ([ByteString], [PData])
type PProc = EnvWithError ByteString

data Environment = Environment
                   { stack :: [PData]
                   , wordMap :: Map ByteString PProc
                   }

showTop :: PProc
showTop = pack . show <$> pop

showStack :: PProc
showStack = get >>= return . pack . show . stack

plus :: PProc
--plus ((PDNumber a):(PDNumber b):xs) = Right ([], (PDNumber $ b+a):xs)
--plus ((PDString a):(PDString b):xs) = Right ([], (PDString $ append b a):xs)
--plus _ = Left "+ needs 2 operand"
plus = undefined

minus :: PProc
--minus ((PDNumber a):(PDNumber b):xs) = Right ([], (PDNumber $ b-a):xs)
--minus _ = Left "- needs 2 operands"
minus = undefined

mul :: PProc
--mul ((PDNumber a):(PDNumber b):xs) = Right ([], (PDNumber $ b*a):xs)
--mul _ = Left "* needs 2 operands"
mul = undefined

div :: PProc
--div ((PDNumber a):(PDNumber b):xs) = Right ([], (PDNumber $ b/a):xs)
--div _ = Left "/ needs 2 operands"
div = undefined

dup :: PProc
--dup (x:xs) = Right ([], x:x:xs)
--dup _ = Left "dup needs 1 operands"
dup = undefined

initEnv :: Environment
initEnv = Environment { stack = []
                      , wordMap = fromList [(".", showTop)
                                           ,(".s", showStack)
                                           ,("+", plus)
                                           ,("-", minus)
                                           ,("*", mul)
                                           ,("/", div)
                                           ,("dup", dup)
                                           ]
                      }

type Env = State Environment
type EnvWithError = EitherT ByteString Env

push :: PData -> Env ()
push d = do
  env@(Environment s _) <- get
  put env { stack = d:s }

pop :: EnvWithError PData
pop = do
  env@(Environment s _) <- get
  case s of
    (a:as) -> put env { stack = as } >> right a
    _ -> left "empty stack"

data PContainer = PData PData
                | PProc ByteString (Maybe PProc)

lookupWord :: ByteString -> Env (Maybe PProc)
lookupWord x = get >>= return . Map.lookup x . wordMap

fromToken :: PToken -> Env PContainer
fromToken (PNumber x) = return . PData $ PDNumber x
fromToken (PBool x) = return . PData $ PDBool x
fromToken (PString x) = return . PData $ PDString x
fromToken (PWord x) = PProc x <$> lookupWord x

conduitPuddingEvaluator :: Monad m => Conduit PToken m ByteString
conduitPuddingEvaluator = CL.concatMapAccum step initEnv =$= CL.map (`append` "\n")
  where
    step :: PToken -> Environment -> (Environment, [ByteString])
    step t e = swap $ runState (fromToken t >>= eval) e

    eval :: PContainer -> Env [ByteString]
    eval (PData x) = push x >> return []
    eval (PProc _ (Just p)) = apply p
    eval (PProc word Nothing) = return [append "undefined word " word]

    apply :: PProc -> Env [ByteString]
    apply p = runEitherT p >>= return . either fail success
      where
        fail :: ByteString -> [ByteString]
        fail x = [append "*** " x]

        success :: ByteString -> [ByteString]
        success x = [append "> " x]

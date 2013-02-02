{-# LANGUAGE DeriveGeneric #-}

module Forml.Types.Symbol where

import Language.Javascript.JMacro

import Control.Applicative

import Text.Parsec         hiding ((<|>), State, many, spaces, parse, label)

import Forml.Parser.Utils

import qualified Data.Map as M
import Data.String.Utils
import Data.Serialize

import GHC.Generics

data Symbol = Symbol String
            | Operator String
            deriving (Ord, Eq, Generic)

instance Serialize Symbol

instance Show Symbol where
    show (Symbol s)   = s
    show (Operator x) = x

instance Syntax Symbol where
    syntax =  (Symbol <$> not_reserved (oneOf "abscdefghijklmnopqrstuvwxyz" <:> many (alphaNum <|> oneOf "_'!$" <|> (string "?" >> return '_'))))
              <|> (Operator <$> not_reserved imp_infix)
        where imp_infix = string "(" *> many1 operator <* option "" (try (string ":")) <* string ")"

instance ToJExpr Symbol where
    toJExpr = toJExpr . to_name

to_name :: Symbol -> String
to_name (Symbol "return") = "_return_"
to_name (Symbol "new") = "_new_"
to_name (Symbol "while") = "_while_"


to_name (Symbol x) = replace "!" "_excl" $ replace " " "_" $ replace "'" "_apos" x
to_name (Operator op) = concat . map (\x -> M.findWithDefault "_" x operator_dict) $ op


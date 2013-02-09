{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE OverlappingInstances   #-}
{-# LANGUAGE QuasiQuotes            #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeSynonymInstances   #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE ViewPatterns           #-}

module Forml.Types.Statement where

import Text.InterpolatedString.Perl6

import Language.Javascript.JMacro

import Control.Applicative

import Text.Parsec                   hiding (State, label, many,
                                      parse, spaces, (<|>))
import Text.Parsec.Indent            hiding (same)

import qualified Data.List                     as L
import           Data.Monoid
import qualified Data.Serialize                as S
import           Data.String.Utils

import GHC.Generics

import Forml.Parser.Utils

import Forml.Types.Axiom
import Forml.Types.Definition
import Forml.Types.Expression
import Forml.Types.Namespace
import Forml.Types.Symbol
import Forml.Types.Type
import Forml.Types.TypeDefinition

import Forml.Javascript.Backend
import Forml.Javascript.Utils

import Prelude                       hiding (curry, (++))
import System.IO.Unsafe              (unsafePerformIO)



--------------------------------------------------------------------------------
----
---- Statement

data Statement = TypeStatement TypeDefinition UnionType
               | DefinitionStatement Definition
               | ExpressionStatement (Addr (Expression Definition))
               | ImportStatement Namespace (Maybe String)
               | ModuleStatement Namespace [Statement]
               deriving (Generic)

instance S.Serialize Statement

instance Show Statement where
    show (TypeStatement t c)     = [qq|type $t = $c|]
    show (DefinitionStatement d) = show d
    show (ExpressionStatement (Addr _ _ x)) = show x
    show (ImportStatement x Nothing) = [qq|open $x|]
    show (ImportStatement x (Just a)) = [qq|open $x as $a|]
    show (ModuleStatement x xs) = replace "\n |" "\n     |"
                                  $ replace "\n\n" "\n\n    "
                                  $ "module "
                                  ++ show x ++ "\n\n" ++ sep_with "\n\n" xs

instance Syntax Statement where

    syntax = whitespace >> withPos statement_types <* many newline

        where statement_types =

                  (type_statement <?> "Type Definition")
                  <|> (try import_statement <?> "Import Statement")
                  <|> (module_statement <?> "Module Declaration")
                  <|> (def_statement <?> "Symbol Definition")
                  <|> (expression_statement <?> "Assertion")

              def_statement = DefinitionStatement <$> syntax

              import_statement =

                  do string "open"
                     whitespace
                     imports <- syntax
                     alias   <- try alias_statement <|> return Nothing
                     return $ ImportStatement imports alias

                  where alias_statement =

                            do many1 (char ' ')
                               string "as"
                               many1 (char ' ')
                               (Symbol x) <- syntax
                               return  (Just x)


              module_statement = do try (string "module")
                                    whitespace1
                                    name <- try syntax <|> (char '"' *> (Namespace . (:[]) <$> (anyChar `manyTill` char '"')))
                                    whitespace *> newline
                                    spaces *> (indented <|> same)
                                    ModuleStatement name <$> withPos (many1 ((spaces >> same >> syntax)))

              type_statement  = do try (string "type" >> spaces) <|> return ()
                                   def <- syntax
                                   set_indentation (+1)
                                   whitespace
                                   sig <- try (string "=" >> spaces >> (string "|" >> type_definition_signature))
                                          <|> (string "=" >> spaces >> type_definition_signature)
                                   whitespace
                                   set_indentation (+(-1))
                                   return $ TypeStatement def sig

              expression_statement = do try (string "test" >> spaces) <|> return ()
                                        whitespace
                                        x <- getPosition
                                        y <- withPos$ addr syntax
                                        z <- getPosition
                                        return $ ExpressionStatement y




--------------------------------------------------------------------------------
----
---- Meta

data Meta = Meta { target    :: Target,
                   namespace :: Namespace,
                   modules   :: [Module],
                   expr      :: Statement } deriving (Show)

data Target = Test | Library
            deriving (Show)

serial :: SourcePos -> SourcePos -> String
serial a b = show (sourceLine a - 1) ++ "_" ++ show (sourceLine b - 1) ++ (if sourceLine a /= sourceLine b then "multi" else "")

get_code :: forall a. Addr a -> JS String
get_code a = do src <- JS (\s @ JSState {src = src} -> (s, src))
                return $ get_error a src

instance Javascript Meta JStat where

    -- Expressions are ignored for Libraries, and rendered as tests for Test
    toJS (Meta { target = Library, expr = ExpressionStatement _ }) = return mempty
    toJS (Meta { target = Test,    expr = ExpressionStatement a' @ (Addr a b e) }) =

        do message <- get_code a'
           return [jmacro| it(`(serial a b ++ "__::__" ++ message)`, function() {
                               `(Jasmine e)`;
                           }); |]

    -- Imports work identically for both targets
    toJS (Meta { modules,
                 namespace = Namespace [],
                 expr      = ImportStatement target_namespace @ (find modules -> Nothing) _ }) =

        fail [qq| Could not resolve namespace $target_namespace |]

    toJS (Meta { modules,
                 expr      = ImportStatement target_namespace Nothing,
                 namespace = (find modules . (++ target_namespace) -> Just y) }) =

        return $ open target_namespace y

    toJS (Meta { modules,
                 expr      = ImportStatement target_namespace @ (Namespace ns) (Just alias),
                 namespace = (find modules . (++ target_namespace) -> Just y) }) =

        return $ declare alias (Namespace $ ns)

    toJS meta @ (Meta { expr = ImportStatement _ _, .. }) =

        let slice (Namespace ns) = Namespace . take (length ns - 1) $ ns
        in  toJS (meta { namespace = slice namespace })


    -- Modules in test mode must open the contents of the Library

    toJS meta @ (Meta { target = Library, namespace = Namespace [], expr = ModuleStatement ns xs, .. }) =

        do xs' <- toJS $ fmap (\z -> meta { namespace =  ns, expr = z }) xs
           return $ declare_window (render_ns ns)
                 [jmacroE| new (function() {
                               `(xs')`;
                           }) |]

    toJS meta @ (Meta { target = Library, expr = ModuleStatement ns xs, .. }) =

        do xs' <- toJS $ fmap (\z -> meta { namespace = namespace ++ ns, expr = z }) xs
           return $ declare_this (render_ns ns)
                 [jmacroE| new (function() {
                               `(xs')`;
                           }) |]


    toJS meta @ (Meta { target = Test, expr = ModuleStatement ns xs, .. }) =

        let (imports, rest) = L.partition f xs
            f (ImportStatement _ _) = True
            f _ = False in

        do imports' <- toJS $ map (\z -> meta { namespace = namespace ++ ns, expr = z }) imports
           rest'    <- toJS $ map (\z -> meta { namespace = namespace ++ ns, expr = z }) rest

           return [jmacro| describe(`(show ns)`, function() {
                             `(open (namespace ++ ns) xs)`;
                             `(imports')`;
                             `(open (namespace ++ ns) xs)`;

                             var x = new (function {
                                 `(rest')`;
                             }());
                         }); |]



    -- Definitions are ignored for the Test target

    toJS (Meta { target = Library, expr = DefinitionStatement d }) = toJS d
    toJS (Meta { target = Test,    expr = DefinitionStatement _ }) = return mempty

    toJS (Meta { expr = TypeStatement _ _ }) = return mempty
  --  toJS x = fail $ "Unimplemented " ++ show x



empty_meta :: Target -> [Statement] -> Statement -> Meta
empty_meta x = Meta x (Namespace []) . build_modules

    where build_modules (ModuleStatement n ns : xs) = Module n (build_modules ns) : build_modules xs
          build_modules (DefinitionStatement (Definition _ _ n _): xs) = Var (to_name n) : build_modules xs
          build_modules (_ : xs) = build_modules xs
          build_modules [] = []

find :: [Module] -> Namespace -> Maybe [String]
find (Var s : ss) n @ (Namespace []) = Just [s] ++ find ss n
find (Var _: xs) ns                  = find xs ns
find [] (Namespace [])               = Just []
find [] _                            = Nothing

find (Module _ xs : ms) n @ (Namespace []) = find ms n
find (Module (Namespace ys) x : zs) n @ (Namespace xs)
     | length xs >= length ys && take (length ys) xs == ys =
         find x (Namespace $ drop (length ys) xs)
     | otherwise = find zs n



--------------------------------------------------------------------------------
----
---- Open

class Open a where open :: Namespace -> [a] -> JStat

instance Open Statement where
    open _ [] = mempty
    open ns (DefinitionStatement (Definition _ _ _ (TypeAxiom _: [])) : xs) = open ns xs
    open ns (DefinitionStatement (Definition _ _ n _) : xs) =

        let f = ref . render_ns
            x = [jmacroE| `(f ns)`[`(n)`] |] in

        [jmacro| `(declare (replace " " "_" $ to_name n) x)`;
                 `(open ns xs)`; |]

    open nss (ModuleStatement ns @ (Namespace (n:_)) _:xs) =

        [jmacro| `(declare (clean_ns n) (ref . render_ns $ nss ++ ns))`;
                 `(open nss xs)`; |]

    open ns (_ : xs) = open ns xs

instance Open String where
    open _ [] = mempty
    open (Namespace ns) (x:xs) =

        let print' []     = error "Empty Namespace"
            print' (y:[]) = [jmacroE| `(ref $ clean_ns y)` |]
            print' (y:ys) = [jmacroE| `(print' ys)`[`(clean_ns y)`] |]

        in  declare x [jmacroE| `(print' $ reverse ns)`[`(x)`] || (typeof global == "undefined" ? window : global)[`(x)`] |] ++ open (Namespace ns) xs

render_ns :: Namespace -> String
render_ns (Namespace xs) =

    concat . L.intersperse "." . map clean_ns $ xs


clean_ns = ("$" ++) . replace " " "_"




--------------------------------------------------------------------------------
----
---- Jasmine

newtype Jasmine = Jasmine (Expression Definition)

instance ToStat Jasmine where

    toStat (Jasmine (ApplyExpression (SymbolExpression (Operator "==")) [x, y])) =

        [jmacro| expect(`(x)`).toEqual(`(y)`); |]

    toStat (Jasmine (ApplyExpression (SymbolExpression (Operator "!=")) [x, y])) =

        [jmacro| expect(`(x)`).toNotEqual(`(y)`); |]

    toStat (Jasmine e) =

        [jmacro| expect((function() {
                     try {
                         return `(e)`;
                     } catch (ex) {
                         return { error: ex };
                     }
                 })()).toEqual(true); |]



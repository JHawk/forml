
<link rel='stylesheet' type='text/css' href='lib/js/jasmine-1.0.1/jasmine.css'>
<script type='text/javascript' src='lib/js/jasmine-1.0.1/jasmine.js'></script>
<script type='text/javascript' src='lib/js/jasmine-1.0.1/jasmine-html.js'></script>
<script type='text/javascript' src='lib/js/zepto.js'></script>
<script type='text/javascript' src='$name.js'></script>
<script type='text/javascript' src='$name.spec.js'></script>
<link href='http://kevinburke.bitbucket.org/markdowncss/markdown.css' rel='stylesheet'></link>
<link href='lib/js/prettify.css' type='text/css' rel='stylesheet' />
<script type='text/javascript' src='lib/js/prettify.js'></script>
<script type='text/javascript' src='lib/js/lang-hs.js'></script>
<script type='text/javascript' src='lib/js/jquery.js'></script>
<style>pre{max-width:1600px;}</style>

> {-# LANGUAGE QuasiQuotes #-}
> {-# LANGUAGE NamedFieldPuns #-}
> {-# LANGUAGE RecordWildCards #-}
> {-# LANGUAGE ViewPatterns #-}
> {-# LANGUAGE RankNTypes #-}
> {-# LANGUAGE TemplateHaskell #-}
> {-# LANGUAGE QuasiQuotes #-}
> {-# LANGUAGE OverlappingInstances #-}
> {-# LANGUAGE FlexibleContexts #-}


> module Main where

> import Text.InterpolatedString.Perl6

> import Control.Applicative
> import Control.Monad.Identity
> import Control.Monad.State hiding (lift)

> import System.IO
> import System.Environment

> import Text.Parsec hiding ((<|>), State, many, spaces, parse)
> import Text.Parsec.Indent
> import Text.Pandoc

> import qualified Data.Map as M
> import qualified Data.List as L
> import qualified Data.Set as S

> import Data.Char (ord, isAscii)
> import Data.String.Utils

> import Language.Javascript.JMacro


Structure & comments
--------------------------------------------------------------------------------
lore ipsum

> type Parser a = ParsecT String () (StateT SourcePos Identity) a

> parse :: Parser a -> SourceName -> String -> Either ParseError a
> parse parser sname input = runIndent sname $ runParserT parser () sname input

> whitespace :: Parser String
> whitespace = many $ oneOf "\t "

> whitespace1 :: Parser String
> whitespace1 = space >> whitespace

> in_block :: Parser ()
> in_block = do pos <- getPosition
>               s <- get
>               if (sourceColumn pos) < (sourceColumn s) 
>                 then parserFail "not indented" 
>                 else do put $ setSourceLine s (sourceLine pos)
>                         return ()

> spaces :: Parser ()
> spaces = try emptyline `manyTill` try line_start >> return ()

>     where emptyline  = whitespace >> newline
>           line_start = whitespace >> notFollowedBy newline >> in_block

> comment :: Parser String
> comment = try (whitespace >> newline >> return "\n") <|> comment'

>     where comment' = do x <- anyChar `manyTill` newline
>                         case x of 
>                           (' ':' ':' ':' ':_) -> return (x ++ "\n")
>                           _ -> return "\n"

> sep_with :: Show a => String -> [a] -> String
> sep_with x = concat . L.intersperse x . fmap show




Parsing 
-----------------------------------------------------------------------------
A Sonnet program is represented by a set of statements

> newtype Program = Program [Statement]

> data Statement = TypeStatement TypeDefinition UnionType
>                | DefinitionStatement String [Axiom]
>                -- | ExpressionStatement Expression

> instance Show Program where
>      show (Program ss) = sep_with "\n" ss

> instance Show Statement where
>     show (TypeStatement t c)        = [qq|type $t = $c|]
>     show (DefinitionStatement s as) = [qq|$s {sep_with "\\n" as}|]

> sonnetParser :: Parser Program
> sonnetParser  = Program . concat <$> many (many (string "\n") >> statement) <* eof
>     where statement = whitespace >> withPos (try type_statement <|> definition_statement) <* many newline


Statements
-----------------------------------------------------------------------------
A Statement may be a definition, which is a list of axioms associated with a
symbol

> data Axiom = TypeAxiom UnionType
>            | EqualityAxiom [Pattern] Expression

> instance Show Axiom where
>     show (TypeAxiom x) = ": " ++ show x
>     show (EqualityAxiom ps ex) = [qq| | {concat . map show $ ps} = $ex|]

> definition_statement :: Parser [Statement]
> definition_statement = do whitespace
>                           name <- type_var
>                           spaces
>                           indented
>                           string ":"
>                           spaces
>                           indented
>                           sig <- withPos type_axiom_signature
>                           spaces
>                           eqs <- withPos (many $ try eq_axiom)
>                           whitespace
>                           return $ [DefinitionStatement name (TypeAxiom sig : eqs)]

>     where eq_axiom   = do spaces
>                           string "|" 
>                           whitespace
>                           patterns <- pattern `sepEndBy` whitespace1
>                           string "="
>                           spaces
>                           indented
>                           ex <- withPos expression
>                           return $ EqualityAxiom patterns ex



Type definitions

> data TypeDefinition = TypeDefinition String [String]

> instance Show TypeDefinition where
>     show (TypeDefinition name vars) = concat . L.intersperse " " $ name : vars



> type_definition :: Parser TypeDefinition
> type_statement  :: Parser [Statement]

> type_statement  = do whitespace
>                      string "type"
>                      whitespace1
>                      def <- type_definition
>                      whitespace 
>                      string "="
>                      spaces
>                      sig <- withPos type_definition_signature
>                      whitespace
>                      return $ [TypeStatement def sig]

> type_definition = do name <- (:) <$> upper <*> many alphaNum
>                      vars <- try vars' <|> return []
>                      return $ TypeDefinition name vars

>     where vars' = do many1 $ oneOf "\t "
>                      let var = (:) <$> lower <*> many alphaNum
>                      var `sepEndBy` whitespace



Patterns
-----------------------------------------------------------------------------


> data Pattern = VarPattern String
>              | AnyPattern
>              | LiteralPattern Literal
>              | RecordPattern (M.Map String Pattern)
>              | ListPattern [Pattern]
>              | NamedPattern String Pattern

> instance Show Pattern where
>     show (VarPattern x)     = x
>     show AnyPattern         = "_"
>     show (LiteralPattern x) = show x
>     show (ListPattern x)    = [qq|[ {sep_with ", " x} ]|]
>     show (RecordPattern m)  = [qq|\{ {g m} \}|] 
>         where g             = concat . L.intersperse ", " . fmap (\(x, y) -> [qq|$x = $y|]) . M.toAscList

> pattern         :: Parser Pattern
> var_pattern     :: Parser Pattern
> literal_pattern :: Parser Pattern
> record_pattern  :: Parser Pattern
> list_pattern    :: Parser Pattern
> named_pattern   :: Parser Pattern
> any_pattern     :: Parser Pattern

> pattern         = var_pattern 
>                   <|> any_pattern
>                   <|> literal_pattern
>                   <|> record_pattern
>                   <|> list_pattern
>                   <|> indentPairs "(" (try named_pattern <|> pattern) ")"

> var_pattern     = VarPattern <$> type_var
> literal_pattern = LiteralPattern <$> literal          
> any_pattern     = many1 (string "_") *> return AnyPattern

> named_pattern   = parserFail "named"

> record_pattern = RecordPattern . M.fromList <$> indentPairs "{" pairs' "}"

>     where pairs' = key_eq_val `sepEndBy` try (comma <|> not_comma)
>           key_eq_val = do key <- many (alphaNum <|> oneOf "_")
>                           spaces
>                           string "="
>                           spaces
>                           value <- pattern
>                           return (key, value)

> list_pattern = ListPattern <$> indentPairs "[" (pattern `sepBy` comma) "]"



Expressions
-----------------------------------------------------------------------------
TODO Infix expressions

> data Expression = ApplyExpression Expression [Expression]
>                 | LiteralExpression Literal
>                 | SymbolExpression String
>                 | JSExpression JStat
>                 | FunctionExpression [Axiom]
>                 | RecordExpression (M.Map String Expression)
>                 | ListExpression [Expression]

> instance Show Expression where
>     show (ApplyExpression x y)   = [qq|$x {sep_with " " y}|]
>     show (LiteralExpression x)   = show x
>     show (SymbolExpression x)    = x
>     show (ListExpression x)      = [qq|[ {sep_with ", " x} ]|]
>     show (FunctionExpression as) = [qq|λ{sep_with "" as}|]
>     show (RecordExpression m)    = [qq|\{ {g m} \}|] 
>         where g                  = concat . L.intersperse ", " . fmap (\(x, y) -> [qq|$x = $y|]) . M.toAscList

> expression          :: Parser Expression
> apply_expression    :: Parser Expression
> function_expression :: Parser Expression
> js_expression       :: Parser Expression
> record_expression   :: Parser Expression
> literal_expression  :: Parser Expression
> symbol_expression   :: Parser Expression
> list_expression     :: Parser Expression

> expression = try apply_expression
>              <|> function_expression
>              <|> indentPairs "(" expression ")" 
>              <|> js_expression 
>              <|> record_expression 
>              <|> literal_expression
>              <|> symbol_expression
>              <|> list_expression

> apply_expression = ApplyExpression <$> app <* whitespace <*> (expression `sepBy` whitespace1)
>     where app = indentPairs "(" (function_expression <|> apply_expression) ")" <|> symbol_expression

> function_expression = do string "\\" <|> string "λ"
>                          t <- option [] (try $ ((:[]) <$> type_axiom <* spaces))
>                          eqs <- withPos (try eq_axiom `sepBy1` (spaces *> string "|" <* whitespace))
>                          return $ FunctionExpression (t ++ eqs)

>     where type_axiom = do string ":"
>                           spaces
>                           indented
>                           TypeAxiom <$> withPos type_axiom_signature

>           eq_axiom   = do patterns <- pattern `sepEndBy` whitespace1
>                           string "="
>                           spaces
>                           indented
>                           ex <- withPos expression
>                           return $ EqualityAxiom patterns ex



TODO allow ` escaping

> js_expression = do expr <- indentPairs "`" (many $ noneOf "`") "`"
>                    case parseJM expr of
>                      Left ex -> parserFail $ show ex
>                      Right s -> return $ JSExpression s

> record_expression = RecordExpression . M.fromList <$> indentPairs "{" pairs' "}"

>     where pairs' = key_eq_val `sepEndBy` try (comma <|> not_comma)
>           key_eq_val = do key <- many (alphaNum <|> oneOf "_")
>                           spaces
>                           string "="
>                           spaces
>                           value <- expression
>                           return (key, value)

> literal_expression = LiteralExpression <$> literal

> symbol_expression = SymbolExpression <$> type_var

> list_expression = ListExpression <$> indentPairs "[" (expression `sepBy` comma) "]"



Literals
-----------------------------------------------------------------------------
Literals in Sonnet are limited to strings and numbers - 


> data Literal = StringLiteral String | NumLiteral Int

> instance Show Literal where
>    show (StringLiteral x) = show x
>    show (NumLiteral x)    = show x

ValueLiterals 


> literal :: Parser Literal
> literal = try num <|> str
>     where num = NumLiteral . read <$> many1 digit
>           str = StringLiteral <$> (char '"' >> (anyChar `manyTill` char '"'))


ListLiterals

> list_literal :: Parser Literal
> list_literal = parserFail "Failed to parse list"



Type Signatures
-----------------------------------------------------------------------------
TODO Implicits
TODO Record Extensions
TODO ! (IO type)
? TODO List, Map, Set shorthand?

The type algebra of Sonnet is broken into 3 types to preserve the 
associativity of UnionTypes: (x | y) | z = x | y | z


> data UnionType = UnionType (S.Set ComplexType)
>                deriving (Ord, Eq)

> data ComplexType = PolymorphicType SimpleType [UnionType]
>                  | JSONType (M.Map String UnionType)
>                  | NamedType String UnionType
>                  | FunctionType UnionType UnionType
>                  | SimpleType SimpleType
>                  deriving (Eq, Ord)

> data SimpleType = SymbolType String | VariableType String deriving (Ord, Eq)

> instance Show UnionType where 
>     show (UnionType xs)        = [qq|{sep_with " | " $ S.toList xs}|]
   
> instance Show ComplexType where
>     show (SimpleType y)        = [qq|$y|]
>     show (PolymorphicType x y) = [qq|($x {sep_with " " y})|]
>     show (NamedType name t)    = [qq|$name of $t|]
>     show (JSONType m)          = [qq|\{ {g m} \}|] 
>         where g = concat . L.intersperse ", " . fmap (\(x, y) -> [qq|$x: $y|]) . M.toAscList

>     show (FunctionType g@(UnionType (S.toList -> ((FunctionType _ _):[]))) h) = [qq|($g -> $h)|]
>     show (FunctionType g h) = [qq|$g -> $h|]

> instance Show SimpleType where
>     show (SymbolType x)   = x
>     show (VariableType x) = x


Where a type signature may be used in Sonnet had two slightly different parsers
in order to allow for somewhat overloaded surrounding characters (eg "|" - when
declaring the type of an axiom, one must be careful to disambiguate UnionTypes
and sets of EqualityAxioms).  However, these types are otherwise equivalent,
and any type that may be declared in a TypeDefinition may also be the explicit
type of a Definition (Note, however, that in the case of NamedTypes, the
names introduced into scope will be inaccessible in the case of a Definition).


> type_axiom_signature      :: Parser UnionType
> type_definition_signature :: Parser UnionType

> type_axiom_signature      = (try nested_union_type <|> (UnionType . S.fromList . (:[]) <$> (try function_type <|> inner_type))) <* whitespace
> type_definition_signature = UnionType . S.fromList <$> (try function_type <|> inner_type) `sepBy1` type_sep <* whitespace


Through various complexities of the recursive structure of these types, we will
need a few mutually recursive parsers to express these slightly different
signature parsers:


> inner_type        :: Parser ComplexType
> nested_function   :: Parser ComplexType
> nested_union_type :: Parser UnionType

> inner_type        = nested_function <|> record_type <|> try named_type <|> try poly_type <|> var_type <|> symbol_type
> nested_function   = indentPairs "(" (try function_type <|> inner_type) ")"
> nested_union_type = indentPairs "(" type_definition_signature ")"


Now that we've expressed the possible parses of a UnionType, we can move on to
parsing the ComplexType and SimpleType layers.  While these are also mutually
recursive, the recursion is uniform, as the various allowable combinations
have already been defined above.


> function_type :: Parser ComplexType
> poly_type     :: Parser ComplexType
> named_type    :: Parser ComplexType
> record_type   :: Parser ComplexType
> symbol_type   :: Parser ComplexType
> var_type      :: Parser ComplexType

> function_type = do x <- try nested_union_type <|> lift inner_type
>                    spaces
>                    string "->" <|> string "→"
>                    spaces
>                    y <- (lift $ try function_type) <|> try nested_union_type <|> lift inner_type
>                    return $ FunctionType x y

> poly_type     = do name <- (SymbolType <$> type_name) <|> (VariableType <$> type_var)
>                    oneOf "\t "
>                    whitespace
>                    let type_vars = nested_union_type <|> lift (record_type <|> var_type <|> symbol_type)
>                    vars <- type_vars `sepEndBy1` whitespace
>                    return $ PolymorphicType name vars

> record_type   = let key_value = (,) <$> many (alphaNum <|> oneOf "_") <* spaces <* string ":" <* spaces <*> type_definition_signature
>                     pairs     = key_value `sepEndBy` try (comma <|> not_comma) in
>                 (JSONType . M.fromList) <$> indentPairs "{" pairs "}"

> named_type    = NamedType <$> type_var <* whitespace <* string "of" <* spaces <*> (try nested_union_type <|> lift inner_type)
> symbol_type   = SimpleType . SymbolType <$> type_name
> var_type      = SimpleType . VariableType <$> type_var


Lastly, all type combinators above must eventuall reach a terminal, of which
there are only two: type names start with an upper case letter, and type
variables start with a lower case letter.  Note the scoping & resolution of
type variables is handled in the type checker.


> type_name :: Parser String
> type_var  :: Parser String

> type_name = (:) <$> upper <*> many (alphaNum <|> oneOf "_'")  
> type_var  = (:) <$> lower <*> many (alphaNum <|> oneOf "_'")  


Of course, there are many common idioms from type parsing which may be factored
out for reuse:


> type_sep    :: Parser Char
> indentPairs :: String -> Parser a -> String -> Parser a
> not_comma   :: Parser ()
> comma       :: Parser ()
> lift        :: Parser ComplexType -> Parser UnionType

> type_sep          = try (spaces *> char '|' <* whitespace)
> indentPairs a p b = string a *> spaces *> withPos p <* spaces <* string b
> not_comma         = whitespace >> newline >> spaces >> notFollowedBy (string "}")
> comma             = spaces >> string "," >> spaces
> lift              = fmap $ UnionType . S.fromList . (:[])

Main
----

> toEntities :: String -> String
> toEntities [] = ""
> toEntities (c:cs) | isAscii c = c : toEntities cs
>                   | otherwise = [qq|&#{ord c};{toEntities cs}|]

> toHTML :: String -> String
> toHTML = toEntities . writeHtmlString defaultWriterOptions . readMarkdown defaultParserState

> main :: IO ()
> main  = do RunConfig (file:_) output _ <- parseArgs <$> getArgs
>            hFile  <- openFile file ReadMode
>            src <- (\ x -> x ++ "\n") <$> hGetContents hFile
>            writeFile (output ++ ".html") $ toHTML (wrap_html output src)
>            putStrLn $ concat $ take 80 $ repeat "-"
>            case parse ((comment <|> return "\n") `manyTill` eof) "Cleaning comments" src of
>              Left ex -> putStrLn (show ex)
>              Right src' -> do case parse sonnetParser "Parsing" (concat src') of
>                                 Left ex -> do putStrLn $ show ex
>                                 Right x -> do putStrLn $ show x
>                                               putStrLn $ "success"

> data RunMode   = Compile | JustTypeCheck
> data RunConfig = RunConfig [String] String RunMode

> parseArgs :: [String] -> RunConfig
> parseArgs = fst . runState argsParser

>   where argsParser = do args <- get
>                         case args of
>                           []     -> return $ RunConfig [] "default" Compile
>                           (x:xs) -> do put xs
>                                        case x of
>                                          "-t"    -> do RunConfig a b _ <- argsParser
>                                                        return $ RunConfig (x:a) b JustTypeCheck
>                                          "-o"    -> do (name:ys) <- get
>                                                        put ys
>                                                        RunConfig a _ c <- argsParser
>                                                        return $ RunConfig (x:a) name c
>                                          ('-':_) -> do error "Could not parse options"
>                                          z       -> do RunConfig a _ c <- argsParser
>                                                        let b = last $ split "/" $ head $ split "." z
>                                                        return $ RunConfig (x:a) b c


Docs

> wrap_html :: String -> String -> String
> wrap_html name body = [qq|

>    <!DOCTYPE HTML PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN' 'http://www.w3.org/TR/html4/loose.dtd'>
>    <html>
>    <head>
>    <title>$name</title>
>    <link rel='stylesheet' type='text/css' href='lib/js/jasmine-1.0.1/jasmine.css'>
>    <script type='text/javascript' src='lib/js/jasmine-1.0.1/jasmine.js'></script>
>    <script type='text/javascript' src='lib/js/jasmine-1.0.1/jasmine-html.js'></script>
>    <script type='text/javascript' src='lib/js/zepto.js'></script>
>    <script type='text/javascript' src='$name.js'></script>
>    <script type='text/javascript' src='$name.spec.js'></script>
>    <link href='http://kevinburke.bitbucket.org/markdowncss/markdown.css' rel='stylesheet'></link>
>    <link href='lib/js/prettify.css' type='text/css' rel='stylesheet' />
>    <script type='text/javascript' src='lib/js/prettify.js'></script>
>    <script type='text/javascript' src='lib/js/lang-hs.js'></script>
>    <script type='text/javascript' src='lib/js/jquery.js'></script>
>    <style>ul\{padding-left:40px;\}</style>
>    </head>
>    <body>
>    <div style='margin: 0 0 50px 0'>$body</div>
>    <script type='text/javascript'>
>    jasmine.getEnv().addReporter(new jasmine.TrivialReporter());
>    jasmine.getEnv().execute();
>    </script>
>    <script type='text/javascript'>$('code').addClass('prettyprint lang-hs');
>    prettyPrint()
>    </script>
>    </body>
>    </html>

> |]

<script type='text/javascript'>
jasmine.getEnv().addReporter(new jasmine.TrivialReporter());
jasmine.getEnv().execute();
</script>
<script type='text/javascript'>$('code').addClass('prettyprint lang-hs');
prettyPrint()
</script>

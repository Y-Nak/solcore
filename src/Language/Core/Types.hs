module Language.Core.Types where

data Type
    = TWord
    | TBool
    | TPair Type Type
    | TSum Type Type
    | TFun [Type] Type
    | TUnit
    deriving (Show)
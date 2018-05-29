{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ViewPatterns #-}
-- | The types of arguments for commands
module Surveyor.Core.Arguments (
  Argument(..),
  SomeAddress(..),
  Type(..),
  TypeRepr(..),
  IntType,
  WordType,
  AddressType,
  StringType,
  CommandType,
  FilePathType,
  showRepr,
  parseArgument
  ) where

import qualified Data.Foldable as F
import qualified Data.Map.Strict as M
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Nonce as PN
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Text as T
import qualified Data.Text.Zipper.Generic as Z
import           Numeric.Natural ( Natural )
import           Text.Read ( readMaybe )

import qualified Surveyor.Core.Architecture as A
import qualified Surveyor.Core.Command as C

data Type where
  StringType :: Type
  AddressType :: Type
  IntType :: Type
  WordType :: Type
  CommandType :: Type
  FilePathType :: Type

type StringType = 'StringType
type AddressType = 'AddressType
type IntType = 'IntType
type WordType = 'WordType
type CommandType = 'CommandType
type FilePathType = 'FilePathType

data TypeRepr tp where
  CommandTypeRepr :: TypeRepr CommandType
  StringTypeRepr :: TypeRepr StringType
  AddressTypeRepr :: TypeRepr AddressType
  IntTypeRepr :: TypeRepr IntType
  WordTypeRepr :: TypeRepr WordType
  FilePathTypeRepr :: TypeRepr FilePathType

instance TestEquality TypeRepr where
  testEquality CommandTypeRepr CommandTypeRepr = Just Refl
  testEquality StringTypeRepr StringTypeRepr = Just Refl
  testEquality AddressTypeRepr AddressTypeRepr = Just Refl
  testEquality IntTypeRepr IntTypeRepr = Just Refl
  testEquality WordTypeRepr WordTypeRepr = Just Refl
  testEquality FilePathTypeRepr FilePathTypeRepr = Just Refl
  testEquality _ _ = Nothing

data SomeAddress s where
  SomeAddress :: (A.Architecture arch s) => PN.Nonce s arch -> A.Address arch s -> SomeAddress s

data Argument e st s tp where
  CommandArgument :: Some (C.Command e st (Argument e st s) TypeRepr) -> Argument e st s CommandType
  StringArgument :: T.Text -> Argument e st s StringType
  AddressArgument :: SomeAddress s -> Argument e st s AddressType
  IntArgument :: Integer -> Argument e st s IntType
  WordArgument :: Natural -> Argument e st s WordType
  FilePathArgument :: FilePath -> Argument e st s FilePathType

parseArgument :: (Z.GenericTextZipper t)
              => (String -> Maybe (SomeAddress s))
              -> [Some (C.Command e st (Argument e st s) TypeRepr)]
              -> t
              -> (TypeRepr tp -> Maybe (Argument e st s tp))
parseArgument parseAddress cmds =
  let indexCommand m (Some cmd) = M.insert (C.cmdName cmd) (Some cmd) m
      cmdIndex = F.foldl' indexCommand M.empty cmds
  in \(Z.toList -> txt) rep ->
    case rep of
      StringTypeRepr -> Just (StringArgument (T.pack txt))
      IntTypeRepr -> IntArgument <$> readMaybe txt
      WordTypeRepr -> WordArgument <$> readMaybe txt
      AddressTypeRepr -> AddressArgument <$> parseAddress txt
      CommandTypeRepr ->
        let t = T.pack txt
        in CommandArgument <$> M.lookup t cmdIndex
      FilePathTypeRepr -> Just (FilePathArgument txt)

showRepr :: TypeRepr tp -> T.Text
showRepr r =
  case r of
    StringTypeRepr -> "String"
    AddressTypeRepr -> "Address"
    IntTypeRepr -> "Int"
    WordTypeRepr -> "Word"
    CommandTypeRepr -> "Command"
    FilePathTypeRepr -> "FilePath"

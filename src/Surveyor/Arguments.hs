{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ViewPatterns #-}
-- | The types of arguments for commands
module Surveyor.Arguments (
  Argument(..),
  Type(..),
  TypeRepr(..),
  IntType,
  WordType,
  AddressType,
  StringType,
  CommandType,
  showRepr,
  parseArgument
  ) where

import qualified Data.Foldable as F
import qualified Data.Map.Strict as M
import           Data.Parameterized.Classes
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Text as T
import qualified Data.Text.Zipper.Generic as Z
import           Numeric.Natural ( Natural )
import           Text.Read ( readMaybe )

import qualified Brick.Command as C
import qualified Surveyor.Architecture as A

data Type where
  StringType :: Type
  AddressType :: Type
  IntType :: Type
  WordType :: Type
  CommandType :: Type

type StringType = 'StringType
type AddressType = 'AddressType
type IntType = 'IntType
type WordType = 'WordType
type CommandType = 'CommandType

data TypeRepr tp where
  CommandTypeRepr :: TypeRepr CommandType
  StringTypeRepr :: TypeRepr StringType
  AddressTypeRepr :: TypeRepr AddressType
  IntTypeRepr :: TypeRepr IntType
  WordTypeRepr :: TypeRepr WordType

instance TestEquality TypeRepr where
  testEquality CommandTypeRepr CommandTypeRepr = Just Refl
  testEquality StringTypeRepr StringTypeRepr = Just Refl
  testEquality AddressTypeRepr AddressTypeRepr = Just Refl
  testEquality IntTypeRepr IntTypeRepr = Just Refl
  testEquality WordTypeRepr WordTypeRepr = Just Refl
  testEquality _ _ = Nothing

data Argument arch st s tp where
  CommandArgument :: Some (C.Command st (Argument arch st s) TypeRepr) -> Argument arch st s CommandType
  StringArgument :: T.Text -> Argument arch st s StringType
  AddressArgument :: A.Address arch s -> Argument arch st s AddressType
  IntArgument :: Integer -> Argument arch st s IntType
  WordArgument :: Natural -> Argument arch st s WordType

parseArgument :: (A.Architecture arch s, Z.GenericTextZipper t)
              => [Some (C.Command st (Argument arch st s) TypeRepr)]
              -> t
              -> (TypeRepr tp -> Maybe (Argument arch st s tp))
parseArgument cmds =
  let indexCommand m (Some cmd) = M.insert (C.cmdName cmd) (Some cmd) m
      cmdIndex = F.foldl' indexCommand M.empty cmds
  in \(Z.toList -> txt) rep ->
    case rep of
      StringTypeRepr -> Just (StringArgument (T.pack txt))
      IntTypeRepr -> IntArgument <$> readMaybe txt
      WordTypeRepr -> WordArgument <$> readMaybe txt
      AddressTypeRepr -> AddressArgument <$> A.parseAddress txt
      CommandTypeRepr ->
        let t = T.pack txt
        in CommandArgument <$> M.lookup t cmdIndex

showRepr :: TypeRepr tp -> T.Text
showRepr r =
  case r of
    StringTypeRepr -> "String"
    AddressTypeRepr -> "Address"
    IntTypeRepr -> "Int"
    WordTypeRepr -> "Word"
    CommandTypeRepr -> "Command"
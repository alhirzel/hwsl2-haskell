{-# LANGUAGE Trustworthy #-}

-- |
-- Module     : Data.Hash.SL2
-- License    : MIT
-- Maintainer : Sam Rijs <srijs@airpost.net>
--
-- An algebraic hash function, inspired by the paper /Hashing with SL2/ by
-- Tillich and Zemor.
--
-- The hash function is based on matrix multiplication in the special linear group
-- of degree 2, over a Galois field of order 2^127,  with all computations modulo
-- the polynomial x^127 + x^63 + 1.
--
-- This construction gives some nice properties, which traditional bit-scambling
-- hash functions don't possess, including it being composable. It holds:
--
-- prop> hash (m1 <> m2) == hash m1 <> hash m2
--
-- Following that, the hash function is also parallelisable. If a message @m@ can be divided
-- into a list of chunks @cs@, the hash of the message can be calculated in parallel:
--
-- prop> mconcat (parMap rpar hash cs) == hash m
--
-- All operations in this package are implemented in a very efficient manner using SSE instructions.
--

module Data.Hash.SL2
  ( Hash
  -- ** Hashing
  , hash
  , append, prepend
  , foldAppend, foldPrepend
  -- ** Composition
  , unit, concat, concatAll
  -- ** Parsing
  , parse
  -- ** Validation
  , valid, validate
  -- ** Packing
  , pack8, pack16, pack32, pack64
  -- ** Unpacking
  , unpack8, unpack16, unpack32, unpack64
  ) where

import Prelude hiding (concat)

import Data.Semigroup (Semigroup, (<>))

import Data.Hash.SL2.Internal (Hash)
import Data.Hash.SL2.Unsafe
import qualified Data.Hash.SL2.Mutable as Mutable

import System.IO.Unsafe

import Data.ByteString (ByteString)

import Data.Word
import Data.Foldable (foldl', foldr')

instance Show Hash where
  show h = unsafePerformIO $ unsafeUseAsPtr h Mutable.serialize

instance Eq Hash where
  a == b = unsafePerformIO $ unsafeUseAsPtr2 a b Mutable.eq

instance Ord Hash where
  compare a b = unsafePerformIO $ unsafeUseAsPtr2 a b Mutable.cmp

instance Semigroup Hash where
  (<>) = concat

instance Monoid Hash where
  mempty = unit
  mappend = (<>)
  mconcat = concatAll

-- | /O(n)/ Calculate the hash of the 'ByteString'. Alias for @('append' 'unit')@.
hash :: ByteString -> Hash
hash = append unit

-- | /O(n)/ Append the hash of the 'ByteString' to the existing 'Hash'.
-- A significantly faster equivalent of @((. 'hash') . 'concat')@.
append :: Hash -> ByteString -> Hash
append h s = fst $ unsafePerformIO $ Mutable.withCopy h $ Mutable.append s
{-# RULES "hash/concat" forall h s . concat h (hash s) = append h s #-}

-- | /O(n)/ Prepend the hash of the 'ByteString' to the existing 'Hash'.
-- A significantly faster equivalent of @('concat' . 'hash')@.
prepend :: ByteString -> Hash -> Hash
prepend s h = fst $ unsafePerformIO $ Mutable.withCopy h $ Mutable.prepend s
{-# RULES "concat/hash" forall s h . concat (hash s) h = prepend s h #-}

-- | /O(n)/ Append the hash of every 'ByteString' to the existing 'Hash', from left to right.
-- A significantly faster equivalent of @('foldl' 'append')@.
foldAppend :: Foldable t => Hash -> t ByteString -> Hash
foldAppend h ss = fst $ unsafePerformIO $ Mutable.withCopy h $ Mutable.foldAppend ss
{-# RULES "foldl/append" forall h ss . foldl append h ss = foldAppend h ss #-}
{-# RULES "foldl'/append" forall h ss . foldl' append h ss = foldAppend h ss #-}

-- | /O(n)/ Prepend the hash of every 'ByteString' to the existing 'Hash', from right to left.
-- A significantly faster equivalent of @('flip' ('foldr' 'prepend'))@.
foldPrepend :: Foldable t => t ByteString -> Hash -> Hash
foldPrepend ss h = fst $ unsafePerformIO $ Mutable.withCopy h $ Mutable.foldPrepend ss
{-# RULES "foldr/prepend" forall ss h . foldr prepend h ss = foldPrepend ss h #-}
{-# RULES "foldr'/prepend" forall ss h . foldr' prepend h ss = foldPrepend ss h #-}

-- | /O(1)/ The unit element for concatenation. Alias for 'mempty'.
unit :: Hash
unit = fst $ unsafePerformIO $ unsafeWithNew Mutable.unit

-- | /O(1)/ Concatenate two hashes. Alias for 'mappend'.
concat :: Hash -> Hash -> Hash
concat a b = fst $ unsafePerformIO $ unsafeWithNew (unsafeUseAsPtr2 a b . Mutable.concat)
{-# INLINE[1] concat #-}

-- | /O(n)/ Concatenate a list of hashes. Alias for 'mconcat'.
concatAll :: [Hash] -> Hash
concatAll [] = unit
concatAll [h] = h
concatAll (h:hs) = fst $ unsafePerformIO $ Mutable.withCopy h $ \p ->
  mapM_ (flip unsafeUseAsPtr $ Mutable.concat p p) hs

-- | /O(1)/ Parse the representation generated by 'show'.
parse :: String -> Maybe Hash
parse s = uncurry (<$) $ unsafePerformIO $ unsafeWithNew $ Mutable.unserialize s

-- | /O(1)/ Check a hash for bit-level validity.
valid :: Hash -> Bool
valid h = unsafePerformIO $ unsafeUseAsPtr h Mutable.valid

-- | /O(1)/ Validate a hash on the bit-level. From @'valid' h == 'True'@ follows @'validate' h == 'Just' h@.
validate :: Hash -> Maybe Hash
validate h | valid h = Just h
validate _ = Nothing

-- | /O(1)/ Pack a list of 64 8-bit words.
pack8 :: [Word8] -> Maybe Hash
pack8 ws | length ws == 64 = validate (unsafePack ws)
pack8 _ = Nothing

-- | /O(1)/ Pack a list of 32 16-bit words.
pack16 :: [Word16] -> Maybe Hash
pack16 ws | length ws == 32 = validate (unsafePack ws)
pack16 _ = Nothing

-- | /O(1)/ Pack a list of 16 32-bit words.
pack32 :: [Word32] -> Maybe Hash
pack32 ws | length ws == 16 = validate (unsafePack ws)
pack32 _ = Nothing

-- | /O(1)/ Pack a list of 8 64-bit words.
pack64 :: [Word64] -> Maybe Hash
pack64 ws | length ws == 8 = validate (unsafePack ws)
pack64 _ = Nothing

-- | /O(1)/ Unpack into list of 64 8-bit words.
unpack8 :: Hash -> [Word8]
unpack8 = unsafeUnpack

-- | /O(1)/ Unpack into list of 32 16-bit words.
unpack16 :: Hash -> [Word16]
unpack16 = unsafeUnpack

-- | /O(1)/ Unpack into list of 16 32-bit words.
unpack32 :: Hash -> [Word32]
unpack32 = unsafeUnpack

-- | /O(1)/ Unpack into list of 8 64-bit words.
unpack64 :: Hash -> [Word64]
unpack64 = unsafeUnpack

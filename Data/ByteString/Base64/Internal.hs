{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Data.ByteString.Base64.Internal
-- Copyright   : (c) 2010 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Fast and efficient encoding and decoding of base64-encoded strings.

module Data.ByteString.Base64.Internal
    (
      encodeWithAlphabet
    , decodeWithTable
    , decodeLenientWithTable
    , joinWith
    , done
    , peek8, poke8, peek8_32
    ) where

import Data.Bits ((.|.), (.&.), shiftL, shiftR)
import qualified Data.ByteString as B
import Data.ByteString.Internal (ByteString(..), mallocByteString, memcpy,
                                 unsafeCreate)
import Data.Word (Word8, Word16, Word32)
import Foreign.ForeignPtr (ForeignPtr, withForeignPtr, castForeignPtr)
import Foreign.Ptr (Ptr, castPtr, minusPtr, plusPtr)
import Foreign.Storable (peek, peekElemOff, poke)
import System.IO.Unsafe (unsafePerformIO)

peek8 :: Ptr Word8 -> IO Word8
peek8 = peek

poke8 :: Ptr Word8 -> Word8 -> IO ()
poke8 = poke

peek8_32 :: Ptr Word8 -> IO Word32
peek8_32 = fmap fromIntegral . peek8

-- | Encode a string into base64 form.  The result will always be a
-- multiple of 4 bytes in length. This function takes the encoding
-- alphabet (for @base64@ or @base64url@) as the first paramert.
encodeWithAlphabet :: ByteString -> ByteString -> ByteString
encodeWithAlphabet alphabet@(PS alfaFP _ _) (PS sfp soff slen)
    | slen > maxBound `div` 4 =
        error "Data.ByteString.Base64.encode: input too long"
    | otherwise = unsafePerformIO $ do
  let dlen = ((slen + 2) `div` 3) * 4
  dfp <- mallocByteString dlen
  withForeignPtr alfaFP $ \aptr ->
    withForeignPtr encodeTable $ \ep ->
      withForeignPtr sfp $ \sptr -> do
        let aidx n = peek8 (aptr `plusPtr` n)
            sEnd = sptr `plusPtr` (slen + soff)
            fill !dp !sp
              | sp `plusPtr` 2 >= sEnd = complete (castPtr dp) sp
              | otherwise = {-# SCC "encode/fill" #-} do
              i <- peek8_32 sp
              j <- peek8_32 (sp `plusPtr` 1)
              k <- peek8_32 (sp `plusPtr` 2)
              let w = (i `shiftL` 16) .|. (j `shiftL` 8) .|. k
                  enc = peekElemOff ep . fromIntegral
              poke dp =<< enc (w `shiftR` 12)
              poke (dp `plusPtr` 2) =<< enc (w .&. 0xfff)
              fill (dp `plusPtr` 4) (sp `plusPtr` 3)
            complete dp sp
                | sp == sEnd = return ()
                | otherwise  = {-# SCC "encode/complete" #-} do
              let peekSP n f = (f . fromIntegral) `fmap` peek8 (sp `plusPtr` n)
                  twoMore    = sp `plusPtr` 2 == sEnd
                  equals     = 0x3d :: Word8
                  {-# INLINE equals #-}
              a <- peekSP 0 ((`shiftR` 2) . (.&. 0xfc))
              b <- peekSP 0 ((`shiftL` 4) . (.&. 0x03))
              !b' <- if twoMore
                     then peekSP 1 ((.|. b) . (`shiftR` 4) . (.&. 0xf0))
                     else return b
              poke8 dp =<< aidx a
              poke8 (dp `plusPtr` 1) =<< aidx b'
              c <- if twoMore
                   then aidx =<< peekSP 1 ((`shiftL` 2) . (.&. 0x0f))
                   else return equals
              poke8 (dp `plusPtr` 2) c
              poke8 (dp `plusPtr` 3) equals
        withForeignPtr dfp $ \dptr ->
          fill (castPtr dptr) (sptr `plusPtr` soff)
  return $! PS dfp 0 dlen
  where -- The encoding table is constructed such that the expansion of a 12bit block
        -- to a 16bit block can be done by a single Word16 copy from the correspoding
        -- table entry to the target address. The 16bit blocks are stored in big-endian
        -- order, as the indices into the table are built in big-endian order.
        encodeTable :: ForeignPtr Word16
        encodeTable = 
            case table of PS fp _ _ -> castForeignPtr fp
          where
            ix    = fromIntegral . B.index alphabet
            table = B.pack $ concat $ [ [ix j, ix k] | j <- [0..63], k <- [0..63] ]
        {-# NOINLINE encodeTable #-}

-- | Efficiently intersperse a terminator string into another at
-- regular intervals, and terminate the input with it.
--
-- Examples:
--
-- > joinWith "|" 2 "----" = "--|--|"
--
-- > joinWith "\r\n" 3 "foobarbaz" = "foo\r\nbar\r\nbaz\r\n"
joinWith :: ByteString  -- ^ String to intersperse and end with
         -> Int         -- ^ Interval at which to intersperse, in bytes
         -> ByteString  -- ^ String to transform
         -> ByteString
joinWith brk@(PS bfp boff blen) every bs@(PS sfp soff slen)
    | every <= 0 = error "invalid interval"
    | blen <= 0  = bs
    | B.null bs = brk
    | otherwise =
  unsafeCreate dlen $ \dptr ->
    withForeignPtr bfp $ \bptr -> do
      withForeignPtr sfp $ \sptr -> do
          let bp = bptr `plusPtr` boff
          let dEnd = dptr `plusPtr` dlen
              loop !dp !sp | dp >= dEnd = return ()
                           | otherwise = do
                let n = min every (dEnd `minusPtr` dp)
                memcpy dp sp (fromIntegral n)
                memcpy (dp `plusPtr` n) bp (fromIntegral blen)
                loop (dp `plusPtr` (n + blen)) (sp `plusPtr` every)
          loop dptr (sptr `plusPtr` soff)
  where dlen = slen + blen * numBreaks
        numBreaks = slen `div` every

-- | Decode a base64-encoded string.  This function strictly follows
-- the specification in RFC 4648,
-- <http://www.apps.ietf.org/rfc/rfc4648.html>.
-- This function takes the decoding table (for @base64@ or @base64url@) as 
-- the first paramert.
decodeWithTable :: ForeignPtr Word8 -> ByteString -> Either String ByteString
decodeWithTable decodeFP (PS sfp soff slen)
    | drem /= 0 = Left "invalid padding"
    | dlen <= 0 = Right B.empty
    | otherwise = unsafePerformIO $ do
  dfp <- mallocByteString dlen
  withForeignPtr decodeFP $ \decptr -> do
    let finish dbytes = return . Right $! if dbytes > 0
                                          then PS dfp 0 dbytes
                                          else B.empty
        bail = return . Left
    withForeignPtr sfp $ \sptr -> do
      let sEnd = sptr `plusPtr` (slen + soff)
          look p = do
            ix <- fromIntegral `fmap` peek8 p
            v <- peek8 (decptr `plusPtr` ix)
            return $! fromIntegral v :: IO Word32
          fill !dp !sp !n
            | sp >= sEnd = finish n
            | otherwise = {-# SCC "decodeWithTable/fill" #-} do
            a <- look sp
            b <- look (sp `plusPtr` 1)
            c <- look (sp `plusPtr` 2)
            d <- look (sp `plusPtr` 3)
            let w = (a `shiftL` 18) .|. (b `shiftL` 12) .|.
                    (c `shiftL` 6) .|. d
            if a == done || b == done
              then bail $ "invalid padding near offset " ++
                   show (sp `minusPtr` sptr)
              else if a .|. b .|. c .|. d == x
              then bail $ "invalid base64 encoding near offset " ++
                   show (sp `minusPtr` sptr)
              else do
                poke8 dp $ fromIntegral (w `shiftR` 16)
                if c == done
                  then finish $ n + 1
                  else do
                    poke8 (dp `plusPtr` 1) $ fromIntegral (w `shiftR` 8)
                    if d == done
                      then finish $! n + 2
                      else do
                        poke8 (dp `plusPtr` 2) $ fromIntegral w
                        fill (dp `plusPtr` 3) (sp `plusPtr` 4) (n+3)
      withForeignPtr dfp $ \dptr ->
        fill dptr (sptr `plusPtr` soff) 0
  where (di,drem) = slen `divMod` 4
        dlen = di * 3

data D = D { dNext :: {-# UNPACK #-} !(Ptr Word8)
           , dValue :: {-# UNPACK #-} !Word32 }

-- | Decode a base64-encoded string.  This function is lenient in
-- following the specification from RFC 4648,
-- <http://www.apps.ietf.org/rfc/rfc4648.html>, and will not generate
-- parse errors no matter how poor its input.
-- This function takes the decoding table (for @base64@ or @base64url@) as 
-- the first paramert.
decodeLenientWithTable :: ForeignPtr Word8 -> ByteString -> ByteString
decodeLenientWithTable decodeFP (PS sfp soff slen)
    | dlen <= 0 = B.empty
    | otherwise = unsafePerformIO $ do
  dfp <- mallocByteString dlen
  dbytes <- withForeignPtr decodeFP $ \decptr ->
    withForeignPtr sfp $ \sptr -> do
      let sEnd = sptr `plusPtr` (slen + soff)
          fill !dp !sp !n
            | sp >= sEnd = return n
            | otherwise = {-# SCC "decodeLenientWithTable/fill" #-} do
            let look skipPad = go
                  where
                    go p | p >= sEnd = return $! D (sEnd `plusPtr` (-1)) done
                         | otherwise =  {-# SCC "decodeLenient/look" #-} do
                      ix <- fromIntegral `fmap` peek8 p
                      v <- peek8 (decptr `plusPtr` ix)
                      if v == x || (v == done && skipPad)
                        then go (p `plusPtr` 1)
                        else return $! D (p `plusPtr` 1) (fromIntegral v)
            !a <- look True  sp
            !b <- look True  (dNext a)
            !c <- look False (dNext b)
            !d <- look False (dNext c)
            let w = (dValue a `shiftL` 18) .|. (dValue b `shiftL` 12) .|.
                    (dValue c `shiftL` 6) .|. dValue d
            if dValue a == done || dValue b == done
              then return n
              else do
                poke8 dp $ fromIntegral (w `shiftR` 16)
                if dValue c == done
                  then return $! n + 1
                  else do
                    poke8 (dp `plusPtr` 1) $ fromIntegral (w `shiftR` 8)
                    if dValue d == done
                      then return $! n + 2
                      else do
                        poke8 (dp `plusPtr` 2) $ fromIntegral w
                        fill (dp `plusPtr` 3) (dNext d) (n+3)
      withForeignPtr dfp $ \dptr ->
        fill dptr (sptr `plusPtr` soff) 0
  return $! if dbytes > 0
            then PS dfp 0 dbytes
            else B.empty
  where dlen = ((slen + 3) `div` 4) * 3

x :: Integral a => a
x = 255
{-# INLINE x #-}

done :: Integral a => a
done = 99
{-# INLINE done #-}

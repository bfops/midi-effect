{-# LANGUAGE NoImplicitPrelude
           , TemplateHaskell
           #-}
module Sound.MIDI.Monad.Core ( MIDI
                             , MIDIContext (..)
                             , seqT'
                             , qT'
                             , connsOut'
                             , connsIn'
                             , instrChannels'
                             , channels'
                             , ioMIDI
                             , runMIDI
                             ) where

import Prelewd

import IO
import STM

import Data.Word
import Storage.Map
import Storage.Refcount
import Template.MemberTransformer

import qualified Sound.ALSA.Sequencer.Address as Addr
import qualified Sound.ALSA.Sequencer.Client as C
import qualified Sound.ALSA.Sequencer.Connect as Connect
import qualified Sound.ALSA.Sequencer.Port as P
import qualified Sound.ALSA.Sequencer.Event as E
import qualified Sound.ALSA.Sequencer.Queue as Q
import qualified Sound.ALSA.Sequencer as S

-- | Context for MIDI I/O actions
data MIDIContext = MIDIContext
            { seqT          :: S.T S.DuplexMode             -- ^ Sequencer handle
            , qT            :: Q.T                          -- ^ Queue handle
            , connsOut      :: [Connect.T]                  -- ^ Outbound connection handles
            , connsIn       :: [Connect.T]                  -- ^ Inbound connection handles
            , instrChannels :: TVar (Map Word8 E.Channel)   -- ^ What instrument's on what
                                                            -- channel?
            , channels      :: TVar (Refcount E.Channel)    -- ^ What channels are in use?
            }

$(memberTransformers ''MIDIContext)

-- | MIDI I/O type
newtype MIDI a = MIDI { raw :: MIDIContext -> IO a }

instance Monad MIDI where
    return = MIDI . return . return
    (MIDI m) >>= f = MIDI $ \h -> m h >>= ($ h) . raw . f

instance MonadPlus MIDI where
    mzero = empty
    mplus = (<|>)

instance Alternative MIDI where
    empty = MIDI $ \_-> empty
    MIDI f <|> MIDI g = MIDI $ liftA2 (<|>) f g

instance Applicative MIDI where
    pure = return
    (<*>) = ap

instance Functor MIDI where fmap = liftA

-- | Perform MIDI I/O
runMIDI :: Text                         -- ^ Client name
        -> [Text]                       -- ^ MIDI output destinations
        -> [Text]                       -- ^ MIDI input sources
        -> MIDI ()                      -- ^ MIDI action
        -> IO ()
runMIDI name outputs inputs m = io $ S.withDefault S.Nonblock $ \h -> do
        C.setName h name
        P.withSimple h "io"
            (P.caps [P.capRead, P.capSubsRead, P.capWrite])
            (P.types [P.typeMidiGeneric, P.typeApplication])
            $ \p -> Q.with h $ \q -> do
                    dests <- parseAndCreatePorts Connect.createTo h p outputs
                    sources <- parseAndCreatePorts Connect.createFrom h p inputs
                    Q.control h q E.QueueStart Nothing
                    instruments <- newTVarIO mempty
                    chnls <- newTVarIO mempty
                    runIO $ raw m $ MIDIContext
                            { seqT              = h
                            , qT                = q
                            , connsOut          = dests
                            , connsIn           = sources
                            , instrChannels     = instruments
                            , channels          = chnls
                            }
    where
        parseAndCreatePorts ctor h p = traverse $ \port -> Addr.parse h port >>= ctor h p

-- | Lift IO to MIDI I/O
ioMIDI :: (MIDIContext -> IO a) -> MIDI a
ioMIDI = MIDI

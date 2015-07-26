-- |
-- Copyright: (C) 2015 Tweag I/O Limited.
--
-- Bindings for @<R/R_ext/eventloop.h>@, for building event loops.

{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}

module Foreign.R.EventLoop
  ( InputHandler(..)
  , inputHandlers
  , polledEvents
  , pollingPeriod
  , graphicsPolledEvents
  , graphicsPollingPeriod
  , checkActivity
  , runHandlers
  ) where

import Control.Applicative
import Foreign (FunPtr, Ptr, Storable(..), castPtr)
import Foreign.C
import System.Posix.Types (Fd(..))
import Prelude -- Silence AMP warning.

#include <R_ext/eventloop.h>

-- | R input handler chain. Each input handler points to the next. This view of
-- input handlers is /shallow/, in the sense that the 'Storable' instance only
-- unmarshalls the first element in the chain at any one time. A shallow view
-- allows 'peek' and 'poke' to be inlinable.
data InputHandler = InputHandler
  { -- | The input handler callback.
    inputHandlerCallback :: FunPtr (Ptr () -> IO ())
    -- | Undocumented and currently unused.
  , inputHandlerActivity :: CInt
    -- | Whether this input handler is activated or deactivated.
  , inputHandlerActive :: CInt
    -- | The file descriptor ahssociated with this handler.
  , inputHandlerFD :: Fd
    -- | Callbacks can optionally be passed in arbitrary data.
  , inputHandlerUserData :: Ptr ()
    -- | The next input handler in the chain.
  , inputHandlerNext :: Ptr InputHandler
  } deriving (Eq, Show)
{#pointer *InputHandler as InputHandler nocode#}

instance Storable InputHandler where
  sizeOf _ = {#sizeof InputHandler#}
  alignment _ = {#alignof InputHandler#}
  peek hptr = InputHandler <$>
      {#get InputHandler->handler#} hptr <*>
      {#get InputHandler->activity#} hptr <*>
      {#get InputHandler->active#} hptr <*>
      (Fd <$> {#get InputHandler->fileDescriptor#} hptr) <*>
      {#get InputHandler->userData#} hptr <*>
      (castPtr <$> {#get InputHandler->next#} hptr)
  poke hptr InputHandler{..} = do
    {#set InputHandler->handler#} hptr inputHandlerCallback
    {#set InputHandler->activity#} hptr inputHandlerActivity
    {#set InputHandler->active#} hptr inputHandlerActive
    {#set InputHandler->fileDescriptor#} hptr (case inputHandlerFD of Fd fd -> fd)
    {#set InputHandler->userData#} hptr inputHandlerUserData
    {#set InputHandler->next#} hptr (castPtr inputHandlerNext)

-- | @R_PolledEvents@ global variable.
foreign import ccall "&R_PolledEvents" polledEvents :: Ptr (FunPtr (IO ()))

-- | @R_wait_usec@ global variable.
foreign import ccall "&R_wait_usec" pollingPeriod :: Ptr CInt

-- | @R_PolledEvents@ global variable.
foreign import ccall "&Rg_PolledEvents" graphicsPolledEvents :: Ptr (FunPtr (IO ()))

-- | @R_wait_usec@ global variable.
foreign import ccall "&Rg_wait_usec" graphicsPollingPeriod :: Ptr CInt

-- | Input handlers used in event loops.
foreign import ccall "&R_InputHandlers" inputHandlers :: Ptr (Ptr InputHandler)

data FdSet

foreign import ccall unsafe "R_checkActivity" checkActivity :: CInt -> CInt -> IO (Ptr FdSet)

foreign import ccall unsafe "R_runHandlers" runHandlers :: Ptr InputHandler -> Ptr FdSet -> IO ()

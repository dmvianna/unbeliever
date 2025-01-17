{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_HADDOCK prune #-}

{- |
Utility functions for running 'Program' actions concurrently.

Haskell uses green threads: small lines of work that are scheduled down onto
actual execution contexts (set by default by this library to be one per core).
Haskell threads are incredibly lightweight, and you are encouraged to use them
freely. Haskell provides a rich ecosystem of tools to do work concurrently and
to communicate safely between threads.

This module provides wrappers around some of these primatives so you can use
them easily from the 'Program' monad.

Note that when you fire off a new thread the top-level application state is
/shared/; it's the same @τ@ inherited from the parent 'Program'.
-}
module Core.Program.Threads
    ( -- * Concurrency
      createScope
    , forkThread
    , forkThread_
    , linkThread
    , waitThread
    , waitThread_
    , waitThread'
    , waitThreads'
    , cancelThread

      -- * Helper functions
    , concurrentThreads
    , concurrentThreads_
    , raceThreads
    , raceThreads_

      -- * Internals
    , Thread
    , unThread
    ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (modifyTVar', newTVarIO, readTVarIO)
import Control.Exception.Safe qualified as Safe (catch, finally, onException, throw)
import Control.Monad
    ( forM
    , forM_
    , void
    )
import Control.Monad.Reader.Class (MonadReader (ask))
import Core.Data.Structures
import Core.Program.Context
import Core.Program.Logging
import Core.System.Base
import Core.Text.Rope

{- |
A thread for concurrent computation.

(this wraps __base__'s 'Control.Concurrent.ThreadId' along with a holder for
the result of the thread)

@since 0.6.0
-}
data Thread α = Thread
    { threadPointerOf :: ThreadId
    , threadOutcomeOf :: MVar (Either SomeException α)
    }

unThread :: Thread α -> ThreadId
unThread = threadPointerOf

{- |
Create a scope to enclose any subsequently spawned threads as a single group.
Ordinarily threads launched in Haskell are completely indepedent. Creating a
scope allows you to operate on a set of threads as a single group with
bi-directional exception passing. This is the basis of an approach called
/structured concurrency/.

When the execution flow exits the scope, any threads that were spawned within
it that are still running will be killed.

If any of the child threads within the scope throws an exception, the other
remaining threads will be killed and then the original exception will be
propegated to this parent thread and re-thrown.

@since 0.6.0
-}
createScope :: Program τ α -> Program τ α
createScope program = do
    context <- ask

    liftIO $ do
        scope <- newTVarIO emptySet

        let context' =
                context
                    { currentScopeFrom = scope
                    }

        Safe.finally
            ( do
                subProgram context' program
            )
            ( do
                pointers <- readTVarIO scope
                forM_ pointers killThread
            )

{- |
Fork a thread. The child thread will run in the same 'Context' as the calling
'Program', including sharing the user-defined application state value.

If you want to find out what the result of a thread was use 'waitThread' on
the 'Thread' object returned from this function. If you don't need the
result, use 'forkThread_' instead.

Threads that are launched off as children are on their own! If the code in the
child thread throws an exception that is /not/ caught within that thread, the
exception will kill the thread. Threads dying without telling anyone is a bit
of an anti-pattern, so this library logs a warning-level log message if this
happens.

(this wraps __base__'s 'Control.Concurrent.forkIO')

@since 0.2.7
-}
forkThread :: Program τ α -> Program τ (Thread α)
forkThread program = do
    context <- ask
    let i = startTimeFrom context
    let v = currentDatumFrom context
    let scope = currentScopeFrom context

    liftIO $ do
        -- if someone calls resetTimer in the thread it should just be that
        -- thread's local duration that is affected, not the parent. We simply
        -- make a new MVar and copy the current start time into it.

        start <- readMVar i
        i' <- newMVar start

        -- we also need to fork the current Datum, in the same way that we do
        -- when we create a nested span. We do this simply by creating a new
        -- MVar so that when the new thread updates the attached metadata
        -- it'll be evolving a different object.

        datum <- readMVar v
        v' <- newMVar datum

        let context' =
                context
                    { startTimeFrom = i'
                    , currentDatumFrom = v'
                    }

        -- fork, and run nested program

        outcome <- newEmptyMVar

        pointer <- forkIO $ do
            Safe.catch
                ( do
                    actual <- subProgram context' program
                    putMVar outcome (Right actual)
                )
                ( \(e :: SomeException) -> do
                    let text = intoRope (displayException e)
                    subProgram context' $ do
                        internal "Uncaught exception ending thread"
                        internal ("e = " <> text)
                    putMVar outcome (Left e)
                )

        atomically $ do
            modifyTVar' scope (\pointers -> insertElement pointer pointers)

        return
            ( Thread
                { threadPointerOf = pointer
                , threadOutcomeOf = outcome
                }
            )

{- |
Fork a thread with 'forkThread' but do not wait for a result. This is on the
assumption that the sub program will either be a side-effect and over quickly,
or long-running daemon thread (presumably containing a 'Control.Monad.forever'
loop in it), never returning.

@since 0.5.2
-}
forkThread_ :: Program τ α -> Program τ ()
forkThread_ = void . forkThread

{- |
Wait for the completion of a thread, returning the result. This is a blocking
operation.

If the thread you are waiting on throws an exception it will be rethrown by
'waitThread'.

If the current thread making this call is cancelled (as a result of being on
the losing side of 'concurrentThreads' or 'raceThreads' for example, or due to
the current scope exiting), then the thread you are waiting on will be
cancelled too. This is necessary to ensure that child threads are not leaked
if you nest `forkThread`s.

@since 0.2.7
-}
waitThread :: Thread α -> Program τ α
waitThread thread = do
    result <- waitThread' thread

    case result of
        Left problem -> Safe.throw problem
        Right actual -> pure actual

{- |
Wait for the completion of a thread, discarding its result. This is
particularly useful at the end of a do-block if you're waiting on a worker
thread to finish but don't need its return value, if any; otherwise you have
to explicily deal with the unused return value:

@
    _ <- 'waitThread' t1
    'return' ()
@

which is a bit tedious. Instead, you can just use this convenience function:

@
    'waitThread_' t1
@

The trailing underscore in the name of this function follows the same
convetion as found in "Control.Monad", which has 'Control.Monad.mapM_' which
does the same as 'Control.Monad.mapM' but which likewise discards the return
value.

@since 0.2.7
-}
waitThread_ :: Thread α -> Program τ ()
waitThread_ thread = void (waitThread thread)

{- |
Wait for a thread to complete, returning the result if the computation was
successful or the exception if one was thrown by the child thread.

This basically is convenience for calling `waitThread` and putting `catch`
around it, but as with all the other @wait*@ functions this ensures that if
the thread waiting is killed the cancellation is propagated to the thread
being watched as well.

@since 0.4.5
-}
waitThread' :: Thread α -> Program τ (Either SomeException α)
waitThread' thread = do
    context <- ask
    let scope = currentScopeFrom context
    let outcome = threadOutcomeOf thread
    let pointer = threadPointerOf thread

    liftIO $ do
        Safe.onException
            ( do
                result <- readMVar outcome -- blocks!
                atomically $ do
                    modifyTVar' scope (\pointers -> removeElement pointer pointers)
                pure result
            )
            ( do
                killThread pointer
                atomically $ do
                    modifyTVar' scope (\pointers -> removeElement pointer pointers)
            )

{- |
Wait for many threads to complete. This function is intended for the scenario
where you fire off a number of worker threads with `forkThread` but rather
than leaving them to run independantly, you need to wait for them all to
complete.

The results of the threads that complete successfully will be returned as
'Right' values. Should any of the threads being waited upon throw an
exception, those exceptions will be returned as 'Left' values.

If you don't need to analyse the failures individually, then you can just
collect the successes using "Data.Either"'s 'Data.Either.rights':

@
    responses <- 'waitThreads''

    'info' "Aggregating results..."
    combineResults ('Data.Either.rights' responses)
@

Likewise, if you /do/ want to do something with all the failures, you might
find 'Data.Either.lefts' useful:

@
    'mapM_' ('warn' . 'intoRope' . 'displayException') ('Data.Either.lefts' responses)
@

If the thread calling 'waitThreads'' is cancelled, then all the threads being
waited upon will also be cancelled. This often occurs within a timeout or
similar control measure implemented using 'raceThreads_'. Should the thread
that spawned all the workers and is waiting for their results be told to
cancel because it lost the "race", the child threads need to be told in turn
to cancel so as to avoid those threads being leaked and continuing to run as
zombies. This function takes care of that.

(this extends 'waitThread'' to work across a list of Threads, taking care to
ensure the cancellation behaviour described throughout this module)

@since 0.4.5
-}
waitThreads' :: [Thread α] -> Program τ [Either SomeException α]
waitThreads' threads = do
    context <- ask
    liftIO $ do
        Safe.onException
            ( do
                subProgram context $ do
                    forM threads waitThread'
            )
            ( do
                --
                -- This is here because if this thread is cancelled it will
                -- only be _one_ of the waitThread above that receives the
                -- exception. All the other child threads need to be killed
                -- too.
                --

                let scope = currentScopeFrom context

                forM_ threads $ \thread -> do
                    let pointer = threadPointerOf thread
                    killThread pointer

                    atomically $ do
                        modifyTVar' scope (\pointers -> removeElement pointer pointers)
            )

{- |
Cancel a thread.

(this wraps __base__\'s 'Control.Concurrent.killThread'. The underlying
mechanism used is to throw the 'GHC.Conc.ThreadKilled' exception to the other
thread. That exception is asynchronous, so will not be trapped by a
'Core.Program.Exceptions.catch' block and will indeed cause the thread
receiving the exception to come to an end)

@since 0.4.5
-}
cancelThread :: Thread α -> Program τ ()
cancelThread thread = do
    liftIO $ do
        killThread (threadPointerOf thread)

{- |
Fork two threads and wait for both to finish. The return value is the pair of
each action's return types.

This is the same as calling 'forkThread' and 'waitThread' twice, except that
if either sub-program fails with an exception the other program which is still
running will be cancelled and the original exception is then re-thrown.

@
    (a,b) <- 'concurrentThreads' one two

    -- continue, doing something with both results.
@

For a variant that ingores the return values and just waits for both see
'concurrentThreads_' below.

@since 0.4.0
-}
concurrentThreads :: Program τ α -> Program τ β -> Program τ (α, β)
concurrentThreads one two = do
    createScope $ do
        a1 <- forkThread one
        a2 <- forkThread two
        result1 <- waitThread a1
        result2 <- waitThread a2
        pure (result1, result2)

{- |
Fork two threads and wait for both to finish.

This is the same as calling 'forkThread' and 'waitThread_' twice, except that
if either sub-program fails with an exception the other program which is still
running will be cancelled and the original exception is then re-thrown.

@since 0.4.0
-}
concurrentThreads_ :: Program τ α -> Program τ β -> Program τ ()
concurrentThreads_ one two = void (concurrentThreads one two)

{- |
Fork two threads and race them against each other. This blocks until one or
the other of the threads finishes. The return value will be 'Left' @α@ if the
first program (@one@) completes first, and 'Right' @β@ if it is the second
program (@two@) which finishes first. The sub program which is still running
will be cancelled with an exception.

@
    result <- 'raceThreads' one two
    case result of
        'Left' a -> do
            -- one finished first
        'Right' b -> do
            -- two finished first
@

For a variant that ingores the return value and just races the threads see
'raceThreads_' below.

@since 0.4.0
-}
raceThreads :: Program τ α -> Program τ β -> Program τ (Either α β)
raceThreads one two = do
    createScope $ do
        outcome <- liftIO $ do
            newEmptyMVar

        _ <- forkThread $ do
            !result1 <- one
            liftIO $ do
                putMVar outcome (Left result1)

        _ <- forkThread $ do
            !result2 <- two
            liftIO $ do
                putMVar outcome (Right result2)

        liftIO $ do
            readMVar outcome

{- |
Fork two threads and race them against each other. When one action completes
the other will be cancelled with an exception. This is useful for enforcing
timeouts:

@
    'raceThreads_'
        ('Core.Program.Execute.sleepThread' 300)
        (do
            -- We expect this to complete within 5 minutes.
            performAction
        )
@

@since 0.4.0
-}
raceThreads_ :: Program τ α -> Program τ β -> Program τ ()
raceThreads_ one two = void (raceThreads one two)

linkThread :: Thread α -> Program τ ()
linkThread _ = pure ()
{-# DEPRECATED linkThread "Exceptions are bidirectional so linkThread no longer needed" #-}

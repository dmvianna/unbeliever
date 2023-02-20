module Core.Program.Class where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader (..), ReaderT (..))
import Core.Program.Context (Program)

{- |
Class of monads based on 'Program'
-}
class (MonadIO ν) => MonadProgram ν where
    -- |
    -- Because 'Program' expects a type variable @τ@ as an application
    -- state, we need to pass it to 'liftProgram'.
    liftProgram :: τ -> Program τ α -> ν α

class (MonadIO ν, MonadReader τ ν) => ReaderProgram τ ν α where
    -- | Get the immutable program state (@τ@) from @ReaderT@.
    liftReaderProgram :: Program τ α -> ReaderT τ ν α

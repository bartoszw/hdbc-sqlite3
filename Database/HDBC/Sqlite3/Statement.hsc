-- -*- mode: haskell; -*-
{-# CFILES hdbc-sqlite3-helper.c #-}
-- Above line for Hugs
{- 
Copyright (C) 2005 John Goerzen <jgoerzen@complete.org>

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

-}
module Database.HDBC.Sqlite3.Statement where
import Database.HDBC.Types
import Database.HDBC
import Database.HDBC.Sqlite3.Types
import Database.HDBC.Sqlite3.Utils
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Ptr
import Control.Concurrent.MVar
import Foreign.C.String
import Foreign.Marshal
import Foreign.Storable
import Control.Monad
import qualified Data.ByteString as B
import Data.List
import Control.Exception
import Database.HDBC.DriverUtils

#include <sqlite3.h>

{- One annoying thing about Sqlite is that a disconnect operation will actually
fail if there are any active statements.  This is highly annoying, and makes
for some somewhat complex algorithms. -}

data StoState = Empty           -- ^ Not initialized or last execute\/fetchrow had no results
              | Prepared Stmt   -- ^ Prepared but not executed
              | Executed Stmt   -- ^ Executed and more rows are expected

instance Show StoState where
    show Empty = "Empty"
    show (Prepared _) = "Prepared"
    show (Executed _) = "Executed"

data SState = SState {dbo :: Sqlite3,
                      stomv :: MVar StoState,
                      querys :: String,
                      colnamesmv :: MVar [String]}

newSth :: Sqlite3 -> ChildList -> String -> IO Statement
newSth indbo mchildren str = 
    do newstomv <- newMVar Empty
       newcolnamesmv <- newMVar []
       let sstate = SState{dbo = indbo,
                           stomv = newstomv,
                           querys = str,
                           colnamesmv = newcolnamesmv}
       modifyMVar_ (stomv sstate) (\_ -> (fprepare sstate >>= return . Prepared))
       let retval = 
               Statement {execute = fexecute sstate,
                           executeMany = fexecutemany sstate,
                           finish = public_ffinish sstate,
                           fetchRow = ffetchrow sstate,
                           originalQuery = str,
                           getColumnNames = readMVar (colnamesmv sstate),
                           describeResult = fail "Sqlite3 backend does not support describeResult"}
       addChild mchildren retval
       return retval

{- The deal with adding the \0 below is in response to an apparent bug in
sqlite3.  See debian bug #343736. 

This function assumes that any existing query in the state has already
been terminated.  (FIXME: should check this at runtime.... never run fprepare
unless state is Empty)
-}
fprepare :: SState -> IO Stmt
fprepare sstate = withRawSqlite3 (dbo sstate)
  (\p -> withCStringLen ((querys sstate) ++ "\0")
   (\(cs, cslen) -> alloca
    (\(newp::Ptr (Ptr CStmt)) -> 
     (do res <- sqlite3_prepare p cs (fromIntegral cslen) newp nullPtr
         checkError ("prepare " ++ (show cslen) ++ ": " ++ (querys sstate)) 
                    (dbo sstate) res
         newo <- peek newp
         newForeignPtr sqlite3_finalizeptr newo
     )
     )
   )
   )
                 

{- General algorithm: find out how many columns we have, check the type
of each to see if it's NULL.  If it's not, fetch it as text and return that.

Note that execute() will have already loaded up the first row -- and we
do that each time.  so this function returns the row that is already in sqlite,
then loads the next row. -}
ffetchrow :: SState -> IO (Maybe [SqlValue])
ffetchrow sstate = modifyMVar (stomv sstate) dofetchrow
    where dofetchrow Empty = return (Empty, Nothing)
          dofetchrow (Prepared _) = 
              throwDyn $ SqlError {seState = "HDBC Sqlite3 fetchrow",
                                   seNativeError = (-1),
                                   seErrorMsg = "Attempt to fetch row from Statement that has not been executed.  Query was: " ++ (querys sstate)}
          dofetchrow (Executed sto) = withStmt sto (\p ->
              do ccount <- sqlite3_column_count p
                 -- fetch the data
                 res <- mapM (getCol p) [0..(ccount - 1)]
                 r <- fstep (dbo sstate) p
                 if r
                    then return (Executed sto, Just res)
                    else do ffinish (dbo sstate) sto
                            return (Empty, Just res)
                                                         )
 
          getCol p icol = 
             do t <- sqlite3_column_type p icol
                if t == #{const SQLITE_NULL}
                   then return SqlNull
                   else do text <- sqlite3_column_text p icol
                           len <- sqlite3_column_bytes p icol
                           s <- peekCStringLen (text, fromIntegral len)
                           return (SqlString s)

fstep :: Sqlite3 -> Ptr CStmt -> IO Bool
fstep dbo p =
    do r <- sqlite3_step p
       case r of
         #{const SQLITE_ROW} -> return True
         #{const SQLITE_DONE} -> return False
         #{const SQLITE_ERROR} -> checkError "step" dbo #{const SQLITE_ERROR}
                                   >> (throwDyn $ SqlError 
                                          {seState = "",
                                           seNativeError = 0,
                                           seErrorMsg = "In HDBC step, internal processing error (got SQLITE_ERROR with no error)"})
         x -> throwDyn $ SqlError {seState = "",
                                   seNativeError = fromIntegral x,
                                   seErrorMsg = "In HDBC step, unexpected result from sqlite3_step"}

fexecute sstate args = modifyMVar (stomv sstate) doexecute
    where doexecute (Executed sto) = ffinish (dbo sstate) sto >> doexecute Empty
          doexecute Empty =     -- already cleaned up from last time
              do sto <- fprepare sstate
                 doexecute (Prepared sto)
          doexecute (Prepared sto) = withStmt sto (\p -> 
              do c <- sqlite3_bind_parameter_count p
                 when (c /= genericLength args)
                   (throwDyn $ SqlError {seState = "",
                                         seNativeError = (-1),
                                         seErrorMsg = "In HDBC execute, received " ++ (show args) ++ " but expected " ++ (show c) ++ " args."})
                 sqlite3_reset p >>= checkError "execute (reset)" (dbo sstate)
                 zipWithM_ (bindArgs p) [1..c] args

                 {- Logic for handling counts of changes: look at the total
                    changes before and after the query.  If they differ,
                    then look at the local changes.  (The local change counter
                    appears to not be updated unless really running a query
                    that makes a change, according to the docs.)

                    This is OK thread-wise because SQLite doesn't support
                    using a given dbh in more than one thread anyway. -}
                 origtc <- withSqlite3 (dbo sstate) sqlite3_total_changes 
                 r <- fstep (dbo sstate) p
                 newtc <- withSqlite3 (dbo sstate) sqlite3_total_changes
                 changes <- if origtc == newtc
                               then return 0
                               else withSqlite3 (dbo sstate) sqlite3_changes
                 fgetcolnames p >>= swapMVar (colnamesmv sstate)
                 if r
                    then return (Executed sto, fromIntegral changes)
                    else do ffinish (dbo sstate) sto
                            return (Empty, fromIntegral changes)
                                                        )
          bindArgs p i SqlNull =
              sqlite3_bind_null p i >>= 
                checkError ("execute (binding NULL column " ++ (show i) ++ ")")
                           (dbo sstate)
          bindArgs p i (SqlByteString bs) =
              B.useAsCStringLen bs (bindCStringArgs p i)
          bindArgs p i arg = withCStringLen (fromSql arg) (bindCStringArgs p i)

          bindCStringArgs p i (cs, len) =
              do r <- sqlite3_bind_text2 p i cs (fromIntegral len)
                 checkError ("execute (binding column " ++ 
                             (show i) ++ ")") (dbo sstate) r

fgetcolnames csth =
        do count <- sqlite3_column_count csth
           mapM (getCol csth) [0..(count -1)]
    where getCol csth i =
              do cstr <- sqlite3_column_name csth i
                 peekCString cstr

-- FIXME: needs a faster algorithm.
fexecutemany sstate arglist =
    mapM_ (fexecute sstate) arglist

--ffinish o = withForeignPtr o (\p -> sqlite3_finalize p >>= checkError "finish")
-- Finish and change state
public_ffinish sstate = modifyMVar_ (stomv sstate) worker
    where worker (Empty) = return Empty
          worker (Prepared sto) = ffinish (dbo sstate) sto >> return Empty
          worker (Executed sto) = ffinish (dbo sstate) sto >> return Empty
    
ffinish dbo o = withRawStmt o (\p -> do r <- sqlite3_finalize p
                                        checkError "finish" dbo r)

foreign import ccall unsafe "hdbc-sqlite3-helper.h &sqlite3_finalize_finalizer"
  sqlite3_finalizeptr :: FunPtr ((Ptr CStmt) -> IO ())

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_finalize_app"
  sqlite3_finalize :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_prepare2"
  sqlite3_prepare :: (Ptr CSqlite3) -> CString -> CInt -> Ptr (Ptr CStmt) -> Ptr (Ptr CString) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_bind_parameter_count"
  sqlite3_bind_parameter_count :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_step"
  sqlite3_step :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_reset"
  sqlite3_reset :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_count"
  sqlite3_column_count :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_name"
  sqlite3_column_name :: Ptr CStmt -> CInt -> IO CString

foreign import ccall unsafe "sqlite3.h sqlite3_column_type"
  sqlite3_column_type :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_text"
  sqlite3_column_text :: (Ptr CStmt) -> CInt -> IO CString

foreign import ccall unsafe "sqlite3.h sqlite3_column_bytes"
  sqlite3_column_bytes :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_bind_text2"
  sqlite3_bind_text2 :: (Ptr CStmt) -> CInt -> CString -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_bind_null"
  sqlite3_bind_null :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_changes"
  sqlite3_changes :: Ptr CSqlite3 -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_total_changes"
  sqlite3_total_changes :: Ptr CSqlite3 -> IO CInt

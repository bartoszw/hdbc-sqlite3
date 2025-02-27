{-# CFILES hdbc-sqlite3-helper.c #-}
-- above line for hugs

module Database.HDBC.Sqlite3.Connection 
	(connectSqlite3, connectSqlite3Raw, Impl.Connection()
        ,Pragma (..), PragmaSynchronousValue (..))
 where

import Database.HDBC.Types
import Database.HDBC
import Database.HDBC.DriverUtils
import qualified Database.HDBC.Sqlite3.ConnectionImpl as Impl
import Database.HDBC.Sqlite3.Types
import Database.HDBC.Sqlite3.Statement
import Foreign.C.Types
import Foreign.C.String
import Foreign.Marshal
import Foreign.Storable
import Database.HDBC.Sqlite3.Utils
import Foreign.ForeignPtr
import Foreign.Ptr
import Control.Concurrent.MVar
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BUTF8
import qualified Data.Char

{- | Connect to an Sqlite version 3 database.  The only parameter needed is
the filename of the database to connect to.

All database accessor functions are provided in the main HDBC module. -}
connectSqlite3 :: FilePath -> IO Impl.Connection
connectSqlite3 = 
    genericConnect (B.useAsCString . BUTF8.fromString)

{- | Connects to a Sqlite v3 database as with 'connectSqlite3', but
instead of converting the supplied 'FilePath' to a C String by performing
a conversion to Unicode, instead converts it by simply dropping all bits past
the eighth.  This may be useful in rare situations
if your application or filesystemare not running in Unicode space. -}
connectSqlite3Raw :: FilePath -> IO Impl.Connection
connectSqlite3Raw = genericConnect withCString

{- | Like 'connectSqlite3' with list of pragmas to be run before first 
transaction is open.-}
connectSqlite3WithPragmas :: [Pragma] -> FilePath -> IO Impl.Connection
connectSqlite3WithPragmas = 
    genericConnect (B.useAsCString . BUTF8.fromString)

{- | Pragmas which can be invoked using 'connectSqlite3WithPragmas' -}
data Pragma = PragmaFKeys Bool
            | PragmaSynchronous PragmaSynchronousValue
           
data PragmaSynchronousValue = PragmaSynchronousOFF
                            | PragmaSynchronousNORMAL
                            | PragmaSynchronousFULL
                            
instance Show PragmaSynchronousValue where
   show PragmaSynchronousOFF = "OFF"
   show PragmaSynchronousNORMAL = "NORMAL"
   show PragmaSynchronousFULL = "ON"

genericConnect :: (String -> (CString -> IO Impl.Connection) -> IO Impl.Connection) 
               -> [Pragma]
               -> FilePath
               -> IO Impl.Connection
genericConnect strAsCStrFunc pgms fp =
    strAsCStrFunc fp
        (\cs -> alloca 
         (\(p::Ptr (Ptr CSqlite3)) ->
              do res <- sqlite3_open cs p
                 o <- peek p
                 fptr <- newForeignPtr sqlite3_closeptr o
                 newconn <- mkConn pgms fp fptr
                 checkError ("connectSqlite3 " ++ fp) fptr res
                 return newconn
         )
        )

mkConn :: [Pragma] -> FilePath -> Sqlite3 -> IO Impl.Connection
mkConn pgms fp obj =
    do children <- newMVar []
       mapM_ (frunPragma obj children) pgms
       begin_transaction obj children
       ver <- (sqlite3_libversion >>= peekCString)
       return $ Impl.Connection {
                            Impl.disconnect = fdisconnect obj children,
                            Impl.commit = fcommit obj children,
                            Impl.rollback = frollback obj children,
                            Impl.run = frun obj children,
                            Impl.runRaw = frunRaw obj children,
                            Impl.prepare = newSth obj children True,
                            Impl.clone = connectSqlite3 fp,
                            Impl.hdbcDriverName = "sqlite3",
                            Impl.hdbcClientVer = ver,
                            Impl.proxiedClientName = "sqlite3",
                            Impl.proxiedClientVer = ver,
                            Impl.dbTransactionSupport = True,
                            Impl.dbServerVer = ver,
                            Impl.getTables = fgettables obj children,
                            Impl.describeTable = fdescribeTable obj children,
                            Impl.setBusyTimeout = fsetbusy obj}

frunPragma obj children pragma =
    case pragma of
       PragmaFKeys True    -> frunRaw obj children "PRAGMA foreign_keys=ON"
       PragmaFKeys False   -> frunRaw obj children "PRAGMA foreign_keys=OFF"
       PragmaSynchronous v -> frunRaw obj children $ "PRAGMA synchronous=" ++ show v
       _                   -> return ()

fgettables o mchildren =
    do sth <- newSth o mchildren True "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
       execute sth []
       res1 <- fetchAllRows' sth
       let res = map fromSql $ concat res1
       return $ seq (length res) res
       
fdescribeTable o mchildren name =  do 
    sth <- newSth o mchildren True $ "PRAGMA table_info(" ++ name ++ ")"
    execute sth []
    res1 <- fetchAllRows' sth
    return $ map describeCol res1
  where
     describeCol (_:name:typ:notnull:df:pk:_) =
        (fromSql name, describeType typ notnull df pk)
        
     describeType name notnull df pk =
         SqlColDesc (typeId name) Nothing Nothing Nothing (nullable notnull)
         
     nullable SqlNull = Nothing
     nullable (SqlString "0") = Just True
     nullable (SqlString "1") = Just False
     nullable _ = Nothing
     
     typeId SqlNull                     = SqlUnknownT "Any"
     typeId (SqlString t)               = typeId' t
     typeId (SqlByteString t)           = typeId' $ BUTF8.toString t
     typeId _                           = SqlUnknownT "Unknown"
     
     typeId' t = case map Data.Char.toLower t of
       ('i':'n':'t':_) -> SqlIntegerT
       "text"          -> SqlVarCharT
       "real"          -> SqlRealT
       "blob"          -> SqlVarBinaryT
       ""              -> SqlUnknownT "Any"
       other           -> SqlUnknownT other


fsetbusy o ms = withRawSqlite3 o $ \ppdb ->
    sqlite3_busy_timeout ppdb ms

--------------------------------------------------
-- Guts here
--------------------------------------------------

begin_transaction :: Sqlite3 -> ChildList -> IO ()
begin_transaction o children = frun o children "BEGIN" [] >> return ()

frun o mchildren query args =
    do sth <- newSth o mchildren False query
       res <- execute sth args
       finish sth
       return res

frunRaw :: Sqlite3 -> ChildList -> String -> IO ()
frunRaw o mchildren query =
    do sth <- newSth o mchildren False query
       executeRaw sth
       finish sth

fcommit o children = do frun o children "COMMIT" []
                        begin_transaction o children
frollback o children = do frun o children "ROLLBACK" []
                          begin_transaction o children

fdisconnect :: Sqlite3 -> ChildList -> IO ()
fdisconnect o mchildren = withRawSqlite3 o $ \p -> 
    do closeAllChildren mchildren
       r <- sqlite3_close p
       checkError "disconnect" o r

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_open2"
  sqlite3_open :: CString -> (Ptr (Ptr CSqlite3)) -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h &sqlite3_close_finalizer"
  sqlite3_closeptr :: FunPtr ((Ptr CSqlite3) -> IO ())

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_close_app"
  sqlite3_close :: Ptr CSqlite3 -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_busy_timeout2"
  sqlite3_busy_timeout :: Ptr CSqlite3 -> CInt -> IO ()

foreign import ccall unsafe "sqlite3.h sqlite3_libversion"
  sqlite3_libversion :: IO CString

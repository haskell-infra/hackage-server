module Distribution.Server.Features.Mirror (
    MirrorFeature,
    mirrorResource,
    MirrorResource(..),
    initMirrorFeature
  ) where

import Distribution.Server.Acid (query, update)
import Distribution.Server.Framework
import Distribution.Server.Features.Core
import Distribution.Server.Features.Users

import Distribution.Server.Users.State
import Distribution.Server.Packages.Types
import Distribution.Server.Users.Backup
import Distribution.Server.Users.Types
import Distribution.Server.Users.Group (UserGroup(..), GroupDescription(..), nullDescription)
import qualified Distribution.Server.Framework.BlobStorage as BlobStorage
import qualified Distribution.Server.Packages.Unpack as Upload
import Distribution.Server.Framework.BackupDump

import Distribution.Simple.Utils (fromUTF8)
import Distribution.PackageDescription.Parse (parsePackageDescription)
import Distribution.ParseUtils (ParseResult(..), locatedErrorMsg, showPWarning)

import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as SBS
import Data.Time.Clock (getCurrentTime)

import Control.Monad.Trans (MonadIO(..))
import Distribution.Package
import Distribution.Text
import System.FilePath ((<.>))
import qualified Codec.Compression.GZip as GZip

data MirrorFeature = MirrorFeature {
    mirrorResource :: MirrorResource,
    mirrorGroup :: UserGroup
}
data MirrorResource = MirrorResource {
    mirrorPackageTarball :: Resource,
    mirrorCabalFile :: Resource,
    mirrorGroupResource :: GroupResource
}

instance IsHackageFeature MirrorFeature where
    getFeatureInterface mirror = (emptyHackageFeature "mirror") {
        featureResources = map ($mirrorResource mirror) [mirrorPackageTarball, mirrorCabalFile]
      , featureDumpRestore = Just (dumpBackup, restoreBackup, testRoundtripDummy)
      }
      where
        dumpBackup    = do
            clients <- query GetMirrorClients
            return [csvToBackup ["clients.csv"] $ groupToCSV clients]
        restoreBackup = groupBackup ["clients.csv"] ReplaceMirrorClients

-------------------------------------------------------------------------
initMirrorFeature :: ServerEnv -> CoreFeature -> UserFeature -> IO MirrorFeature
initMirrorFeature env core users = do
    let coreR  = coreResource core
        store  = serverBlobStore env
        mirrorers = UserGroup {
            groupDesc = nullDescription { groupTitle = "Mirror clients" },
            queryUserList = query GetMirrorClients,
            addUserList = update . AddMirrorClient,
            removeUserList = update . RemoveMirrorClient,
            groupExists = return True,
            canRemoveGroup = [adminGroup users],
            canAddGroup = [adminGroup users]
        }
    (mirrorers', mirrorR) <- groupResourceAt users "/packages/mirrorers" mirrorers
    return MirrorFeature
      { mirrorResource = MirrorResource
          { mirrorPackageTarball = (extendResource $ corePackageTarball coreR) {
                                     resourcePut = [("", tarballPut store)]
                                   }
          , mirrorCabalFile      = (extendResource $ coreCabalFile coreR) {
                                     resourcePut = [("", cabalPut)]
                                   }
          , mirrorGroupResource  = mirrorR
          }
      , mirrorGroup = mirrorers'
      }
  where
    -- result: error from unpacking, bad request error, or warning lines
    tarballPut :: BlobStorage.BlobStorage -> DynamicPath -> ServerPart Response
    tarballPut store dpath = runServerPartE $ do
        uid <- requireMirrorAuth
        withPackageTarball dpath $ \pkgid -> do
          expectTarball
          Body fileContent <- consumeRequestBody
          time <- liftIO getCurrentTime
          let uploadData = (time, uid)
          res <- liftIO $ BlobStorage.addWith store fileContent $ \fileContent' ->
                   let filename = display pkgid <.> "tar.gz"
                   in case Upload.unpackPackageRaw filename fileContent' of
                        Left err -> return $ Left err
                        Right x ->
                            do let decompressedContent = GZip.decompress fileContent'
                               blobIdDecompressed <- BlobStorage.add store decompressedContent
                               return $ Right (x, blobIdDecompressed)
          case res of
              Left err -> badRequest (toResponse err)
              Right ((((pkg, pkgStr), warnings), blobIdDecompressed), blobId) -> do
                  -- doMergePackage runs the package hooks
                  -- if the upload feature is enabled, it adds
                  -- the user to the package's maintainer group
                  -- the mirror client should probably do this itself,
                  -- if it's able (if it's a trustee).
                  liftIO $ doMergePackage core $ PkgInfo {
                      pkgInfoId     = packageId pkg,
                      pkgDesc       = pkg,
                      pkgData       = pkgStr,
                      pkgTarball    = [(PkgTarball { pkgTarballGz = blobId,
                                                     pkgTarballNoGz = blobIdDecompressed },
                                        uploadData)],
                      pkgUploadData = uploadData,
                      pkgDataOld    = []
                  }
                  return . toResponse $ unlines warnings

    -- return: error from parsing, bad request error, or warning lines
    cabalPut :: DynamicPath -> ServerPart Response
    cabalPut dpath = runServerPartE $ do
        uid <- requireMirrorAuth
        withPackageId dpath $ \pkgid -> do
          expectTextPlain
          Body fileContent <- consumeRequestBody
          time <- liftIO getCurrentTime
          let uploadData = (time, uid)
          case parsePackageDescription . fromUTF8 . BS.unpack $ fileContent of
              ParseFailed err -> badRequest (toResponse $ show (locatedErrorMsg err))
              ParseOk warnings pkg -> do
                  liftIO $ doMergePackage core $ PkgInfo {
                      pkgInfoId     = packageId pkg,
                      pkgDesc       = pkg,
                      pkgData       = fileContent,
                      pkgTarball    = [],
                      pkgUploadData = uploadData,
                      pkgDataOld    = []
                  }
                  let filename = display pkgid <.> "cabal"
                  return . toResponse $ unlines $ map (showPWarning filename) warnings

    requireMirrorAuth :: ServerPartE UserId
    requireMirrorAuth = do
        ulist   <- query GetMirrorClients
        userdb  <- query GetUserDb
        withHackageAuth userdb (Just ulist) $ \uid _info ->
          return uid

    -- It's silly that these are in continuation style,
    -- we should be able to fail -- exception-style -- with an HTTP error code!
    expectTextPlain :: ServerPartE ()
    expectTextPlain = do
      req <- askRq
      let contentType     = fmap SBS.unpack (getHeader "Content-Type" req)
          contentEncoding = fmap SBS.unpack (getHeader "Content-Encoding"  req)
      case (contentType, contentEncoding) of
        (Just "text/plain", Nothing) -> return ()
        _ -> finishWith =<< resp 415 (toResponse "expected text/plain")

    expectTarball  :: ServerPartE ()
    expectTarball = do
      req <- askRq
      let contentType     = fmap SBS.unpack (getHeader "Content-Type" req)
          contentEncoding = fmap SBS.unpack (getHeader "Content-Encoding" req)
      case (contentType, contentEncoding) of
        (Just "application/x-tar", Just "gzip") -> return ()
        (Just "application/x-gzip", Nothing)    -> return ()
        _ -> finishWith =<< resp 415 (toResponse "expected application/x-tar or x-gzip")

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main (main) where

import           ACME
import           Control.Monad.Catch      (Exception, MonadThrow)
import           Control.Monad.IO.Class
import           Crypto.Hash
import           Crypto.PubKey.RSA        hiding (Error)
import           Data.ASN1.BinaryEncoding
import           Data.ASN1.Encoding
import           Data.ASN1.Types
import qualified Data.ByteString          as B
import qualified Data.ByteString.Char8    as BC
import qualified Data.ByteString.Lazy     as L
import           Data.PEM
import qualified Data.Text                as T
import           Data.X509
import           Data.X509.PKCS10         as CSR hiding (subject)
import           PKCS1
import           System.Console.GetOpt
import           System.Environment       (getArgs, getProgName)
import           System.Exit              (die)
import           System.IO                (hPutStrLn, stderr)
import           Utils

decodeDER :: BC.ByteString -> Either String [ASN1]
decodeDER = either (Left . show) Right . decodeASN1' DER

keyFromDER :: BC.ByteString -> Either String PrivateKey
keyFromDER bs = getPrivateKey . fst <$> (decodeDER bs >>= fromASN1)

keyFromPEM :: PEM -> Either String PrivateKey
keyFromPEM pem =
  if pemName pem == "RSA PRIVATE KEY"
  then keyFromDER . pemContent $ pem
  else Left "PEM: unknown format"

data Error = Error String deriving (Show, Typeable)
instance Exception Error

keyFromFile :: (MonadIO m, MonadThrow m) => FilePath -> m PrivateKey
keyFromFile file = do
  bytes <- liftIO $ B.readFile file
  pems <- Error `throwIfError` pemParseBS bytes
  pem <- Error ("pem container '" ++ file ++ "' is empty") `throwIfNothing` headMay pems
  Error `throwIfError` keyFromPEM pem

certChainToPEM :: CertificateChain -> L.ByteString
certChainToPEM chain =
  let CertificateChainRaw encoded = encodeCertificateChain chain in
  L.concat $ certToPEM <$> encoded
  where
    certToPEM bytes = pemWriteLBS $ PEM "CERTIFICATE" [] bytes

makeCSR :: PrivateKey -> [String] -> AcmeM CertificationRequest
makeCSR domainPriv domains = do
  csr <- liftIO $ generateCSR subject extAttrs keyPair SHA256
  Error `throwIfError` csr
  where
    keyPair = KeyPairRSA (private_pub domainPriv) domainPriv
    subject = X520Attributes []
    altNames = AltNameDNS <$> domains
    extAttrs = PKCS9Attributes [PKCS9Attribute $ ExtSubjectAltName altNames]

logStrLn :: MonadIO m => String -> m ()
logStrLn str = liftIO $ hPutStrLn stderr str

retrieveCert :: PrivateKey -> String -> [String] -> AcmeM L.ByteString
retrieveCert domainKey webroot domains = do
    regUrl <- acmeNewReg
    logStrLn $ "Registered account with url " ++ T.unpack regUrl
    _ <- acmeAgreeTOS regUrl
    logStrLn "Agreed to TOS"
    forM_ domains $ \domain -> do
      logStrLn $ "Performing HTTP validation for domain " ++ domain ++ "..."
      _ <- acmeNewHttp01Authz webroot $ T.pack domain
      logStrLn $ "Completed challenge for domain " ++ domain
    chain <- acmeNewCert =<< makeCSR domainKey domains
    logStrLn $ "Obtained certificate chain of length " ++ show (chainLength chain)
    return $ certChainToPEM chain
    where
      chainLength (CertificateChain c) = length c

data Options = Options { optDirectoryUrl :: String
                       , optWebroot      :: String
                       , optAccoutKey    :: String
                       , optDomainKey    :: String
                       , optDomains      :: [String]
                       }

defaultDirectoryUrl :: String
defaultDirectoryUrl = "https://acme-staging.api.letsencrypt.org/directory"

defaultOptions :: Options
defaultOptions = Options defaultDirectoryUrl mzero mzero mzero mzero

options :: [OptDescrEx (Options -> Options)]
options =
  [ OptOption $ Option ['D'] ["directory-url"]
    (ReqArg
      (\o opts -> opts { optDirectoryUrl = o })
      "URL"
    ) "the ACME directory url"
  , ReqOption $ Option ['w'] ["webroot"]
    (ReqArg
      (\o opts -> opts { optWebroot = o })
      "DIR"
    ) "path to webroot for responding to http-01 challenges"
  , ReqOption $ Option ['a'] ["account-key"]
    (ReqArg
      (\o opts -> opts { optAccoutKey = o })
      "FILE"
    ) "key for registering the ACME account"
  , ReqOption $ Option ['d'] ["domain-key"]
    (ReqArg
      (\o opts -> opts { optDomainKey = o })
      "FILE"
    ) "key for issuing the certificate"
  ]

parseOptions :: [String] -> IO Options
parseOptions args =
  case getOptReq options args of
    (True, opts, domains, []) -> processOptions opts domains
    (False, _, _, _) -> getProgName >>= dieWithUsage []
    (_, _, _, errs) -> getProgName >>= dieWithUsage (errs ++ ["\n"])
  where
    header :: String -> String
    header prog = "Usage: " ++ prog ++ " [OPTION...] domains...\n"
    dieWithUsage errs prog = die $ concat errs ++ usageInfo (header prog) (getOptDescr <$> options)
    processOptions opts domains =
      if null domains then
        getProgName >>= dieWithUsage []
      else
        return $ (foldl (flip id) defaultOptions opts) { optDomains = domains }

main :: IO ()
main = do
  Options {..} <- parseOptions =<< getArgs
  accountKey <- keyFromFile optAccoutKey
  domainKey <- keyFromFile optDomainKey
  cert <- runAcmeM accountKey optDirectoryUrl $ retrieveCert domainKey optWebroot optDomains
  L.putStr cert


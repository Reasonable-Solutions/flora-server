-- | Externally facing config parsed from the environment.
module Flora.Environment.Config
  ( FloraConfig (..)
  , LoggingEnv (..)
  , ConnectionInfo (..)
  , TestConfig (..)
  , PoolConfig (..)
  , DeploymentEnv (..)
  , LoggingDestination (..)
  , parseConfig
  , parseTestConfig
  )
where

import Control.Monad ((>=>))
import Data.Bifunctor
import Data.ByteString (ByteString)
import Data.Pool (Pool)
import Data.Text (Text)
import Data.Text.Display (Display (..))
import Data.Time (NominalDiffTime)
import Data.Typeable
import Data.Word (Word16)
import Database.PostgreSQL.Simple qualified as PG
import Env
  ( AsUnread (unread)
  , Error (..)
  , Parser
  , Reader
  , def
  , help
  , nonempty
  , str
  , switch
  , var
  , (<=<)
  )
import GHC.Generics
import Text.Read (readMaybe)

data ConnectionInfo = ConnectionInfo
  { connectHost :: Text
  , connectPort :: Word16
  , connectUser :: Text
  , connectPassword :: Text
  , connectDatabase :: Text
  , sslMode :: Text
  }
  deriving (Generic, Eq, Read, Show, Typeable)

data DeploymentEnv
  = Production
  | Development
  | Test
  deriving stock (Show, Eq, Generic, Enum, Bounded)

instance Display DeploymentEnv where
  displayBuilder Production = "prod"
  displayBuilder Development = "dev"
  displayBuilder Test = "test"

data LoggingDestination
  = -- | Logs are printed on the standard output
    StdOut
  | -- | Logs are printed on the standard output in JSON format
    Json
  | -- | Logs are sent to a file as JSON
    JSONFile
  deriving (Show, Generic)

data LoggingEnv = LoggingEnv
  { sentryDSN :: Maybe String
  , prometheusEnabled :: Bool
  , logger :: LoggingDestination
  }
  deriving stock (Show, Generic)

-- | The datatype that is used to model the external configuration
data FloraConfig = FloraConfig
  { dbConfig :: PoolConfig
  , connectionInfo :: ByteString
  , domain :: Text
  , httpPort :: Word16
  , logging :: LoggingEnv
  , environment :: DeploymentEnv
  }
  deriving stock (Show, Generic)

data PoolConfig = PoolConfig
  { connectionTimeout :: NominalDiffTime
  , connections :: Int
  }
  deriving stock (Show)

data TestConfig = TestConfig
  { httpPort :: Word16
  , dbConfig :: PoolConfig
  , connectionInfo :: ByteString
  }
  deriving stock (Generic)

data TestEnv = TestEnv
  { httpPort :: Word16
  , pool :: Pool PG.Connection
  }
  deriving stock (Generic)

parseConnectionInfo :: Parser Error ByteString
parseConnectionInfo =
  var str "FLORA_DB_CONNSTRING" (help "libpq-compatible connection string")

parsePoolConfig :: Parser Error PoolConfig
parsePoolConfig =
  PoolConfig
    <$> var timeout "FLORA_DB_TIMEOUT" (help "Timeout for each connection")
    <*> var
      (int >=> nonNegative)
      "FLORA_DB_POOL_CONNECTIONS"
      (help "Number of connections per sub-pool")

parseLoggingEnv :: Parser Error LoggingEnv
parseLoggingEnv =
  LoggingEnv
    <$> var (pure . Just <=< nonempty) "FLORA_SENTRY_DSN" (help "Sentry DSN" <> def Nothing)
    <*> switch "FLORA_PROMETHEUS_ENABLED" (help "Whether or not Prometheus is enabled")
    <*> var loggingDestination "FLORA_LOGGING_DESTINATION" (help "Where do the logs go")

parsePort :: Parser Error Word16
parsePort = var port "FLORA_HTTP_PORT" (help "HTTP Port for Flora")

parseDomain :: Parser Error Text
parseDomain = var str "FLORA_DOMAIN" (help "URL domain for Flora")

parseDeploymentEnv :: Parser Error DeploymentEnv
parseDeploymentEnv =
  var deploymentEnv "FLORA_ENVIRONMENT" (help "Name of the current environment (production, development, test)")

parseConfig :: Parser Error FloraConfig
parseConfig =
  FloraConfig
    <$> parsePoolConfig
    <*> parseConnectionInfo
    <*> parseDomain
    <*> parsePort
    <*> parseLoggingEnv
    <*> parseDeploymentEnv

parseTestConfig :: Parser Error TestConfig
parseTestConfig =
  TestConfig
    <$> parsePort
    <*> parsePoolConfig
    <*> parseConnectionInfo

-- Env parser helpers

int :: Reader Error Int
int i = case readMaybe i of
  Nothing -> Left . unread . show $ i
  Just i' -> Right i'

port :: Reader Error Word16
port p = case int p of
  Left err -> Left err
  Right intPort ->
    if intPort >= 1 && intPort <= 65535
      then Right $ fromIntegral intPort
      else Left . unread . show $ p

nonNegative :: Int -> Either Error Int
nonNegative nni = if nni >= 0 then Right nni else Left . unread . show $ nni

timeout :: Reader Error NominalDiffTime
timeout t = second fromIntegral (int >=> nonNegative $ t)

deploymentEnv :: Reader Error DeploymentEnv
deploymentEnv "production" = Right Production
deploymentEnv "development" = Right Development
deploymentEnv "test" = Right Test
deploymentEnv e = Left $ unread e

loggingDestination :: Reader Error LoggingDestination
loggingDestination "stdout" = Right StdOut
loggingDestination "json" = Right Json
loggingDestination "json-file" = Right JSONFile
loggingDestination e = Left $ unread e

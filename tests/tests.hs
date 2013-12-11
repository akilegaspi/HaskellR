-- |
-- Copyright: (C) 2013 Amgen, Inc.
--
-- Tests. Run H on a number of R programs of increasing size and complexity,
-- comparing the output of H with the output of R.

module Main where

import H.Prelude
import H.Constraints
import qualified H.HExp as H
import qualified Foreign.R as R
import qualified Language.R.Interpreter as R (initialize, defaultConfig)
import qualified Language.R as R (withProtected, r2)
import qualified Test.FunPtr
import qualified Test.RVal

import Test.Tasty hiding (defaultMain)
import Test.Tasty.Golden.Advanced
import Test.Tasty.Golden.Manage
import Test.Tasty.HUnit

import qualified Data.ByteString.Char8 (pack)
import           Data.Text (Text)
import qualified Data.Text    as T
import qualified Data.Text.IO as T (readFile)

import Control.Monad (guard)
import Control.Monad.Trans
import Control.Applicative ((<$>))

import Debug.Trace

import Foreign

import System.IO
import qualified System.IO.Strict as Strict (readFile)
import System.Process
import System.FilePath

invokeR :: FilePath -> ValueGetter r Text
invokeR fp = do
    inh <- liftIO $ openFile fp ReadMode
    (_, Just outh, _, _) <- liftIO $ createProcess $ (proc "R" ["--vanilla","--silent","--slave"])
      { std_out = CreatePipe
      , std_in = UseHandle inh
      }
    liftIO $ T.pack <$> hGetContents outh


invokeH :: FilePath -> ValueGetter r Text
invokeH fp = do
    -- Logic:
    --
    --    1. Run translation process that will output translation result to the
    --    pipe.
    --
    --    XXX: in general case when multifile translation will be enabled we
    --    will have to use files that were generated by H
    --
    --    2. Save file to the temporary module
    --
    --    3. Call ghci on resulting file
    --
    (_, Just outh1, _, _) <- liftIO $ createProcess $ (proc "./dist/build/H/H" ["--ghci",fp])
      { std_out = CreatePipe }
    (_, Just outh2, _, _) <- liftIO $ createProcess $ (proc "sh" ["tests/ghciH.sh","-v0","-ghci-script","H.ghci"])
      { std_out = CreatePipe
      , std_in = UseHandle outh1 }
    liftIO $ T.pack <$> hGetContents outh2

invokeGHCi :: FilePath -> ValueGetter r Text
invokeGHCi fp = liftIO $ fmap T.pack $
    Strict.readFile fp >>= readProcess "sh" ["tests/ghciH.sh","-v0","-ghci-script","H.ghci"]

scriptCase :: TestName
           -> FilePath
           -> TestTree
scriptCase name scriptPath =
    goldenTest
      name
      (invokeR scriptPath)
      (invokeH scriptPath)
      (\outputR outputH -> return $ do
         let a = T.lines outputR
             b = T.lines outputH
         -- Continue only if values don't match. If they do, then there's
         -- 'Nothing' to do...
         guard $ not $ and (zipWith compareValues a b) && Prelude.length a == Prelude.length b
         return $ unlines ["Outputs don't match."
                          , "R: "
                          , T.unpack outputR
                          , "H: "
                          , T.unpack outputH
                          ])
      (const $ return ())
  where
    -- Compare Haskell and R outputs:
    -- This function assumes that output is a vector string
    --    INFO Value1 Value2 .. ValueN
    -- where INFO is [OFFSET]. For decimals we are checking if
    -- they are equal with epsilon 1e-6, this is done because R
    -- output is not very predictable it can output up to 6
    -- characters or round them.
    compareValues :: Text -> Text -> Bool
    compareValues r h =
      let (r': rs') = T.words r
          (h': hs') = T.words h
      in (r' == h') && (all eqEpsilon $ zip (map (read . T.unpack) rs' :: [Double]) (map (read . T.unpack) hs' :: [Double]))
    eqEpsilon :: (Double, Double) -> Bool
    eqEpsilon (a, b) = (a - b < 1e-6) && (a - b > (-1e-6))

ghciSession :: TestName -> FilePath -> TestTree
ghciSession name scriptPath =
    goldenTest
      name
      (liftIO $ T.readFile $ scriptPath ++ ".golden.output")
      (invokeGHCi scriptPath)
      (\goldenOutput outputH ->
         let a = T.replace "\r\n" "\n" goldenOutput
             b = T.replace "\r\n" "\n" outputH
         in if a == b
            then return Nothing
            else return $ Just $
              unlines ["Outputs don't match."
                      , "expected: "
                      , show $ T.unpack a
                      , "H: "
                      , show $ T.unpack b
                      ])
      (const $ return ())

unitTests :: TestTree
unitTests = testGroup "Unit tests"
  [ testCase "fromSEXP . mkSEXP" $ runInRThread $
      (2 :: Double) @=? fromSEXP (mkSEXP (2 :: Double))
  , testCase "HEq HExp" $ runInRThread $ do
      -- XXX ideally randomly generate input.
      let x = 2 :: Double
      assertBool "reflexive" $
          let s = H.hexp $ mkSEXP x in s === s
      assertBool "symmetric" $
          let s1 = H.hexp $ mkSEXP x
              s2 = H.hexp $ mkSEXP x
          in s1 === s2 && s2 === s1
      assertBool "transitive" $
          let s1 = H.hexp $ mkSEXP x
              s2 = H.hexp $ mkSEXP x
              s3 = H.hexp $ mkSEXP x
          in s1 === s2 && s2 === s3 && s1 === s3
  , testCase "Haskell function from R" $ runInRThread $ do
      (("[1] 3.0" @=?) =<<) $
        fmap ((\s -> trace s s).  show . toHVal) $ alloca $ \p -> do
          e <- peek R.globalEnv
          R.withProtected (return $ mkSEXP (\x -> (return $ x+1 :: IO Double))) $
            \sf -> R.tryEval (R.r2 (Data.ByteString.Char8.pack ".Call") sf (mkSEXP (2::Double))) e p
  , Test.FunPtr.tests
  , Test.RVal.tests
  ]

integrationTests :: TestTree
integrationTests = testGroup "Integration tests"
  [ scriptCase "Trivial (empty) script" $
      "tests" </> "R" </> "empty.R"
  -- TODO: enable in relevant topic branches.
  , scriptCase "Simple arithmetic" $
       "tests" </> "R" </> "arith.R"
  , scriptCase "Simple arithmetic on vectors" $
       "tests" </> "R" </> "arith-vector.R"
  , ghciSession "qq.ghci" $
       "tests" </> "ghci" </> "qq.ghci"
  , ghciSession "qq-stderr.ghci" $
       "tests" </> "ghci" </> "qq-stderr.ghci"
  -- , scriptCase "Functions - factorial" $
  --     "tests" </> "R" </> "fact.R"
  -- , scriptCase "Functions - Fibonacci sequence" $
  --     "tests" </> "R" </> "fib.R"
  ]

tests :: TestTree
tests = testGroup "Tests" [unitTests, integrationTests]

main :: IO ()
main = do
    _ <- R.initialize R.defaultConfig
    defaultMain tests

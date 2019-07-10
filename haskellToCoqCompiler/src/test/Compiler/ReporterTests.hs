module Compiler.ReporterTests
  ( testReporter
  )
where

import           System.IO.Error                ( ioError
                                                , userError
                                                )

import           Test.Hspec

import           Compiler.Reporter

-- | Test group for all @Compiler.Reporter@ tests.
testReporter :: Spec
testReporter = describe "Compiler.Reporter" $ do
  testRunReporter
  testIsFatal
  testMessages
  testReportIOErrors

-------------------------------------------------------------------------------
-- Tests for @runReporter@                                                  --
-------------------------------------------------------------------------------

-- | Test group for 'runReporter' tests.
testRunReporter :: Spec
testRunReporter = describe "runReporter" $ do
  it "returns 'Just' the produced value if no message was reported" $ do
    runReporter (return testValue1) `shouldBe` (Just testValue1, [])
  it "returns 'Just' the produced value if no fatal message was reported" $ do
    runReporter (report testMessage1 >> return testValue1)
      `shouldBe` (Just testValue1, [testMessage1])
  it "returns 'Nothing' if a fatal message was reported" $ do
    runReporter (reportFatal testMessage1)
      `shouldBe` (Nothing :: Maybe (), [testMessage1])

-------------------------------------------------------------------------------
-- Test data                                                                 --
-------------------------------------------------------------------------------

-- | A message that is reported by some reporters for testing purposes.
testMessage1 :: Message
testMessage1 = Message Nothing Error "Keyboard not found\nPress F1 to Resume"

-- | A message that is reported by some reporters for testing purposes.
testMessage2 :: Message
testMessage2 = Message Nothing Error "Maximum call stack size exceeded!"

-- | A value that is returned some reporters for testing purposes.
testValue1 :: Int
testValue1 = 42

-- | An alternative value that is returned some reporters for testing purposes.
testValue2 :: Int
testValue2 = 1337

-------------------------------------------------------------------------------
-- Tests for @isFatal@                                                       --
-------------------------------------------------------------------------------

-- | Test group for 'isFatal' tests.
testIsFatal :: Spec
testIsFatal = describe "isFatal" $ do
  it "is not fatal to return from a reporter" $ do
    isFatal (return testValue1) `shouldBe` False
  it "is not fatal to report a regular message" $ do
    isFatal (report testMessage1) `shouldBe` False
  it "is fatal to report a fatal message" $ do
    isFatal (reportFatal testMessage1) `shouldBe` True
  it "is fatal if a computation involves reporting a fatal message" $ do
    isFatal (reportFatal testMessage1 >> return testValue1) `shouldBe` True

-------------------------------------------------------------------------------
-- Tests for @messages@                                                      --
-------------------------------------------------------------------------------

-- | Test group for 'messages' tests.
testMessages :: Spec
testMessages = describe "messages" $ do
  it "collects all reported messages" $ do
    let reporter = report testMessage1 >> report testMessage1
    length (messages reporter) `shouldBe` 2
  it "collects all messages reported before a fatal message" $ do
    let reporter = report testMessage1 >> reportFatal testMessage1
    length (messages reporter) `shouldBe` 2
  it "collects no messages reported after a fatal messages" $ do
    let reporter = reportFatal testMessage1 >> report testMessage1
    length (messages reporter) `shouldBe` 1
  it "collects no messages in the right order" $ do
    let reporter = report testMessage1 >> report testMessage2
    messages reporter `shouldBe` [testMessage1, testMessage2]

-------------------------------------------------------------------------------
-- Tests for @reportIOErrors@                                                --
-------------------------------------------------------------------------------

-- | Test group for 'reportIOErrors' tests.
testReportIOErrors :: Spec
testReportIOErrors = describe "reportIOErrors" $ do
  it "catches IO errors" $ do
    reporter <- unhoist $ reportIOErrors (lift $ ioError (userError "catch me"))
    isFatal reporter `shouldBe` True
    length (messages reporter) `shouldBe` 1
  it "forwards reported messages" $ do
    reporter <- unhoist $ reportIOErrors (hoist (report testMessage1))
    isFatal reporter `shouldBe` False
    length (messages reporter) `shouldBe` 1

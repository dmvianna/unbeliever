{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Implementations of different backends that telemetry can be exported to.
-}
module Core.Telemetry.Backends (
    Dataset,
    Exporter,
    consoleExporter,
    honeycombExporter,
) where

import Core.Data.Structures (Map, fromMap, insertKeyValue)
import Core.Encoding.Json
import Core.Program.Context
import Core.Program.Logging
import Core.System.Base (stdout)
import Core.System.External (TimeStamp (unTimeStamp), getCurrentTimeNanoseconds)
import Core.Text.Colour
import Core.Text.Rope
import Core.Text.Utilities
import qualified Data.ByteString as B (ByteString)
import qualified Data.ByteString.Lazy as L (ByteString)
import qualified Data.List as List

-- TODO convert this into a Render instance

-- Somewhat counterintuitively, this does NOT do I/O, but instead returns text
-- which `processTelemetryMessages` will then forward to the main output queue
-- consumed by `processStandardOutput`. This is a bit roundabout, but ensures
-- debug output from this function doesn't smash the console.
consoleExporter :: Exporter
consoleExporter =
    Exporter
        { codenameFrom = "console"
        , processorFrom = process
        }
  where
    process :: Datum -> IO Rope
    process datum = do
        now <- getCurrentTimeNanoseconds
        let start = spanTimeFrom datum
        let text =
                (intoEscapes pureGrey)
                    <> spanNameFrom datum
                    <> " metrics:"
                    <> let pairs :: [(JsonKey, JsonValue)]
                           pairs = fromMap (attachedMetadataFrom datum)
                        in List.foldl' f emptyRope pairs
                            <> (intoEscapes resetColour)

        let result = formatLogMessage start now SeverityDebug text
        pure result

    f :: Rope -> (JsonKey, JsonValue) -> Rope
    f acc (k, v) =
        acc <> "\n  "
            <> (intoEscapes pureGrey)
            <> render 80 k
            <> (intoEscapes pureGrey)
            <> " = "
            <> render 80 v

{- |
Indicate which \"dataset\" spans and events will be posted into
-}
type Dataset = Rope

honeycombExporter :: Dataset -> Exporter
honeycombExporter _ =
    Exporter
        { codenameFrom = "honeycomb"
        , processorFrom = process
        }
  where
    process :: Datum -> IO Rope
    process datum = do
        let json = convertDatumToJson datum
        pure (render 80 json)

    convertDatumToJson :: Datum -> JsonValue
    convertDatumToJson datum =
        let meta0 = attachedMetadataFrom datum

            meta1 = insertKeyValue "name" (JsonString (spanNameFrom datum)) meta0

            meta2 = case spanIdentifierFrom datum of
                Nothing -> meta1
                Just self -> insertKeyValue "trace.span_id" (JsonString (unSpan self)) meta1

            meta3 = case parentIdentifierFrom datum of
                Nothing -> meta2
                Just parent -> insertKeyValue "trace.parent_id" (JsonString (unSpan parent)) meta2

            meta4 = case traceIdentifierFrom datum of
                Nothing -> meta3
                Just trace -> insertKeyValue "trace.trace_id" (JsonString (unTrace trace)) meta3

            meta5 = case serviceNameFrom datum of
                Nothing -> meta4
                Just service -> insertKeyValue "service_name" (JsonString service) meta4

            meta6 = case durationFrom datum of
                Nothing -> meta5
                Just duration ->
                    insertKeyValue
                        "duration_ms"
                        (JsonNumber (fromRational (toRational duration / 1e6)))
                        meta5

            json = JsonObject meta6
         in json

-- Renders Haskell Tidal events in the form purerl-tidal's specs use:
-- whole|part|key=value,... with values tagged f (float), n (note), quoted
-- strings and bare ints, three decimals. Load into a Tidal GHCi session
-- (Limulus's, for one) with `:script test/ghci/render.hs`, then:
--   render (s "bd*2" # n "1 2 3") 0 1
import qualified Data.Map.Strict as RenderMap
import Text.Printf (printf)
import Data.Ratio (numerator, denominator)
import Data.List (intercalate)

:{
renderRat :: Rational -> String
renderRat x = if denominator x == 1 then show (numerator x) else show (numerator x) ++ "/" ++ show (denominator x)

renderArc :: Arc -> String
renderArc (Arc a b) = renderRat a ++ "-" ++ renderRat b

renderValue :: Value -> String
renderValue v = case v of
  VF x -> "f" ++ printf "%.3f" x
  VN x -> "n" ++ printf "%.3f" (unNote x)
  VS x -> show x
  VI x -> show x
  other -> show other

renderEvent :: Event ValueMap -> String
renderEvent e = maybe "~" renderArc (whole e) ++ "|" ++ renderArc (part e) ++ "|"
  ++ intercalate "," [ k ++ "=" ++ renderValue x | (k, x) <- RenderMap.toList (value e) ]

render :: ControlPattern -> Rational -> Rational -> IO ()
render p a b = print (map renderEvent (queryArc p (Arc a b)))
:}

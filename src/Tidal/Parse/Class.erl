-module(tidal_parse_class@foreign).
-export([readFloat/1]).

% Parse a string to float
readFloat(Bin) ->
    Str = binary_to_list(Bin),
    case string:to_float(Str) of
        {Float, []} -> Float;
        {error, no_float} ->
            % Try as integer first
            case string:to_integer(Str) of
                {Int, []} -> float(Int);
                _ -> 0.0
            end;
        {Float, _Rest} -> Float
    end.

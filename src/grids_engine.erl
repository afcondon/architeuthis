%% Mutable Instruments Grids — algorithm core.
%%
%% Pure functions translating Emilie Gillet's `EvaluateDrums()` and
%% `ReadDrumMap()` from `stages-firmware/grids/pattern_generator.cc`
%% to Erlang.  No OTP, no state — the per-voice gen_server in
%% `grids_voice` calls into this with a snapshot of {X, Y, densities,
%% perturbations, step}.
%%
%% The "Drums" mode only; Euclidean (also in the firmware) deferred.
%% Per `project_beam_native_virtual_modules` + the parameter-as-Pattern
%% lift, each of the seven config inputs (X, Y, three densities,
%% randomness, mode) is queried per step from a PureScript Pattern and
%% handed to `evaluate_step/5` as a flat Int.
%%
%% Reference: pattern_generator.cc lines 69-136.
-module(grids_engine).
-export([
    u8_mix/3,
    read_drum_map/4,
    evaluate_step/5,
    fresh_perturbations/2,
    instrument_index/1
]).

%% --------------------------------------------------------------------
%% u8_mix(A, B, T) — linear interpolation between A and B by T/256.
%%
%% Direct port of avrlib's `U8Mix` C reference:
%%
%%     uint8_t U8Mix(uint8_t a, uint8_t b, uint8_t balance) {
%%       return a * (255 - balance) + b * balance >> 8;
%%     }
%%
%% No rounding offset.  Uses 255 (not 256) as the complement —
%% balance=0 returns a, balance=255 returns b * 255 / 256 ≈ b.
%% Verified against op.h's both assembly and C definitions.
%% --------------------------------------------------------------------
u8_mix(A, B, T) when is_integer(A), is_integer(B), is_integer(T),
                     A >= 0, A =< 255, B >= 0, B =< 255,
                     T >= 0, T =< 255 ->
    (A * (255 - T) + B * T) bsr 8.

%% --------------------------------------------------------------------
%% read_drum_map(Step, Instrument, X, Y) — bilinear lookup.
%%
%% Direct port of `PatternGenerator::ReadDrumMap` (pattern_generator.cc
%% lines 77-95).  X, Y are 0..255; their top two bits index into the
%% 5x5 node grid, and their bottom six bits (shifted up by 2 to become
%% 0..252) are the fractional weights for the bilinear blend.
%%
%% Returns the byte 0..255 at (Step, Instrument) after interpolating
%% the four surrounding nodes.
%% --------------------------------------------------------------------
read_drum_map(Step, Inst, X, Y) when is_integer(Step), Step >= 0, Step < 32,
                                     is_integer(Inst), Inst >= 0, Inst < 3,
                                     is_integer(X), X >= 0, X =< 255,
                                     is_integer(Y), Y >= 0, Y =< 255 ->
    I = X bsr 6,
    J = Y bsr 6,
    AMap = grids_tables:drum_map(I, J),
    BMap = grids_tables:drum_map(I + 1, J),
    CMap = grids_tables:drum_map(I, J + 1),
    DMap = grids_tables:drum_map(I + 1, J + 1),
    Offset = Inst * 32 + Step,
    A = binary:at(AMap, Offset),
    B = binary:at(BMap, Offset),
    C = binary:at(CMap, Offset),
    D = binary:at(DMap, Offset),
    XFrac = (X band 16#3F) bsl 2,
    YFrac = (Y band 16#3F) bsl 2,
    u8_mix(u8_mix(A, B, XFrac), u8_mix(C, D, XFrac), YFrac).

%% --------------------------------------------------------------------
%% evaluate_step(Step, X, Y, Densities, Perturbations) — one step.
%%
%% Direct port of `PatternGenerator::EvaluateDrums` (pattern_generator.cc
%% lines 98-136), minus the output-clock packing (we hand triggers
%% out as a list of {Instrument, Accent} rather than packing into the
%% firmware's state byte).
%%
%% Densities :: [DensBd, DensSd, DensHh]  -- each 0..255
%% Perturbations :: [PertBd, PertSd, PertHh]  -- each 0..255, sampled
%%                                               at step 0 by the voice
%%
%% Returns: [{bd|sd|hh, accent :: boolean()}] — only instruments whose
%% level cleared the density threshold appear in the list.
%% --------------------------------------------------------------------
evaluate_step(Step, X, Y, [DensBd, DensSd, DensHh],
              [PertBd, PertSd, PertHh])
  when is_integer(Step), Step >= 0, Step < 32 ->
    Bd = evaluate_one(Step, 0, X, Y, DensBd, PertBd, bd),
    Sd = evaluate_one(Step, 1, X, Y, DensSd, PertSd, sd),
    Hh = evaluate_one(Step, 2, X, Y, DensHh, PertHh, hh),
    [T || T <- [Bd, Sd, Hh], T =/= silent].

%% Per-instrument evaluation.  Returns either `{Name, Accent}` or
%% `silent`.  The clipping rule (level >= 255 - perturbation -> 255)
%% matches the firmware's "weird clipping rule" comment at line 117.
evaluate_one(Step, Inst, X, Y, Density, Perturbation, Name) ->
    Raw = read_drum_map(Step, Inst, X, Y),
    Level =
        if
            Raw + Perturbation > 255 -> 255;
            true -> Raw + Perturbation
        end,
    Threshold = 255 - clamp_density(Density),
    if
        Level > Threshold -> {Name, Level > 192};
        true -> silent
    end.

clamp_density(D) when is_integer(D), D >= 0, D =< 255 -> D;
clamp_density(D) when is_integer(D), D < 0 -> 0;
clamp_density(D) when is_integer(D) -> 255.

%% --------------------------------------------------------------------
%% fresh_perturbations(Randomness, RngState) — sampled at step 0.
%%
%% The firmware does `part_perturbation_[i] = (Random::GetByte() *
%% (randomness >> 2)) >> 8` once per pattern start.  We do the same
%% but take an explicit RngState so the engine stays pure — the voice
%% threads its own random seed through (per memory open-question #2,
%% deterministic per-voice RNG keeps live-coded reproducibility on
%% the table).
%%
%% Returns: {[PertBd, PertSd, PertHh], NextRngState}
%% --------------------------------------------------------------------
fresh_perturbations(Randomness, RngState0) when is_integer(Randomness),
                                                Randomness >= 0,
                                                Randomness =< 255 ->
    Scale = Randomness bsr 2,
    {R1, RngState1} = rand_byte(RngState0),
    {R2, RngState2} = rand_byte(RngState1),
    {R3, RngState3} = rand_byte(RngState2),
    P1 = (R1 * Scale) bsr 8,
    P2 = (R2 * Scale) bsr 8,
    P3 = (R3 * Scale) bsr 8,
    {[P1, P2, P3], RngState3}.

%% xorshift32 — keeps RngState a small Int, deterministic per seed,
%% fast.  Returns a byte 0..255 plus the next state.
rand_byte(S0) ->
    S1 = S0 bxor (S0 bsl 13),
    S2 = (S1 bxor (S1 bsr 17)) band 16#FFFFFFFF,
    S3 = (S2 bxor (S2 bsl 5))  band 16#FFFFFFFF,
    {S3 band 16#FF, S3}.

%% --------------------------------------------------------------------
%% instrument_index(Name) — name <-> 0/1/2 index used by the firmware.
%% --------------------------------------------------------------------
instrument_index(bd) -> 0;
instrument_index(sd) -> 1;
instrument_index(hh) -> 2.

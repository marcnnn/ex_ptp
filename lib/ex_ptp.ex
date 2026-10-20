defmodule ExPtp do
  @moduledoc """
  IEEE 1588 (PTPv2) in hardware and on the BEAM.

  The BEAM side: message codecs (`ExPtp.Message`), data sets and the best
  master clock algorithm (`ExPtp.BMCA`), the port state machine
  (`ExPtp.PortState`) and an ordinary clock process (`ExPtp.Port`) over a
  pluggable `ExPtp.Transport`, tested against a simulated network
  (`ExPtp.Sim`). The hardware side exists as bit-exact reference models:
  `ExPtp.Wallclock`, `ExPtp.Delay`, `ExPtp.Servo`, `ExPtp.MediaClock`.
  """
end

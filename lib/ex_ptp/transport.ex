defmodule ExPtp.Transport do
  @moduledoc """
  What an `ExPtp.Port` needs from the network and the local clock. A
  transport is a `{module, handle}` pair; the module implements these
  callbacks on the handle. The real implementation talks to the MAC's
  timestamping unit and the wallclock in hardware; `ExPtp.Sim.Node` is the
  simulated one.

  Received packets arrive in the port process as
  `{:ptp_rx, channel, payload, rx_timestamp}` (`rx_timestamp` is an
  `ExPtp.Timestamp` for event messages, `nil` for general ones), timers as
  `{:ptp_timer, term}`. Payloads are PTP messages (UDP payload for ports
  319/320 or an L2 payload with EtherType 0x88F7); framing is the
  transport's business.
  """
  alias ExPtp.Timestamp

  @type handle :: term()
  @type channel :: :event | :general

  @doc "Registers the process that receives `:ptp_rx` and `:ptp_timer` messages."
  @callback attach(handle, pid) :: :ok

  @doc """
  Sends a payload. Event messages return their egress hardware timestamp.
  Option `one_step: true` asks the hardware to insert the origin timestamp.
  """
  @callback send_msg(handle, channel, binary, keyword) ::
              {:ok, Timestamp.t() | nil} | {:error, term}

  @doc "Reads the local clock (the timestamping wallclock)."
  @callback now(handle) :: Timestamp.t()

  @doc "Delivers `{:ptp_timer, message}` after `delay_ns` of local time."
  @callback schedule(handle, delay_ns :: non_neg_integer, term) :: :ok

  @doc "Sets the clock rate adjustment (absolute, ppb; positive runs faster)."
  @callback adjust_frequency(handle, ppb :: number) :: :ok

  @doc "Steps the clock phase by `delta_ns` (signed)."
  @callback step_clock(handle, delta_ns :: integer) :: :ok

  @doc """
  Kind of timestamps the transport delivers, `:hardware` (default) or `:software`;
  picks the servo profile (`ExPtp.Servo.Profile`). Optional.
  """
  @callback timestamping(handle) :: :hardware | :software

  @doc """
  Timescale of `now/1`: `:ptp` (TAI, what an Announce with `ptp_timescale` promises;
  default) or `:arb` (arbitrary, e.g. a free running or UTC clock). `utc_offset` is
  TAI minus UTC in seconds and `valid` says whether the transport knows it. Optional.
  """
  @callback timescale(handle) ::
              :ptp | :arb | {:ptp, utc_offset :: integer, valid :: boolean}

  @optional_callbacks timestamping: 1, timescale: 1

  @doc "Timestamping kind of a transport (`:hardware` unless it says otherwise)."
  def timestamping({mod, handle}) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :timestamping, 1),
      do: mod.timestamping(handle),
      else: :hardware
  end

  @doc """
  Timescale of a transport as `{:ptp, utc_offset, valid}` or `:arb` (the PTP timescale
  with offset 37 and not valid unless it says otherwise).
  """
  def timescale({mod, handle}) do
    r =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :timescale, 1),
        do: mod.timescale(handle),
        else: :ptp

    if r == :ptp, do: {:ptp, 37, false}, else: r
  end

  @doc "Message channel (`:event` or `:general`) for a message type."
  def channel(type) when type in [:sync, :delay_req, :pdelay_req, :pdelay_resp], do: :event
  def channel(_), do: :general
end

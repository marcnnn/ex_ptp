defmodule ExPtp.Delay do
  @moduledoc """
  Offset and mean path delay (IEEE 1588-2019 clauses 11.3 and 11.4) in exact
  integer arithmetic. Timestamps are `ExPtp.Timestamp`, corrections and
  results are scaled ns (`ExPtp.Correction`); halving is an arithmetic shift.

  Delay request-response: `t1` Sync origin (master), `t2` Sync receipt,
  `t3` Delay_Req origin, `t4` Delay_Req receipt (from Delay_Resp).
  Peer delay: `t1` Pdelay_Req origin, `t2` its receipt at the responder,
  `t3` Pdelay_Resp origin, `t4` its receipt at the requester.

      iex> alias ExPtp.{Delay, Timestamp, Correction}
      iex> t = &Timestamp.new(0, &1)
      iex> # slave 1000 ns ahead, path 500 ns each way
      iex> {t1, t2, t3, t4} = {t.(0), t.(1500), t.(2000), t.(1500)}
      iex> mpd = Delay.e2e_mean_path_delay(t1, t2, t3, t4)
      iex> Correction.to_ns(mpd)
      500.0
      iex> Correction.to_ns(Delay.offset_from_master(t1, t2, 0, mpd))
      1000.0
  """
  import Bitwise
  alias ExPtp.Timestamp

  @doc """
  `((t2 - t1) + (t4 - t3) - c_sync - c_delay_resp) / 2`; `c_sync` is the
  sum of the Sync and Follow_Up corrections, `c_delay_resp` the Delay_Resp's.
  """
  def e2e_mean_path_delay(t1, t2, t3, t4, c_sync \\ 0, c_delay_resp \\ 0),
    do: (Timestamp.diff(t2, t1) + Timestamp.diff(t4, t3) - c_sync - c_delay_resp) >>> 1

  @doc """
  `((t2 - t1) + (t4 - t3) - c_resp - c_resp_follow_up) / 2`, the peer mean
  path delay; the corrections are those of the Pdelay_Resp and
  Pdelay_Resp_Follow_Up (the responder's turnaround in one-step mode).
  """
  def p2p_mean_path_delay(t1, t2, t3, t4, c_resp \\ 0, c_resp_follow_up \\ 0),
    do: (Timestamp.diff(t2, t1) + Timestamp.diff(t4, t3) - c_resp - c_resp_follow_up) >>> 1

  @doc "`t2 - t1 - mean_path_delay - correction` (slave minus master)."
  def offset_from_master(t1, t2, correction, mean_path_delay),
    do: Timestamp.diff(t2, t1) - mean_path_delay - correction

  @doc """
  Ratio of the master's elapsed time to the local elapsed time between two
  sync points (a float near 1.0); the rate error is `ratio - 1`.
  """
  def rate_ratio(master_a, master_b, local_a, local_b) do
    case Timestamp.diff_ns(local_b, local_a) do
      0 -> nil
      d -> Timestamp.diff_ns(master_b, master_a) / d
    end
  end
end

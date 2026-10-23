defmodule ExPtp.Profile do
  @moduledoc """
  Profile defaults: `:default` (IEEE 1588 default profile), `:aes67` (AES67
  Annex A media profile) and `:smpte_2059_2`. Values are the profile's
  default and, for the intervals, its permitted `{min, max}` range
  (log2 seconds; the receipt timeout is in announce intervals).

  Unverified: the numbers are transcribed from memory of the standards
  (AES67-2018 Annex A, SMPTE ST 2059-2:2021), not checked against the text;
  treat them as a starting point. Known uncertain: the AES67 announce
  default (0 here, the standard may say 1) and its Delay_Req range, the
  SMPTE ST 2059-2 Delay_Req range and announce receipt timeout range.
  Peer delay is allowed by both media profiles; the defaults use `:e2e`.
  Not modelled: the SMPTE synchronization metadata TLV.

      iex> ExPtp.Profile.get(:aes67).domain
      0
      iex> ExPtp.Profile.get(:aes67).log_sync_interval
      -3
      iex> ExPtp.Profile.get(:smpte_2059_2).domain
      127
  """

  import Bitwise

  @profiles %{
    default: %{
      name: :default,
      domain: 0,
      delay_mechanism: :e2e,
      priority1: 128,
      priority2: 128,
      log_announce_interval: 1,
      log_announce_range: {0, 4},
      announce_receipt_timeout: 3,
      announce_receipt_timeout_range: {2, 255},
      log_sync_interval: 0,
      log_sync_range: {-1, 1},
      log_min_delay_req_interval: 0,
      log_min_delay_req_range: {0, 5}
    },
    aes67: %{
      name: :aes67,
      domain: 0,
      delay_mechanism: :e2e,
      priority1: 128,
      priority2: 128,
      log_announce_interval: 0,
      log_announce_range: {0, 4},
      announce_receipt_timeout: 3,
      announce_receipt_timeout_range: {2, 10},
      log_sync_interval: -3,
      log_sync_range: {-4, 1},
      log_min_delay_req_interval: 0,
      log_min_delay_req_range: {-3, 5}
    },
    smpte_2059_2: %{
      name: :smpte_2059_2,
      domain: 127,
      delay_mechanism: :e2e,
      priority1: 128,
      priority2: 128,
      log_announce_interval: -2,
      log_announce_range: {-3, 1},
      announce_receipt_timeout: 3,
      announce_receipt_timeout_range: {2, 10},
      log_sync_interval: -3,
      log_sync_range: {-7, -1},
      log_min_delay_req_interval: -3,
      log_min_delay_req_range: {-7, 5}
    }
  }

  @doc "The profile map; raises on an unknown name."
  def get(name), do: Map.fetch!(@profiles, name)

  @doc "Profile names."
  def names, do: Map.keys(@profiles)

  @doc "True if the interval of `kind` (`:announce`, `:sync`, `:min_delay_req`) is in the profile's range."
  def in_range?(profile, kind, log_interval) do
    {lo, hi} =
      case kind do
        :announce -> profile.log_announce_range
        :sync -> profile.log_sync_range
        :min_delay_req -> profile.log_min_delay_req_range
      end

    log_interval in lo..hi
  end

  @doc "A log2-seconds interval in integer nanoseconds."
  def interval_ns(log), do: if(log >= 0, do: 1_000_000_000 <<< log, else: 1_000_000_000 >>> -log)
end

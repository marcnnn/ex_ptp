defmodule ExPtp.Gen do
  @moduledoc false
  use ExUnitProperties
  import Bitwise, only: [<<<: 2]
  import StreamData
  alias ExPtp.{Message, Timestamp, TLV}

  def timestamp do
    gen all s <- integer(0..0xFFFFFFFFFFFF), n <- integer(0..999_999_999) do
      %Timestamp{seconds: s, nanoseconds: n}
    end
  end

  def identity, do: tuple({binary(length: 8), integer(0..0xFFFF)})

  def tlv do
    gen all t <- integer(0..0xFFFF), v <- binary(max_length: 24) do
      %TLV{type: t, value: v}
    end
  end

  def body(:sync), do: map_of_ts(:origin_timestamp)
  def body(:delay_req), do: map_of_ts(:origin_timestamp)
  def body(:pdelay_req), do: map_of_ts(:origin_timestamp)
  def body(:follow_up), do: map_of_ts(:precise_origin_timestamp)

  def body(:delay_resp), do: with_port(:receive_timestamp)
  def body(:pdelay_resp), do: with_port(:request_receipt_timestamp)
  def body(:pdelay_resp_follow_up), do: with_port(:response_origin_timestamp)

  def body(:announce) do
    gen all ts <- timestamp(),
            utc <- integer(-32768..32767),
            p1 <- integer(0..255),
            class <- integer(0..255),
            acc <- integer(0..255),
            var <- integer(0..0xFFFF),
            p2 <- integer(0..255),
            gm <- binary(length: 8),
            steps <- integer(0..0xFFFF),
            src <- integer(0..255) do
      %{
        origin_timestamp: ts,
        current_utc_offset: utc,
        priority1: p1,
        clock_class: class,
        clock_accuracy: acc,
        offset_scaled_log_variance: var,
        priority2: p2,
        grandmaster_identity: gm,
        steps_removed: steps,
        time_source: src
      }
    end
  end

  def body(:signaling), do: map(identity(), &%{target_port: &1})

  def body(:management) do
    gen all id <- identity(), a <- integer(0..255), b <- integer(0..255), act <- integer(0..15) do
      %{target_port: id, starting_boundary_hops: a, boundary_hops: b, action: act}
    end
  end

  defp map_of_ts(key), do: map(timestamp(), &%{key => &1})

  defp with_port(key) do
    gen all ts <- timestamp(), id <- identity() do
      %{key => ts, :requesting_port => id}
    end
  end

  def message do
    gen all type <- member_of(Map.values(Message.types())),
            body <- body(type),
            src <- identity(),
            seq <- integer(0..0xFFFF),
            domain <- integer(0..255),
            flags <- integer(0..0xFFFF),
            corr <- integer(-(1 <<< 62)..(1 <<< 62)),
            log <- integer(-128..127),
            specific <- integer(0..0xFFFFFFFF),
            sdo <- integer(0..15),
            tlvs <- list_of(tlv(), max_length: 3) do
      %Message{
        type: type,
        body: body,
        source: src,
        sequence_id: seq,
        domain: domain,
        flags: flags,
        correction: corr,
        log_interval: log,
        type_specific: specific,
        major_sdo_id: sdo,
        tlvs: tlvs
      }
    end
  end
end

defmodule ExPtp.MessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise, only: [<<<: 2]

  alias ExPtp.{Correction, Message, Timestamp, TLV}

  doctest ExPtp.Message
  doctest ExPtp.TLV
  doctest ExPtp.Timestamp
  doctest ExPtp.Correction

  @cid <<0x00, 0x1B, 0x21, 0xFF, 0xFE, 0x01, 0x02, 0x03>>

  test "decodes a hand-built Sync (two-step, domain 0, logSyncInterval -3)" do
    bin =
      <<0x00, 0x02, 0, 44, 0, 0, 0x02, 0x00, 0::64, 0::32, @cid::binary, 0x00, 0x01, 0x12, 0x34,
        0x00, 0xFD, 0::80>>

    assert {:ok, m} = Message.decode(bin)
    assert m.type == :sync
    assert m.source == {@cid, 1}
    assert m.sequence_id == 0x1234
    assert m.log_interval == -3
    assert Message.flag?(m, :two_step)
    refute Message.flag?(m, :unicast)
    assert m.body.origin_timestamp == %Timestamp{}
    assert Message.encode(m) == bin
  end

  test "announce wire layout" do
    body = %{
      origin_timestamp: Timestamp.new(1, 2),
      current_utc_offset: 37,
      priority1: 128,
      clock_class: 6,
      clock_accuracy: 0x21,
      offset_scaled_log_variance: 0x4E5D,
      priority2: 129,
      grandmaster_identity: @cid,
      steps_removed: 2,
      time_source: 0x20
    }

    flags = Message.flags([:ptp_timescale, :current_utc_offset_valid])
    m = Message.new(:announce, {@cid, 1}, 9, body, flags: flags, log_interval: 0)
    bin = Message.encode(m)
    assert byte_size(bin) == 64
    assert <<0x0B, 0x02, 0, 64, _::binary>> = bin
    assert <<_::binary-6, 0x00, 0x0C, _::binary>> = bin

    assert <<_::binary-34, 1::48, 2::32, 37::16, 0, 128, 6, 0x21, 0x4E5D::16, 129, _::binary>> =
             bin

    assert {:ok, ^m} = Message.decode(bin)
  end

  test "Delay_Resp, Pdelay_Resp and Management lengths" do
    ts = Timestamp.new(3, 4)
    port = {@cid, 7}
    src = {@cid, 1}
    dr = Message.new(:delay_resp, src, 1, %{receive_timestamp: ts, requesting_port: port})
    assert byte_size(Message.encode(dr)) == 54
    pq = Message.new(:pdelay_req, src, 1, %{origin_timestamp: ts})
    assert byte_size(Message.encode(pq)) == 54

    mg =
      Message.new(:management, src, 1, %{
        target_port: port,
        starting_boundary_hops: 1,
        boundary_hops: 1,
        action: 2
      })

    mg = %{mg | tlvs: [%TLV{type: 1, value: <<0x20, 0x01, 0, 0>>}]}
    assert Message.length_of(mg) == 48 + 8
    assert {:ok, ^mg} = mg |> Message.encode() |> Message.decode()
  end

  test "trailing padding after messageLength is ignored" do
    m = Message.new(:sync, {@cid, 1}, 1, %{origin_timestamp: Timestamp.new(1, 1)})
    bin = Message.encode(m) <> <<0::64>>
    assert {:ok, ^m} = Message.decode(bin)
  end

  test "malformed input yields errors" do
    m = Message.new(:sync, {@cid, 1}, 1, %{origin_timestamp: Timestamp.new(1, 1)})
    bin = Message.encode(m)
    assert {:error, :short} = Message.decode(<<>>)
    assert {:error, :short} = Message.decode(binary_part(bin, 0, 33))
    assert {:error, :bad_length} = Message.decode(binary_part(bin, 0, 40))

    assert {:error, {:unknown_type, 4}} =
             Message.decode(<<0x04, bin::binary-size(43)>> |> tl_fix(bin))

    assert {:error, :bad_timestamp} = Message.decode(replace(bin, 34, <<0::48, 0xFFFFFFFF::32>>))
    assert {:error, :bad_length} = Message.decode(replace(bin, 2, <<0, 10>>))
    assert {:error, :bad_body} = Message.decode(replace(bin, 2, <<0, 40>>))
    tlv = bin |> replace(2, <<0, 48>>) |> Kernel.<>(<<0, 8, 0, 9, 1, 2>>)
    assert {:error, :bad_tlv} = Message.decode(replace(tlv, 2, <<0, 50>>))
    assert {:error, :short} = Message.decode(:nope)
  end

  defp tl_fix(_, bin), do: replace(bin, 0, <<0x04>>)

  defp replace(bin, at, new) do
    <<pre::binary-size(at), _::binary-size(byte_size(new)), post::binary>> = bin
    pre <> new <> post
  end

  test "Timestamp and Correction arithmetic" do
    a = Timestamp.new(5, 999_999_999)
    assert Timestamp.add_ns(a, 1) == Timestamp.new(6, 0)
    assert Timestamp.add_ns(a, -999_999_999 - 5_000_000_000) == Timestamp.new(0, 0)

    assert Timestamp.diff(Timestamp.new(1, 0), Timestamp.new(0, 500)) ==
             Correction.from_ns(999_999_500)

    assert Timestamp.add(Timestamp.new(1, 0), Correction.from_ns(2.5)) == Timestamp.new(1, 2)
    assert Timestamp.compare(a, Timestamp.new(6, 0)) == :lt
    assert Timestamp.decode(<<0::48, 1_000_000_000::32>>) == {:error, :bad_timestamp}
    assert Correction.saturate(1 <<< 70) == (1 <<< 63) - 1
    assert Correction.decode(Correction.encode(-123_456)) == -123_456
    assert Correction.to_ns_rounded(Correction.from_ns(2.5)) == 3
    assert Correction.sub(Correction.from_ns(1), Correction.from_ns(3)) == Correction.from_ns(-2)
  end

  property "encode/decode round trip for every message type" do
    check all(m <- ExPtp.Gen.message(), max_runs: 500) do
      bin = Message.encode(m)
      assert byte_size(bin) == Message.length_of(m)
      assert {:ok, ^m} = Message.decode(bin)
    end
  end

  property "decode never raises on arbitrary bytes" do
    check all(bin <- binary(max_length: 120), max_runs: 1000) do
      assert match?({:ok, _}, Message.decode(bin)) or match?({:error, _}, Message.decode(bin))
    end
  end

  property "decode never raises on corrupted valid messages" do
    check all(
            m <- ExPtp.Gen.message(),
            pos <- integer(0..120),
            byte <- integer(0..255),
            cut <- integer(0..130),
            max_runs: 500
          ) do
      bin = Message.encode(m)
      pos = rem(pos, byte_size(bin))
      <<pre::binary-size(pos), _, post::binary>> = bin
      mutated = pre <> <<byte>> <> post

      for b <- [mutated, binary_part(mutated, 0, min(cut, byte_size(mutated)))] do
        assert match?({:ok, _}, Message.decode(b)) or match?({:error, _}, Message.decode(b))
      end
    end
  end

  property "timestamps round trip and subtract consistently" do
    check all(a <- ExPtp.Gen.timestamp(), d <- integer(-1_000_000_000_000..1_000_000_000_000)) do
      assert {:ok, ^a} = Timestamp.decode(Timestamp.encode(a))
      b = Timestamp.add_ns(a, d)
      expect = max(Timestamp.to_ns(a) + d, 0)

      assert Timestamp.to_ns(b) ==
               min(
                 expect,
                 Timestamp.to_ns(%Timestamp{seconds: 0xFFFFFFFFFFFF, nanoseconds: 999_999_999})
               )
    end
  end
end

defmodule ExPtp.Interop.TsharkTest do
  @moduledoc """
  PTP messages of every type, built by ex_ptp, dissected by Wireshark (tshark in
  the `ex-interop-tshark` container) over UDP (ports 319/320) and over
  Ethernet (0x88F7). No malformed markers or expert warnings, and every field
  Wireshark shows equals what went in. The reverse direction decodes the
  Wireshark sample captures `ptpv2.pcap` and `ptpv2_anon.pcapng` with
  `ExPtp.Message` and compares them with tshark's view.
  """
  use ExUnit.Case, async: false

  alias ExPtp.{Message, Timestamp, TLV}
  alias Interop.{Captures, Frame, Tshark}
  alias PtpInterop.Fields

  @moduletag :interop
  @moduletag timeout: 300_000

  @src {<<0, 1, 2, 255, 254, 3, 4, 5>>, 1}
  @other {<<9, 8, 7, 255, 254, 6, 5, 4>>, 2}

  defp ts(s, n), do: Timestamp.new(s, n)

  defp messages do
    announce_flags =
      Message.flags([
        :ptp_timescale,
        :time_traceable,
        :frequency_traceable,
        :current_utc_offset_valid
      ])

    [
      Message.new(:sync, @src, 11, %{origin_timestamp: ts(1000, 123)},
        flags: Message.flags([:two_step, :ptp_timescale]),
        log_interval: -3,
        correction: 98_304
      ),
      Message.new(:follow_up, @src, 11, %{precise_origin_timestamp: ts(1000, 124)},
        log_interval: -3,
        correction: -65_536
      ),
      Message.new(:sync, @src, 65_535, %{origin_timestamp: ts(0xFFFFFFFFFFFF, 999_999_999)},
        domain: 127,
        log_interval: 0
      ),
      Message.new(:delay_req, @src, 12, %{origin_timestamp: ts(0, 0)}),
      Message.new(
        :delay_resp,
        @other,
        12,
        %{receive_timestamp: ts(1000, 999), requesting_port: @src},
        log_interval: 0,
        correction: 3 * 65_536
      ),
      Message.new(:pdelay_req, @src, 13, %{origin_timestamp: ts(5, 6)}),
      Message.new(
        :pdelay_resp,
        @other,
        13,
        %{request_receipt_timestamp: ts(7, 8), requesting_port: @src},
        flags: Message.flags([:two_step])
      ),
      Message.new(:pdelay_resp_follow_up, @other, 13, %{
        response_origin_timestamp: ts(9, 10),
        requesting_port: @src
      }),
      Message.new(
        :announce,
        @src,
        14,
        %{
          origin_timestamp: ts(0, 0),
          current_utc_offset: 37,
          priority1: 100,
          clock_class: 6,
          clock_accuracy: 0x21,
          offset_scaled_log_variance: 0x4E5D,
          priority2: 110,
          grandmaster_identity: <<1, 2, 3, 255, 254, 4, 5, 6>>,
          steps_removed: 2,
          time_source: 0x20
        },
        flags: announce_flags,
        log_interval: 1,
        tlvs: [TLV.path_trace([<<1, 2, 3, 255, 254, 4, 5, 6>>, <<1, 2, 3, 255, 254, 4, 5, 7>>])]
      ),
      Message.new(:signaling, @src, 15, %{target_port: @other},
        tlvs: [%TLV{type: 3, value: <<0, 0, 0x0E, 0x82, 1, 2, 3, 4>>}]
      ),
      Message.new(
        :management,
        @src,
        16,
        %{target_port: @other, starting_boundary_hops: 2, boundary_hops: 2, action: 0},
        tlvs: [%TLV{type: 1, value: <<0x20, 0x00>>}]
      )
    ]
  end

  defp port_for(type) when type in [:sync, :delay_req, :pdelay_req, :pdelay_resp], do: 319
  defp port_for(_), do: 320

  test "every message type over UDP/IPv4 (multicast 224.0.1.129, ports 319/320)" do
    msgs = messages()

    frames =
      for m <- msgs do
        group =
          if m.type |> to_string() |> String.starts_with?("pdelay"),
            do: {224, 0, 0, 107},
            else: {224, 0, 1, 129}

        Frame.udp(Message.encode(m),
          dst_ip: group,
          dst_port: port_for(m.type),
          src_port: port_for(m.type)
        )
      end

    pkts = Tshark.dissect(frames)
    assert length(pkts) == length(msgs)
    Tshark.assert_clean(pkts)

    for {p, m} <- Enum.zip(pkts, msgs) do
      assert String.ends_with?(Tshark.get(p, "frame.protocols"), "udp:ptp")
      assert Tshark.get(p, "ip.checksum.status") == "1"
      assert Tshark.get(p, "udp.checksum.status") == "1"
      Fields.check(p, m)
    end
  end

  test "every message type over Ethernet (0x88F7), plain and with an 802.1Q tag" do
    msgs = messages()

    mk = fn m, opts ->
      dst =
        if String.starts_with?(to_string(m.type), "pdelay"),
          do: <<0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E>>,
          else: <<0x01, 0x1B, 0x19, 0, 0, 0>>

      Frame.l2(Message.encode(m), 0x88F7, [dst: dst] ++ opts)
    end

    frames = Enum.map(msgs, &mk.(&1, [])) ++ Enum.map(msgs, &mk.(&1, vlan: 7))
    pkts = Tshark.dissect(frames)
    assert length(pkts) == 2 * length(msgs)
    Tshark.assert_clean(pkts)

    for {p, m} <- Enum.zip(pkts, msgs ++ msgs) do
      assert Tshark.get(p, "eth.type") in ["0x88f7", "0x8100"]
      Fields.check(p, m)
    end
  end

  test "frames padded to the Ethernet minimum are still dissected cleanly" do
    m = Message.new(:delay_req, @src, 1, %{origin_timestamp: ts(0, 0)})
    bin = Message.encode(m)
    frame = Frame.l2(bin <> <<0::size(8 * 6)>>, 0x88F7, dst: <<0x01, 0x1B, 0x19, 0, 0, 0>>)
    [pkt] = Tshark.dissect([frame])
    Tshark.assert_clean([pkt])
    assert Tshark.get(pkt, "ptp.v2.messagelength") == "44"
    assert {:ok, ^m} = Message.decode(bin <> <<0::size(8 * 6)>>)
  end

  test "malformed input: tshark flags what ExPtp.Message rejects (negative control)" do
    m = Message.new(:sync, @src, 1, %{origin_timestamp: ts(1, 2)})
    bin = Message.encode(m)
    cut = binary_part(bin, 0, 40)
    assert {:error, _} = Message.decode(cut)

    [pkt] =
      Tshark.dissect([
        Frame.udp(cut, dst_ip: {224, 0, 1, 129}, dst_port: 319, src_port: 319)
      ])

    assert Tshark.problems(pkt) != []
  end

  for name <- [
        "ptpv2.pcap",
        "https://wiki.wireshark.org/uploads/faca5622d7ec2f07f1a9ee3f062fdfac/ptpv2_anon.pcapng"
      ] do
    test "#{name} from the Wireshark sample captures decodes like tshark" do
      case Captures.fetch(unquote(name)) do
        {:skip, why} ->
          IO.puts("skipped #{unquote(name)}: #{why}")

        {:ok, path} ->
          {_, frames} = Captures.frames(path)
          pkts = Tshark.dissect_file(Path.dirname(path), Path.basename(path))
          assert length(frames) == length(pkts)

          results =
            for {f, p} <- Enum.zip(frames, pkts), Tshark.get(p, "ptp.v2.messagetype") != nil do
              payload =
                case Frame.payload(f) do
                  {:udp, _, pl} -> pl
                  {:l2, _, pl} -> pl
                end

              case Message.decode(payload) do
                {:ok, m} ->
                  # fields are derived from the decoded message; tshark must agree
                  Fields.check(p, m)
                  m.type

                {:error, e} ->
                  flunk(
                    "ExPtp.Message.decode failed (#{inspect(e)}) on a frame tshark parses as PTP: #{Tshark.get(p, "ptp.v2.messagetype")}"
                  )
              end
            end

          IO.puts("#{unquote(name)}: #{inspect(Enum.frequencies(results))}")
          assert results != []
      end
    end
  end
end

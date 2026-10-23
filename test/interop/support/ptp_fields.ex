defmodule PtpInterop.Fields do
  @moduledoc false
  # What Wireshark's PTP dissector must show for an `ExPtp.Message`, and the checks.
  import ExUnit.Assertions

  alias ExPtp.{Message, Timestamp}
  alias Interop.Tshark

  # The fields Wireshark must show for a message (name => string).
  def expected(%Message{} = m) do
    {cid, port} = m.source
    corr = m.correction

    common = %{
      "ptp.v2.messagetype" => "0x" <> hex(Map.fetch!(types(), m.type), 2),
      "ptp.v2.versionptp" => "2",
      "ptp.v2.domainnumber" => "#{m.domain}",
      "ptp.v2.sequenceid" => "#{m.sequence_id}",
      "ptp.v2.sourceportid" => "#{port}",
      "ptp.v2.clockidentity" => "0x" <> Base.encode16(cid, case: :lower),
      "ptp.v2.flags" => "0x" <> hex(m.flags, 4),
      "ptp.v2.logmessageperiod" => "#{signed8(m.log_interval)}",
      "ptp.v2.messagelength" => "#{Message.length_of(m)}",
      "ptp.v2.correction.ns" => "#{div(corr, 65_536)}"
    }

    Map.merge(common, body_fields(m))
  end

  defp types, do: Map.new(Message.types(), fn {k, v} -> {v, k} end)

  defp hex(n, w),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(w, "0")

  defp signed8(n) when n > 127, do: n - 256
  defp signed8(n), do: n

  defp tsf(prefix, %Timestamp{seconds: s, nanoseconds: n}),
    do: %{(prefix <> ".seconds") => "#{s}", (prefix <> ".nanoseconds") => "#{n}"}

  defp ident({cid, _}), do: "0x" <> Base.encode16(cid, case: :lower)

  defp body_fields(%{type: t, body: b}) when t in [:sync, :delay_req],
    do: tsf("ptp.v2.sdr.origintimestamp", b.origin_timestamp)

  defp body_fields(%{type: :follow_up, body: b}),
    do: tsf("ptp.v2.fu.preciseorigintimestamp", b.precise_origin_timestamp)

  defp body_fields(%{type: :delay_resp, body: b}) do
    {_, p} = b.requesting_port

    Map.merge(tsf("ptp.v2.dr.receivetimestamp", b.receive_timestamp), %{
      "ptp.v2.dr.requestingsourceportid" => "#{p}",
      "ptp.v2.dr.requestingsourceportidentity" => ident(b.requesting_port)
    })
  end

  defp body_fields(%{type: :pdelay_req, body: b}),
    do: tsf("ptp.v2.pdrq.origintimestamp", b.origin_timestamp)

  defp body_fields(%{type: :pdelay_resp, body: b}) do
    {_, p} = b.requesting_port

    Map.merge(tsf("ptp.v2.pdrs.requestreceipttimestamp", b.request_receipt_timestamp), %{
      "ptp.v2.pdrs.requestingsourceportid" => "#{p}",
      "ptp.v2.pdrs.requestingportidentity" => ident(b.requesting_port)
    })
  end

  defp body_fields(%{type: :pdelay_resp_follow_up, body: b}) do
    {_, p} = b.requesting_port

    Map.merge(tsf("ptp.v2.pdfu.responseorigintimestamp", b.response_origin_timestamp), %{
      "ptp.v2.pdfu.requestingsourceportid" => "#{p}",
      "ptp.v2.pdfu.requestingportidentity" => ident(b.requesting_port)
    })
  end

  defp body_fields(%{type: :announce, body: b}) do
    Map.merge(tsf("ptp.v2.an.origintimestamp", b.origin_timestamp), %{
      "ptp.v2.an.origincurrentutcoffset" => "#{b.current_utc_offset}",
      "ptp.v2.an.priority1" => "#{b.priority1}",
      "ptp.v2.an.priority2" => "#{b.priority2}",
      "ptp.v2.an.grandmasterclockclass" => "#{b.clock_class}",
      "ptp.v2.an.grandmasterclockaccuracy" => "0x" <> hex(b.clock_accuracy, 2),
      "ptp.v2.an.grandmasterclockvariance" => "#{b.offset_scaled_log_variance}",
      "ptp.v2.an.grandmasterclockidentity" =>
        "0x" <> Base.encode16(b.grandmaster_identity, case: :lower),
      "ptp.v2.an.localstepsremoved" => "#{b.steps_removed}",
      "ptp.v2.timesource" => "0x" <> hex(b.time_source, 2)
    })
  end

  defp body_fields(%{type: :signaling, body: b}),
    do: %{"ptp.v2.sig.targetportidentity" => ident(b.target_port)}

  defp body_fields(%{type: :management, body: b}) do
    {_, p} = b.target_port

    %{
      "ptp.v2.mm.targetportidentity" => ident(b.target_port),
      "ptp.v2.mm.targetportid" => "#{p}",
      "ptp.v2.mm.startingboundaryhops" => "#{b.starting_boundary_hops}",
      "ptp.v2.mm.boundaryhops" => "#{b.boundary_hops}",
      "ptp.v2.mm.action" => "#{b.action}"
    }
  end

  def flag_names(pkt) do
    [
      {"alternatemaster", :alternate_master},
      {"twostep", :two_step},
      {"unicast", :unicast},
      {"specific1", :profile_specific_1},
      {"specific2", :profile_specific_2},
      {"li61", :leap61},
      {"li59", :leap59},
      {"utcreasonable", :current_utc_offset_valid},
      {"timescale", :ptp_timescale},
      {"timetraceable", :time_traceable},
      {"frequencytraceable", :frequency_traceable},
      {"synchronizationUncertain", :synchronization_uncertain}
    ]
    |> Enum.filter(fn {w, _} -> Tshark.get(pkt, "ptp.v2.flags." <> w) == "1" end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  def check(pkt, %Message{} = m) do
    for {k, v} <- expected(m) do
      assert Tshark.get(pkt, k) == v,
             "#{m.type} #{k}: tshark #{inspect(Tshark.get(pkt, k))}, library #{v}"
    end

    assert flag_names(pkt) == Enum.sort(Message.flag_names(m.flags))

    # correction: tshark splits into ns and a fractional part
    {frac, _} = Tshark.get(pkt, "ptp.v2.correction.subns") |> Float.parse()
    ns = Tshark.get(pkt, "ptp.v2.correction.ns") |> String.to_integer()
    assert_in_delta ns + frac, m.correction / 65_536, 1.0e-4
  end
end

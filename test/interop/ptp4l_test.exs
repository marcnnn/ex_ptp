Code.require_file("support/ptp_interop.ex", __DIR__)

defmodule ExPtp.Interop.Ptp4lTest do
  @moduledoc """
  ExPtp.Port against linuxptp's ptp4l 4.2 (Debian trixie, software timestamps,
  UDP/IPv4, end-to-end delay mechanism), both in rootless podman containers on one
  network. See README "Interop" and test/interop/support/ptp_interop.ex.

  Every scenario is repeated for the default profile (1 s sync, 2 s announce) and the
  AES67 profile values (125 ms sync, 1 s announce).
  """
  use ExUnit.Case, async: false

  alias Interop.Ptp

  @moduletag :interop
  @moduletag timeout: 300_000

  @port_cid "eeeeee.fffe.000001"
  # TAI-UTC: a master that announces the PTP timescale must send TAI, and ptp4l with
  # software timestamps compares it with CLOCK_REALTIME plus this offset
  @tai 37

  @profiles %{
    default: [],
    aes67: [
      "--logAnnounceInterval=0",
      "--logSyncInterval=-3",
      "--logMinDelayReqInterval=0",
      "--announceReceiptTimeout=3",
      "--summary_interval=-3"
    ]
  }

  for profile <- [:default, :aes67] do
    describe "profile #{profile}" do
      @tag profile: profile
      test "(a) ptp4l master, ExPtp.Port slave: reaches SLAVE with a bounded clock error", %{
        profile: profile
      } do
        p4 = Ptp.unique("p4l")
        Ptp.start_ptp4l(p4, ["--serverOnly=1", "--priority1=100"] ++ @profiles[profile])

        # ExPtp.Servo uses linuxptp's hardware timestamp gains. With software timestamps
        # at 8 Hz (AES67 profile) the port flaps between UNCALIBRATED and SLAVE unless the
        # lock threshold is wide (NEEDS.md, "Interop findings", 1)
        lock_ns = if profile == :aes67, do: 500_000, else: 100_000

        events =
          Ptp.run_beam(
            profile: profile,
            seconds: 40,
            priority1: 128,
            lock_ns: lock_ns,
            id: 1
          )

        log = Ptp.logs_with_best_master(p4)
        states = for {:state, new, old, _} <- events, do: {old, new}
        assert {:listening, :uncalibrated} in states
        assert {:uncalibrated, :slave} in states
        assert {:final, final} = List.keyfind(events, :final, 0)
        assert final.state in [:slave, :uncalibrated]

        # the port follows the master ptp4l announced (clock identity from its MAC)
        ptp4l_id = Ptp.best_master(log) |> String.replace(".", "") |> String.upcase()
        assert final.gm == ptp4l_id

        # software timestamps on a shared host: the port clock, steered by the servo,
        # stays within hundreds of microseconds of the (shared) kernel clock
        errs = for {:offset, _, _, e} <- events, do: abs(e)
        assert length(errs) >= 8
        recent = Enum.take(errs, -8)
        assert Ptp.median(recent) < 500_000, "median clock error #{inspect(recent)} ns"
        assert Enum.max(recent) < 2_000_000, "max clock error #{inspect(recent)} ns"

        mpds = for {:offset, _, mpd, _} <- events, do: mpd

        IO.puts(
          "(a) #{profile}: median |clock error| #{Ptp.median(errs)} ns, " <>
            "median mean path delay #{Ptp.median(mpds)} ns, " <>
            "port states #{inspect(Enum.map(states, &elem(&1, 1)))}"
        )

        # a veth hop, two container networking stacks and BEAM scheduling
        assert Ptp.median(mpds) in 1_000..1_000_000

        # ptp4l stays master
        refute Enum.any?(Ptp.ptp4l_transitions(log), fn {_, to, _} ->
                 to in ["SLAVE", "UNCALIBRATED"]
               end)

        assert log =~ "assuming the grand master role"
      end

      @tag profile: profile
      test "(b) ExPtp.Port master, ptp4l slave: ptp4l reaches s2 and SLAVE", %{profile: profile} do
        p4 = Ptp.unique("p4l")
        Ptp.start_ptp4l(p4, ["--clientOnly=1"] ++ @profiles[profile])

        events =
          Ptp.run_beam(
            profile: profile,
            seconds: 70,
            priority1: 100,
            tai: @tai,
            id: 1
          )

        log = Ptp.logs(p4)
        transitions = Ptp.ptp4l_transitions(log)
        assert {"LISTENING", "UNCALIBRATED", "RS_SLAVE"} in transitions, log
        assert {"UNCALIBRATED", "SLAVE", "MASTER_CLOCK_SELECTED"} in transitions, log
        assert Ptp.best_master(log) == @port_cid

        assert {:final, %{state: :master}} = List.keyfind(events, :final, 0)

        offs = Ptp.ptp4l_offsets(log)
        s2 = for {o, 2, d} <- offs, do: {o, d}
        assert length(s2) >= 5, "only #{length(s2)} s2 lines:\n#{String.slice(log, -2000, 2000)}"

        IO.puts(
          "(b) #{profile}: ptp4l #{length(s2)} s2 samples, median |offset| " <>
            "#{Ptp.median(for {o, _} <- s2, do: abs(o))} ns, " <>
            "median path delay #{Ptp.median(for {_, d} <- s2, do: d)} ns"
        )

        # raw (unfiltered) offsets with software timestamps, a 37 s TAI offset applied
        # on our side: tens of microseconds
        assert Ptp.median(for {o, _} <- s2, do: abs(o)) < 200_000
        assert Ptp.median(for {_, d} <- s2, do: d) in 1_000..1_000_000
        refute log =~ "timed out while polling for tx timestamp"
      end
    end
  end

  describe "BMCA" do
    test "(c1) lower priority1 on ptp4l: ptp4l is master, the port is slave" do
      p4 = Ptp.unique("p4l")
      Ptp.start_ptp4l(p4, ["--priority1=100"])

      events =
        Ptp.run_beam(profile: :default, seconds: 35, priority1: 110, lock_ns: 100_000, id: 1)

      log = Ptp.logs(p4)
      assert {:final, %{state: :slave}} = List.keyfind(events, :final, 0)
      assert log =~ "assuming the grand master role"
      refute log =~ "to SLAVE"
    end

    test "(c2) lower priority1 on the port: the port is master, ptp4l is slave" do
      p4 = Ptp.unique("p4l")
      Ptp.start_ptp4l(p4, ["--priority1=100"])
      events = Ptp.run_beam(profile: :default, seconds: 35, priority1: 90, tai: @tai, id: 1)
      log = Ptp.logs(p4)
      assert {:final, %{state: :master}} = List.keyfind(events, :final, 0)
      assert {"UNCALIBRATED", "SLAVE", "MASTER_CLOCK_SELECTED"} in Ptp.ptp4l_transitions(log)
      assert Ptp.best_master(log) == @port_cid
    end

    test "(c3) priority1 raised on ptp4l at run time via pmc: mastership moves to the port" do
      p4 = Ptp.unique("p4l")
      Ptp.start_ptp4l(p4, ["--priority1=100"])

      task =
        Task.async(fn ->
          Ptp.run_beam(
            profile: :default,
            seconds: 70,
            priority1: 110,
            tai: @tai,
            lock_ns: 100_000,
            id: 1
          )
        end)

      # the port syncs to ptp4l first
      Process.sleep(32_000)
      mid = Ptp.logs(p4)
      assert mid =~ "assuming the grand master role"
      Ptp.pmc(p4, "SET PRIORITY1 120")
      assert Ptp.pmc(p4, "GET PRIORITY1") =~ "priority1 120"
      events = Task.await(task, 120_000)
      log = Ptp.logs(p4)

      states = for {:state, new, old, _} <- events, do: {old, new}

      assert Enum.any?(states, fn {_, new} -> new == :slave end),
             "port never reached slave: #{inspect(states)}"

      assert {:final, %{state: :master}} = List.keyfind(events, :final, 0)
      assert {"UNCALIBRATED", "SLAVE", "MASTER_CLOCK_SELECTED"} in Ptp.ptp4l_transitions(log)
      assert Ptp.best_master(log) == @port_cid
    end
  end

  describe "clock identity tie break (equal priorities, clock class and accuracy)" do
    # IEEE 1588 BMCA: the lower clockIdentity wins when everything else is equal.
    # ptp4l's identity comes from the MAC of its container interface, so it is read from its
    # log and the port's identity is chosen just below or above it.
    for {label, delta, port_master} <- [{"lower", -1, true}, {"higher", 1, false}] do
      @tag delta: delta, port_master: port_master
      test "(c4) port identity #{label} than ptp4l's: port is #{if port_master, do: "master", else: "slave"}",
           %{delta: delta, port_master: port_master} do
        p4 = Ptp.unique("p4l")
        Ptp.start_ptp4l(p4, [])
        # ptp4l logs the selected local clock at start (INITIALIZING -> LISTENING)
        Process.sleep(1_500)

        {out, _} =
          System.cmd("podman", ["exec", p4, "pmc", "-u", "-b", "0", "GET DEFAULT_DATA_SET"])

        [_, id_text] = Regex.run(~r/clockIdentity\s+(\S+)/, out)
        ptp4l_id = id_text |> String.replace(".", "") |> String.upcase()
        <<ptp4l_int::64>> = Base.decode16!(ptp4l_id)
        port_cid = Base.encode16(<<ptp4l_int + delta::64>>)

        events =
          Ptp.run_beam(
            profile: :default,
            seconds: 30,
            cid: port_cid,
            tai: @tai,
            lock_ns: 100_000
          )

        log = Ptp.logs(p4)
        assert {:final, final} = List.keyfind(events, :final, 0)

        if port_master do
          assert final.state == :master
          assert {"UNCALIBRATED", "SLAVE", "MASTER_CLOCK_SELECTED"} in Ptp.ptp4l_transitions(log)
        else
          assert final.state in [:slave, :uncalibrated]
          assert final.gm == ptp4l_id
          assert log =~ "assuming the grand master role"
        end
      end
    end
  end

  describe "traffic" do
    test "(d) every frame of a ptp4l master / ExPtp.Port slave exchange decodes and matches tshark" do
      p4 = Ptp.unique("p4l")
      Ptp.start_ptp4l(p4, ["--serverOnly=1", "--priority1=100"])
      dir = Interop.Tshark.tmp_dir()
      File.chmod!(dir, 0o777)
      stop = Ptp.capture(p4, dir, "udp port 319 or udp port 320")
      events = Ptp.run_beam(profile: :default, seconds: 30, lock_ns: 100_000, id: 1)
      frames = stop.()
      assert {:final, %{state: state}} = List.keyfind(events, :final, 0)
      assert state in [:slave, :uncalibrated]

      pkts = Interop.Tshark.dissect_file(dir, "cap.pcap")
      assert length(pkts) == length(frames)
      # ptp4l announces itself as it likes; Wireshark must not call anything malformed
      refute Enum.any?(pkts, &Map.has_key?(&1, "_ws.malformed"))

      types =
        for {f, p} <- Enum.zip(frames, pkts),
            Interop.Tshark.get(p, "ptp.v2.messagetype") != nil do
          {:udp, _, payload} = Interop.Frame.payload(f)

          assert {:ok, m} = ExPtp.Message.decode(payload),
                 "ExPtp.Message.decode failed on ptp4l/port frame"

          PtpInterop.Fields.check(p, m)
          m.type
        end

      freq = Enum.frequencies(types)
      # ptp4l: Announce, Sync, Follow_Up, Delay_Resp; the port: Delay_Req
      for t <- [:announce, :sync, :follow_up, :delay_req, :delay_resp],
          do: assert(freq[t] >= 3, inspect(freq))
    end
  end
end

defmodule Interop.Ptp do
  @moduledoc false
  # Orchestration for the linuxptp tests: ptp4l runs in a detached container of the
  # `ex-interop-linuxptp` image, the BEAM side (ExPtp.Port over
  # PtpInterop.UdpTransport, test/interop/support/ptp_node.exs) in an Elixir
  # container on the same podman network. Both containers share the host kernel
  # clock, so a correctly synchronised port clock has zero error against CLOCK_REALTIME.

  @network "ex-interop-ptp"
  @fake_clock "/usr/local/lib/fakeclock.so"

  def network do
    System.cmd("podman", ["network", "create", @network], stderr_to_stdout: true)
    @network
  end

  def require_images! do
    Interop.Podman.require_image!("linuxptp")
    Interop.Podman.require_image!("beam")
  end

  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "Starts ptp4l detached; the fake clock shim lets its servo run without CAP_SYS_TIME."
  def start_ptp4l(name, args) do
    require_images!()

    {out, 0} =
      System.cmd(
        "podman",
        [
          "run",
          "-d",
          "--rm",
          "--network",
          network(),
          "--name",
          name,
          "-e",
          "LD_PRELOAD=" <> @fake_clock,
          Interop.Podman.image("linuxptp"),
          "ptp4l",
          "-i",
          "eth0",
          "-S",
          "-4",
          "-E",
          "-m",
          "--sanity_freq_limit=0"
        ] ++ args,
        stderr_to_stdout: true
      )

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
    end)

    String.trim(out)
  end

  def logs(name, tries \\ 5) do
    {out, _} = System.cmd("podman", ["logs", name], stderr_to_stdout: true)

    if out == "" and tries > 0 do
      Process.sleep(500)
      logs(name, tries - 1)
    else
      out
    end
  end

  def pmc(name, command) do
    {out, _} =
      System.cmd("podman", ["exec", name, "pmc", "-u", "-b", "0", command],
        stderr_to_stdout: true
      )

    out
  end

  @doc """
  Runs `ptp_node.exs` with `key=value` args in the BEAM container and returns the
  parsed output lines.
  """
  def run_beam(args) do
    libs = Path.join(Mix.Project.build_path(), "lib")
    support = Path.expand("support", __DIR__ |> Path.dirname())
    name = unique("ex-interop-beam")

    {out, status} =
      System.cmd(
        "podman",
        [
          "run",
          "--rm",
          "--network",
          network(),
          "--name",
          name,
          "--security-opt",
          "label=disable",
          "-v",
          "#{libs}:/libs:ro",
          "-v",
          "#{support}:/support:ro",
          Interop.Podman.image("beam"),
          "elixir",
          "-pa",
          "/libs/*/ebin",
          "/support/ptp_node.exs"
        ] ++ Enum.map(args, fn {k, v} -> "#{k}=#{v}" end),
        stderr_to_stdout: true
      )

    lines = String.split(out, "\n", trim: true)
    if status != 0, do: raise("ptp_node failed (#{status}):\n#{out}")
    parse_beam(lines)
  end

  def parse_beam(lines) do
    Enum.flat_map(lines, fn
      "STATE " <> rest ->
        [new, old | _] = String.split(rest)
        [{:state, String.to_atom(new), String.to_atom(old), clkerr(rest)}]

      "OFFSET " <> rest ->
        [off, mpd | _] = String.split(rest)
        [{:offset, String.to_integer(off), String.to_integer(mpd), clkerr(rest)}]

      "TICK " <> rest ->
        [{:tick, field(rest, "state") |> String.to_atom(), clkerr(rest), field(rest, "locked")}]

      "FINAL " <> rest ->
        [
          {:final,
           %{
             state: field(rest, "state") |> String.to_atom(),
             clkerr: clkerr(rest),
             gm: field(rest, "gm"),
             line: rest
           }}
        ]

      _ ->
        []
    end)
  end

  defp field(s, key) do
    [_, v] = Regex.run(~r/(?:^|\s)#{key}=(\S+)/, s)
    v
  end

  defp clkerr(s), do: s |> field("clkerr") |> String.to_integer()

  # -- ptp4l log ---------------------------------------------------------------------------------

  @doc "Port state changes: `[{port, from, to, event}]`."
  def ptp4l_transitions(log) do
    for [_, from, to, event] <-
          Regex.scan(~r/port 1 \(eth0\): (\w+) to (\w+) on (\w+)/, log),
        do: {from, to, event}
  end

  @doc "`[{offset_ns, servo_state, path_delay_ns}]` from `master offset` lines."
  def ptp4l_offsets(log) do
    for [_, off, st, delay] <-
          Regex.scan(~r/master offset\s+(-?\d+) s(\d) freq\s+[+-]?\d+ path delay\s+(-?\d+)/, log),
        do: {String.to_integer(off), String.to_integer(st), String.to_integer(delay)}
  end

  @doc "Clock identity ptp4l selected as best master (e.g. `eeeeee.fffe.000001`)."
  @doc "Logs of `name` once ptp4l has logged its best master choice (polls up to 10 s)."
  def logs_with_best_master(name, tries \\ 20) do
    log = logs(name)

    if best_master(log) == nil and tries > 0 do
      Process.sleep(500)
      logs_with_best_master(name, tries - 1)
    else
      log
    end
  end

  def best_master(log) do
    case Regex.scan(
           ~r/selected (?:best master clock|local clock) (\S+?)(?: as best master)?\n/,
           log
         ) do
      [] -> nil
      l -> l |> List.last() |> Enum.at(1)
    end
  end

  def median(l) do
    s = Enum.sort(l)
    Enum.at(s, div(length(s), 2))
  end

  @doc """
  Starts tcpdump in the network namespace of container `target`, writing `dir/cap.pcap`.
  Returns a function that stops it and returns the captured frames.
  """
  def capture(target, dir, filter) do
    Interop.Podman.require_image!("nettools")
    name = unique("ex-interop-tcap")

    {_, 0} =
      System.cmd(
        "podman",
        [
          "run",
          "-d",
          "--name",
          name,
          "--network",
          "container:" <> target,
          "--cap-add=NET_RAW,NET_ADMIN",
          "-v",
          "#{dir}:/out:z",
          Interop.Podman.image("nettools"),
          "sh",
          "-c",
          "exec tcpdump -i eth0 -U -s 0 -w /out/cap.pcap '#{filter}'"
        ],
        stderr_to_stdout: true
      )

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
    end)

    Process.sleep(1_500)

    fn ->
      System.cmd("podman", ["kill", "-s", "INT", name], stderr_to_stdout: true)
      Process.sleep(1_000)
      System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
      {_, frames} = Interop.Captures.frames(Path.join(dir, "cap.pcap"))
      frames
    end
  end

  @doc "ptp4l's clock identity (16 hex digits, upper case) from its log."
  def ptp4l_identity(log) do
    [_, id] = Regex.run(~r/selected local clock (\S+) as best master/, log)
    id |> String.replace(".", "") |> String.upcase()
  end
end

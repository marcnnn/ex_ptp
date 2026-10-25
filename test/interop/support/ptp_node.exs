# Runs inside the ex-interop-beam container (see test/interop/support/ptp_interop.ex):
#
#   elixir -pa "/libs/*/ebin" /support/ptp_node.exs key=value ...
#
# Keys: priority1, priority2, profile (default|aes67), seconds, slave_only (true|false),
# clock_class, lock_ns, id (last byte of the clock identity) or cid (16 hex digits), domain,
# timescale (ptp|arb, ptp by default: the clock is TAI), tai (TAI-UTC offset in s, 37).
# Prints one event per line: STATE new old, OFFSET ns mpd_ns, SERVO ppb, CLKERR ns, INFO ...
args =
  System.argv()
  |> Enum.map(&String.split(&1, "=", parts: 2))
  |> Map.new(fn [k, v] -> {k, v} end)

int = fn k, d -> if args[k], do: String.to_integer(args[k]), else: d end

{:ok, ifs} = :inet.getifaddrs()

iface =
  for {name, opts} <- ifs, name != ~c"lo", {:addr, {_, _, _, _} = a} <- opts, do: a

iface = hd(iface)

{:ok, tr} =
  ExPtp.Transport.Udp.start_link(
    iface_ip: iface,
    timescale: String.to_atom(args["timescale"] || "ptp"),
    tai_offset_s: int.("tai", 37)
  )

opts = [
  transport: {ExPtp.Transport.Udp, tr},
  clock_identity:
    if(args["cid"],
      do: Base.decode16!(args["cid"], case: :mixed),
      else: <<0xEE, 0xEE, 0xEE, 0xFF, 0xFE, 0, 0, int.("id", 1)>>
    ),
  profile: String.to_atom(args["profile"] || "default"),
  priority1: int.("priority1", 128),
  priority2: int.("priority2", 128),
  clock_class: int.("clock_class", 248),
  domain_number: int.("domain", 0),
  slave_only: args["slave_only"] == "true"
  # lock_ns, lock_count and step_ns override the servo profile of the transport (software)
]

opts =
  opts ++
    for {key, arg} <- [
          lock_threshold_ns: "lock_ns",
          lock_count: "lock_count",
          step_threshold_ns: "step_ns"
        ],
        args[arg],
        do: {key, String.to_integer(args[arg])}

{:ok, port} = ExPtp.Port.start_link(opts)
ExPtp.Port.subscribe(port)
IO.puts("START iface=#{inspect(iface)} #{inspect(Keyword.drop(opts, [:transport]))}")

deadline = System.monotonic_time(:millisecond) + int.("seconds", 20) * 1000

loop = fn loop ->
  left = deadline - System.monotonic_time(:millisecond)

  if left > 0 do
    receive do
      {:ex_ptp, _, {:state, new, old}} ->
        IO.puts("STATE #{new} #{old} clkerr=#{ExPtp.Transport.Udp.clock_error_ns(tr)}")

      {:ex_ptp, _, {:offset, off, mpd}} ->
        IO.puts(
          "OFFSET #{round(off)} #{round(mpd)} clkerr=#{ExPtp.Transport.Udp.clock_error_ns(tr)}"
        )

      {:ex_ptp, _, {:servo, ppb}} ->
        IO.puts("SERVO #{Float.round(ppb * 1.0, 1)}")
    after
      min(left, 1000) ->
        i = ExPtp.Port.info(port)

        IO.puts(
          "TICK state=#{i.state} clkerr=#{ExPtp.Transport.Udp.clock_error_ns(tr)} offset=#{inspect(i.offset_ns)} locked=#{i.locked}"
        )
    end

    loop.(loop)
  end
end

loop.(loop)
i = ExPtp.Port.info(port)

IO.puts(
  "FINAL state=#{i.state} clkerr=#{ExPtp.Transport.Udp.clock_error_ns(tr)} offset=#{inspect(i.offset_ns)} mpd=#{inspect(i.mean_path_delay_ns)} gm=#{Base.encode16(i.grandmaster)} tp=#{inspect(i.time_properties)} stats=#{inspect(i.stats)}"
)

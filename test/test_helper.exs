# :verilator - co-simulation, needs verilator in PATH
# :yosys - resource numbers, needs yosys in PATH
# :interop - real implementations in podman containers, `mix test --only interop`
exclude =
  [verilator: "verilator", yosys: "yosys"]
  |> Enum.reject(fn {_tag, exe} -> System.find_executable(exe) end)
  |> Enum.map(fn {tag, _} -> {tag, true} end)

Code.require_file("interop/support/interop.ex", __DIR__)
Code.require_file("interop/support/ptp_fields.ex", __DIR__)
ExUnit.start(exclude: [{:interop, true} | exclude])

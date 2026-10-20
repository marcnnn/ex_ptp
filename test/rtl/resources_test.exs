defmodule ExPtp.RTL.ResourcesTest do
  use ExUnit.Case, async: true

  alias ExPtp.RTL.{
    MediaNco,
    Offset,
    PtpDetect,
    RxStamp,
    Servo,
    TimestampUnit,
    TxInsert,
    Wallclock
  }

  @moduletag :yosys
  @moduletag timeout: 300_000

  # {name, module, max LUT, max DSP}; ceilings are about 25 % above the numbers in the README
  defp designs,
    do: [
      {"Wallclock, 2 captures + snapshot + PPS", fn -> Wallclock.build() end, 700, 0},
      {"Wallclock, bare", fn -> Wallclock.build(ncap: 0, snap: false, pps: false) end, 700, 0},
      {"TimestampUnit", fn -> TimestampUnit.build() end, 360, 0},
      {"PtpDetect 64", fn -> PtpDetect.build(64) end, 210, 0},
      {"PtpDetect 8", fn -> PtpDetect.build(8) end, 220, 0},
      {"RxStamp 64", fn -> RxStamp.build(64) end, 200, 0},
      {"TxInsert 64", fn -> TxInsert.build(64) end, 660, 0},
      {"TxInsert 8", fn -> TxInsert.build(8) end, 400, 0},
      {"Servo (PI kernel, lock, rate)", fn -> Servo.build() end, 1020, 16},
      {"Offset", fn -> Offset.build() end, 440, 3},
      {"MediaNco", fn -> MediaNco.build() end, 1350, 28}
    ]

  test "resources on UltraScale+ (Yosys synth_xilinx): no block RAM, DSPs only where multiplies are" do
    rows =
      for {name, build, max_lut, max_dsp} <- designs() do
        m = build.()

        {:ok, u} =
          ExHdl.Synth.Yosys.utilization(ExHdl.Backends.SystemVerilog.RTL.generate(m), m.name,
            family: "xcup"
          )

        assert u.lut <= max_lut, "#{name}: #{u.lut} LUT"
        assert u.dsp <= max_dsp, "#{name}: #{u.dsp} DSP"
        assert u.bram18 == 0 and u.uram == 0
        "| #{name} | #{u.lut} | #{u.ff} | #{u.dsp} | #{u.lutram} |"
      end

    IO.puts(
      "\n| Module | LUT | FF | DSP | LUTRAM |\n|---|---|---|---|---|\n" <> Enum.join(rows, "\n")
    )
  end
end

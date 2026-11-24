SIM ?= iverilog
RTL_SRC = rtl/audio_i2s_pkg.sv \
          rtl/clkgen.sv \
          rtl/apb_i2s.sv \
          rtl/ahb_dma.sv \
          rtl/audio_i2s_top.sv
SRC = $(RTL_SRC) tb/tb_top.sv
OUT = sim.out

.PHONY: sim lint clean

sim: $(OUT)
	vvp $(OUT) -N

$(OUT): $(SRC)
	iverilog -g2012 -s tb_top -o $(OUT) $(SRC)

lint:
	verilator --lint-only -Wno-fatal -sv $(RTL_SRC)

clean:
	rm -f $(OUT) *.vcd

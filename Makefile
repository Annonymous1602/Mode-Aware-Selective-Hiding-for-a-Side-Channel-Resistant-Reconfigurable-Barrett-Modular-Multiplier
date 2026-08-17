SIM ?= iverilog
VVP ?= vvp
N ?= 64
TRACES ?= 1000
SEED ?= 12648430
DESIGN ?= qgsp
SEC64_TOGGLE_BITS ?= 8192

ifeq ($(DESIGN),baseline)
  RTL=rtl/rbmm_baseline.v
  TB=tb/tb_rbmm_baseline_sca.v
  TOP=tb_rbmm_sca
  EXTRA_TOP_PARAMS=
else
  RTL=rtl/rbmm_qgsp.v
  TB=tb/tb_rbmm_qgsp_sca.v
  TOP=tb_rbmm_qgsp_sca
  EXTRA_TOP_PARAMS=-P$(TOP).SEC64_TOGGLE_BITS=$(SEC64_TOGGLE_BITS)
endif

BUILD=build_$(DESIGN)_N$(N)
FIXED_VCD=traces/$(DESIGN)_fixed_N$(N).vcd
RANDOM_VCD=traces/$(DESIGN)_random_N$(N).vcd
FIXED_OP=traces/$(DESIGN)_fixed_N$(N).txt
RANDOM_OP=traces/$(DESIGN)_random_N$(N).txt
FIXED_ACT=traces/$(DESIGN)_fixed_N$(N)_activity.csv
RANDOM_ACT=traces/$(DESIGN)_random_N$(N)_activity.csv

.PHONY: all dirs sim-fixed sim-random sca security-summary plots compare clean vivado-synth parse-vivado hardware-plots
all: sca

dirs:
	mkdir -p traces reports plots $(BUILD)

sim-fixed: dirs
	$(SIM) -g2012 -o $(BUILD)/sim_fixed \
	  -P$(TOP).N=$(N) -P$(TOP).N_TRACES=$(TRACES) -P$(TOP).SEED=$(SEED) \
	  -P$(TOP).FIXED_A=1 $(EXTRA_TOP_PARAMS) \
	  $(RTL) $(TB)
	$(VVP) $(BUILD)/sim_fixed +VCDFILE=$(FIXED_VCD) +OPFILE=$(FIXED_OP)

sim-random: dirs
	$(SIM) -g2012 -o $(BUILD)/sim_random \
	  -P$(TOP).N=$(N) -P$(TOP).N_TRACES=$(TRACES) -P$(TOP).SEED=$(SEED) \
	  -P$(TOP).FIXED_A=0 $(EXTRA_TOP_PARAMS) \
	  $(RTL) $(TB)
	$(VVP) $(BUILD)/sim_random +VCDFILE=$(RANDOM_VCD) +OPFILE=$(RANDOM_OP)

sca: sim-fixed sim-random
	python3 scripts/extract_vcd_activity.py $(FIXED_VCD) $(FIXED_ACT)
	python3 scripts/extract_vcd_activity.py $(RANDOM_VCD) $(RANDOM_ACT)
	python3 scripts/tvla_extended.py $(FIXED_ACT) $(RANDOM_ACT) \
	  --out-json traces/$(DESIGN)_N$(N)_tvla.json --out-csv traces/$(DESIGN)_N$(N)_tvla.csv \
	  | tee traces/$(DESIGN)_N$(N)_tvla.txt
	python3 scripts/qif_proxy.py $(RANDOM_OP) $(RANDOM_ACT) --N $(N) \
	  --out-json traces/$(DESIGN)_N$(N)_qif.json --out-csv traces/$(DESIGN)_N$(N)_qif.csv \
	  | tee traces/$(DESIGN)_N$(N)_qif.txt
	python3 scripts/cpa_correlation.py $(RANDOM_OP) $(RANDOM_ACT) --N $(N) \
	  --out-json traces/$(DESIGN)_N$(N)_cpa.json --out-csv traces/$(DESIGN)_N$(N)_cpa.csv \
	  | tee traces/$(DESIGN)_N$(N)_cpa.txt

security-summary:
	python3 scripts/collect_metrics.py --traces-dir traces --out-csv reports/security_summary.csv --out-md reports/security_summary.md

plots: security-summary
	python3 scripts/plot_metrics.py --security-csv reports/security_summary.csv --outdir plots

compare:
	bash run_compare_all.sh

vivado-synth:
	vivado -mode batch -source vivado_synth.tcl -tclargs $(DESIGN) $(N)

parse-vivado:
	python3 scripts/parse_vivado_reports.py --report-dir reports/vivado --out-csv reports/hardware_summary.csv

hardware-plots: parse-vivado
	python3 scripts/plot_metrics.py --security-csv reports/security_summary.csv --hardware-csv reports/hardware_summary.csv --outdir plots

clean:
	rm -rf build_* traces/*.vcd traces/*.txt traces/*.csv traces/*.json reports/security_summary.* plots/*.png

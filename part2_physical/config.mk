export DESIGN_NICKNAME = convolution# your directory name
export DESIGN_NAME = Convolver# top module name
export PLATFORM    = nangate45

export VERILOG_FILES = $(sort $(wildcard $(DESIGN_HOME)/src/$(DESIGN_NICKNAME)/*.v))
export SDC_FILE = $(DESIGN_HOME)/$(PLATFORM)/$(DESIGN_NICKNAME)/constraint.sdc
export ABC_AREA = 1

export CORE_UTILIZATION ?= 80
export PLACE_DENSITY_LB_ADDON = 0.20
export TNS_END_PERCENT        = 100

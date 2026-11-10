# sobel

MARCH   = rv32imc_zicsr_zifencei
EFFORT  = -O2

# must match IMEM_SIZE / DMEM_SIZE in rtl/top.vhd
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=32k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=256k

# include libraries
APP_INC += -I ../lib

# toolchain prefix (default is riscv-none-elf-)
#RISCV_PREFIX ?= riscv-none-elf-
RISCV_PREFIX ?= riscv64-unknown-elf-

NEORV32_HOME ?= ../../ext/neorv32
include $(NEORV32_HOME)/sw/common/common.mk

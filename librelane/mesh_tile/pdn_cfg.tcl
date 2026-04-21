# source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
# source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
# set_global_connections

# set_voltage_domain -name CORE -power VDD -ground VSS

# define_pdn_grid \
#     -name stdcell_grid \
#     -starts_with POWER \
#     -voltage_domain CORE

# add_pdn_stripe \
#     -grid stdcell_grid \
#     -layer Metal2 \
#     -width 3 \
#     -pitch 50 \
#     -offset 5 \
#     -starts_with POWER

# add_pdn_stripe \
#     -grid stdcell_grid \
#     -layer Metal3 \
#     -width 3 \
#     -pitch 50 \
#     -offset 5 \
#     -starts_with POWER

# add_pdn_connect \
#     -grid stdcell_grid \
#     -layers "Metal2 Metal3"

# if { $::env(PDN_ENABLE_RAILS) == 1 } {
#     add_pdn_stripe \
#         -grid stdcell_grid \
#         -layer $::env(PDN_RAIL_LAYER) \
#         -width $::env(PDN_RAIL_WIDTH) \
#         -followpins

#     add_pdn_connect \
#         -grid stdcell_grid \
#         -layers "$::env(PDN_RAIL_LAYER) Metal2"
# }

# define_pdn_grid \
#     -macro \
#     -default \
#     -name macro \
#     -starts_with POWER \
#     -halo "10 10"

# add_pdn_connect \
#     -grid macro \
#     -layers "Metal2 Metal3"

















source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set_voltage_domain -name CORE -power VDD -ground VSS

# ── Standard cell grid ────────────────────────────────────────────────────────
define_pdn_grid \
    -name stdcell_grid \
    -starts_with POWER \
    -voltage_domain CORE

# Metal1 followpin rails (VDD/VSS on every stdcell row)
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) Metal2"
}

# Metal2 vertical stripes
add_pdn_stripe \
    -grid stdcell_grid \
    -layer Metal2 \
    -width $::env(PDN_VWIDTH) \
    -pitch $::env(PDN_VPITCH) \
    -offset 5 \
    -starts_with POWER

# Metal3 horizontal stripes
add_pdn_stripe \
    -grid stdcell_grid \
    -layer Metal3 \
    -width $::env(PDN_HWIDTH) \
    -pitch $::env(PDN_HPITCH) \
    -offset 5 \
    -starts_with POWER

add_pdn_connect \
    -grid stdcell_grid \
    -layers "Metal2 Metal3"

# ── Macro grid (covers both SRAMs via -default) ───────────────────────────────
define_pdn_grid \
    -macro \
    -default \
    -name macro \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

# Bring Metal3 stripes down to the macro's Metal2 power pins
add_pdn_connect \
    -grid macro \
    -layers "Metal2 Metal3"


add_pdn_stripe \
    -grid macro \
    -layer Metal4 \
    -width $::env(PDN_HWIDTH) \
    -pitch $::env(PDN_HPITCH) \
    -offset 5 \
    -starts_with POWER

add_pdn_connect \
    -grid macro \
    -layers "Metal3 Metal4"
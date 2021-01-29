#ifndef HW_ARM_APPLE_M1_SOC_H 
#define HW_ARM_APPLE_M1_SOC_H

#include "qom/object.h"
#include "target/arm/cpu.h"

enum {
    VIRT_MEM,   // A block of ram
    VIRT_UART,  // The virtual uart (on real hardware this is on the type-C and multiplexed via USB-PD selection)
    BOOT_ARGS   // We setup a block of ROM to make pretend boot arguments to match what the real hardware does
};

// We create an "m1 soc" but realistically the chip has a model, should we use that instead? this is pretty
// high level emulation of the SoC so it might not really matter for our purposes. Probably should change it though.
#define TYPE_APPLE_M1_SOC "apple-m1-soc"

OBJECT_DECLARE_SIMPLE_TYPE(AppleM1SoCState, APPLE_M1_SOC)

struct AppleM1SoCState {
    /*< private >*/
    DeviceState parent_obj;

    /*< public >*/
    ARMCPU maincore;
};

#endif // HW_ARM_APPLE_M1_SOC_H

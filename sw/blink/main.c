#include <neorv32.h>

static void
wait_ms(uint32_t time_ms)
{
    neorv32_aux_delay_ms(neorv32_sysinfo_get_clk(), time_ms);
}

int
main(void)
{
    // clear GPIO output
    neorv32_gpio_port_set(0);

    // configure lowest 8 GPIO pins as outputs
    // this is only relevant if the GPIO direction control feature is enabled
    neorv32_gpio_port_dir_set(0x000000FF);

    int cnt = 0;
    for (;;) {
        neorv32_gpio_port_set(cnt++ & 0xFF); // increment counter and mask for lowest 8 bit
        wait_ms(10); // wait 250ms using busy wait
    }

    // this should never be reached
    return 0;
}

/* Bare-metal smoke test: prints over the UART and takes machine timer
   interrupts, all in C. Addresses are memmap.sv's; the timer is the CLINT
   (rtl/clint.sv). Passes when three ticks have been taken. */
#include <stdint.h>

#define UART_THR ((volatile uint8_t *)0x10000000u)
#define UART_LSR ((volatile uint8_t *)0x10000005u)
#define LSR_THRE 0x20u

/* 64-bit CLINT registers as two words: low, then high. */
#define MTIME    ((volatile uint32_t *)0x0200bff8u)
#define MTIMECMP ((volatile uint32_t *)0x02004000u)

#define TICK_PERIOD  1000u /* mtime ticks: 50 MHz, so 20 us */
#define TICKS_WANTED 3

/* The testbench reads this word for the result (riscv-tests convention). */
volatile uint32_t tohost __attribute__((section(".tohost"))) = 0;

static volatile uint32_t ticks;

static void putc_(char c) {
    while (!(*UART_LSR & LSR_THRE))
        ;
    *UART_THR = (uint8_t)c;
}

static void puts_(const char *s) {
    for (; *s; s++)
        putc_(*s);
}

/* Arm the timer for `delta` ticks from now. The high word goes to all ones
   first, so the comparator never sees a half-written, early value. The high
   word stays zero: the test runs far from a 32-bit wrap of mtime. */
static void set_timer_in(uint32_t delta) {
    uint32_t now = MTIME[0];
    MTIMECMP[1] = 0xffffffffu;
    MTIMECMP[0] = now + delta;
    MTIMECMP[1] = 0;
}

__attribute__((interrupt("machine"), aligned(4))) static void trap_handler(void) {
    ticks++;
    putc_('t');
    set_timer_in(TICK_PERIOD);
}

int main(void) {
    puts_("hello from C\n");
    set_timer_in(TICK_PERIOD);
    __asm__ volatile("csrw mtvec, %0" ::"r"((uintptr_t)trap_handler));
    __asm__ volatile("csrs mie, %0" ::"r"(1u << 7)); /* MTIE */
    __asm__ volatile("csrs mstatus, %0" ::"r"(1u << 3)); /* MIE */

    while (ticks < TICKS_WANTED)
        ;

    __asm__ volatile("csrc mstatus, %0" ::"r"(1u << 3));
    puts_("\ndone\n");
    tohost = 1;
    for (;;)
        ;
}

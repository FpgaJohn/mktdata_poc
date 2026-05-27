#include "FreeRTOS.h"
#include "task.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xuartpsv.h"
#include "xscugic.h"
#include "xil_exception.h"

/* Values come from the BSP xparameters.h generated from the XSA */
#define UART_DEVICE_ID    XPAR_XUARTPSV_0_DEVICE_ID
#define GIC_DEVICE_ID     XPAR_SCUGIC_SINGLE_DEVICE_ID
#define UART_INT_ID       XPAR_XUARTPSV_0_INTR

static volatile BaseType_t keep_running = pdTRUE;
static XUartPsv uart_inst;
static XScuGic  gic_inst;

static void uart_irq_handler(void *ref)
{
    u32 isr = XUartPsv_ReadReg(uart_inst.Config.BaseAddress,
                                XUARTPSV_UARTMIS_OFFSET);
    if (isr & XUARTPSV_UARTIMSC_RXIM_MASK) {
        while (!(XUartPsv_ReadReg(uart_inst.Config.BaseAddress,
                                   XUARTPSV_UARTFR_OFFSET) &
                 XUARTPSV_UARTFR_RXFE_MASK)) {
            u8 ch = (u8)XUartPsv_ReadReg(uart_inst.Config.BaseAddress,
                                          XUARTPSV_UARTDR_OFFSET);
            if (ch == 0x03) {   /* Ctrl+C */
                xil_printf("\r\nCtrl+C received — stopping counter.\r\n");
                keep_running = pdFALSE;
            }
        }
        XUartPsv_WriteReg(uart_inst.Config.BaseAddress,
                           XUARTPSV_UARTICR_OFFSET,
                           XUARTPSV_UARTIMSC_RXIM_MASK);
    }
}

static void counter_task(void *pvParameters)
{
    int counter = 1;
    TickType_t last_wake = xTaskGetTickCount();

    while (keep_running) {
        xil_printf("Counter: %d\r\n", counter++);
        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(1000));
    }

    vTaskDelete(NULL);
}

static int setup_uart_interrupt(void)
{
    XUartPsv_Config *uart_cfg;
    XScuGic_Config  *gic_cfg;
    int rc;

    gic_cfg = XScuGic_LookupConfig(GIC_DEVICE_ID);
    if (!gic_cfg) return XST_FAILURE;
    rc = XScuGic_CfgInitialize(&gic_inst, gic_cfg, gic_cfg->CpuBaseAddress);
    if (rc != XST_SUCCESS) return rc;

    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic_inst);
    Xil_ExceptionEnable();

    uart_cfg = XUartPsv_LookupConfig(UART_DEVICE_ID);
    if (!uart_cfg) return XST_FAILURE;
    rc = XUartPsv_CfgInitialize(&uart_inst, uart_cfg, uart_cfg->BaseAddress);
    if (rc != XST_SUCCESS) return rc;

    XUartPsv_SetOperMode(&uart_inst, XUARTPSV_OPER_MODE_NORMAL);

    rc = XScuGic_Connect(&gic_inst, UART_INT_ID,
                          (Xil_InterruptHandler)uart_irq_handler, NULL);
    if (rc != XST_SUCCESS) return rc;

    XScuGic_Enable(&gic_inst, UART_INT_ID);

    /* Enable RX interrupt */
    u32 mask = XUartPsv_ReadReg(uart_inst.Config.BaseAddress,
                                  XUARTPSV_UARTIMSC_OFFSET);
    XUartPsv_WriteReg(uart_inst.Config.BaseAddress,
                       XUARTPSV_UARTIMSC_OFFSET,
                       mask | XUARTPSV_UARTIMSC_RXIM_MASK);

    return XST_SUCCESS;
}

int main(void)
{
    if (setup_uart_interrupt() != XST_SUCCESS) {
        xil_printf("ERROR: UART interrupt setup failed\r\n");
        return -1;
    }

    xil_printf("Poller app started. Press Ctrl+C to exit.\r\n");

    xTaskCreate(counter_task, "counter",
                configMINIMAL_STACK_SIZE * 4,
                NULL, tskIDLE_PRIORITY + 1, NULL);

    vTaskStartScheduler();

    /* Never reached */
    return 0;
}

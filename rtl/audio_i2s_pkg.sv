`timescale 1ns/1ps
`ifndef AUDIO_I2S_PKG_SV
`define AUDIO_I2S_PKG_SV
package audio_i2s_pkg;
  parameter int DMA_CH_NUM = 6;
  parameter int I2S_NUM    = 6;
  parameter int APB_AW     = 12;
  parameter int APB_DW     = 32;
  parameter int AHB_AW     = 32;
  parameter int AHB_DW     = 32;
  parameter int FIFO_BIG   = 4096; // 0x1000, CH1..CH4 for C8
  parameter int FIFO_SMALL = 128;  // CH0, CH5

  typedef logic [APB_DW-1:0] apb_data_t;
  typedef logic [APB_AW-1:0] apb_addr_t;
  typedef logic [AHB_DW-1:0] ahb_data_t;
  typedef logic [AHB_AW-1:0] ahb_addr_t;
endpackage
`endif
